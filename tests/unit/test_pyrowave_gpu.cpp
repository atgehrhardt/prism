/**
 * @file tests/unit/test_pyrowave_gpu.cpp
 * @brief Opt-in DMA-BUF encode/decode tests using generated images, without capturing the desktop.
 */
#include <gtest/gtest.h>
#if defined(PRISM_ENABLE_PYROWAVE) && defined(PRISM_BUILD_VULKAN)
  #include "src/platform/linux/graphics.h"
  #include "src/pyrowave/api.h"
  #include "src/pyrowave/encoder.h"
  #include "src/pyrowave/protocol.h"
  #include "src/video.h"

  #include <cstdlib>
  #include <dlfcn.h>
  #include <fcntl.h>
  #include <gbm.h>
  #include <unistd.h>

namespace {
  /**
   * @brief Synthetic display metadata for a generated 128-pixel capture image.
   */
  struct generated_display: platf::display_t {
    bool hdr = false;  ///< Requested synthetic HDR state.

    /**
     * @brief Construct a 128 by 128 synthetic display.
     */
    generated_display() {
      width = height = 128;
    }

    /**
     * @brief No desktop capture is performed by this test display.
     */
    platf::capture_e capture(const push_captured_image_cb_t &, const pull_free_image_cb_t &, bool *) override {
      return platf::capture_e::error;
    }

    /**
     * @brief The test supplies its own exported GBM image.
     */
    std::shared_ptr<platf::img_t> alloc_img() override {
      return {};
    }

    /**
     * @brief Dummy capture is not supported.
     */
    int dummy_img(platf::img_t *) override {
      return -1;
    }

    /**
     * @brief Return the synthetic source's HDR transfer mode.
     */
    bool is_hdr() override {
      return hdr;
    }
  };
}  // namespace

/**
 * @brief Round-trip generated SDR/HDR and chroma variants, including separate-cursor composition.
 */
TEST(PyroWaveGpu, EncodeGeneratedDmaBufAndDecode) {
  if (!std::getenv("PRISM_TEST_GPU")) {
    GTEST_SKIP() << "Set PRISM_TEST_GPU=1 to exercise real GPU DMA-BUF import";
  }
  // Load GBM like the host graphics layer; keep the core tests independent of its link ABI.
  void *library = dlopen("libgbm.so.1", RTLD_NOW | RTLD_LOCAL);
  ASSERT_NE(library, nullptr);
  auto close_library = util::fail_guard([&]() {
    dlclose(library);
  });
  auto create_device = reinterpret_cast<decltype(&gbm_create_device)>(dlsym(library, "gbm_create_device"));
  auto destroy_device = reinterpret_cast<decltype(&gbm_device_destroy)>(dlsym(library, "gbm_device_destroy"));
  auto create_bo = reinterpret_cast<decltype(&gbm_bo_create)>(dlsym(library, "gbm_bo_create"));
  auto destroy_bo = reinterpret_cast<decltype(&gbm_bo_destroy)>(dlsym(library, "gbm_bo_destroy"));
  auto map_bo = reinterpret_cast<decltype(&gbm_bo_map)>(dlsym(library, "gbm_bo_map"));
  auto unmap_bo = reinterpret_cast<decltype(&gbm_bo_unmap)>(dlsym(library, "gbm_bo_unmap"));
  auto get_fd = reinterpret_cast<decltype(&gbm_bo_get_fd)>(dlsym(library, "gbm_bo_get_fd"));
  auto get_stride = reinterpret_cast<decltype(&gbm_bo_get_stride)>(dlsym(library, "gbm_bo_get_stride"));
  auto get_modifier = reinterpret_cast<decltype(&gbm_bo_get_modifier)>(dlsym(library, "gbm_bo_get_modifier"));
  ASSERT_TRUE(create_device && destroy_device && create_bo && destroy_bo && map_bo && unmap_bo && get_fd && get_stride && get_modifier);
  int render_fd = open(platf::resolve_render_device().c_str(), O_RDWR | O_CLOEXEC);
  ASSERT_GE(render_fd, 0);
  auto close_fd = util::fail_guard([&]() {
    close(render_fd);
  });
  auto *gbm = create_device(render_fd);
  ASSERT_NE(gbm, nullptr);
  auto destroy_gbm = util::fail_guard([&]() {
    destroy_device(gbm);
  });
  auto *bo = create_bo(gbm, 128, 128, GBM_FORMAT_XRGB8888, GBM_BO_USE_WRITE | GBM_BO_USE_LINEAR);
  ASSERT_NE(bo, nullptr);
  auto destroy_image = util::fail_guard([&]() {
    destroy_bo(bo);
  });
  uint32_t stride = 0;
  void *mapping = nullptr;
  auto *pixels = static_cast<uint8_t *>(map_bo(bo, 0, 0, 128, 128, GBM_BO_TRANSFER_WRITE, &stride, &mapping));
  ASSERT_NE(pixels, nullptr);
  for (int y = 0; y < 128; ++y) {
    for (int x = 0; x < 128; ++x) {
      pixels[y * stride + x * 4 + 0] = 64;
      pixels[y * stride + x * 4 + 1] = 128;
      pixels[y * stride + x * 4 + 2] = 192;
      pixels[y * stride + x * 4 + 3] = 255;
    }
  }
  unmap_bo(bo, mapping);
  egl::img_descriptor_t image {};
  image.sequence = 1;
  image.sd = {128, 128, {get_fd(bo), -1, -1, -1}, GBM_FORMAT_XRGB8888, get_modifier(bo), {get_stride(bo), 0, 0, 0}, {0, 0, 0, 0}};
  ASSERT_GE(image.sd.fds[0], 0);
  pyrowave_device decode_device = nullptr;
  ASSERT_EQ(pyrowave_create_default_device(&decode_device), PYROWAVE_SUCCESS);
  auto destroy_decode_device = util::fail_guard([&]() {
    pyrowave_device_destroy(decode_device);
  });
  for (int mode = 0; mode < 4; ++mode) {
    for (int variant = 0; variant < 4; ++variant) {
      const bool cursor = variant & 1;
      const int output_width = variant & 2 ? 192 : 128;
      SCOPED_TRACE(::testing::Message() << "mode=" << mode << " variant=" << variant);
      video::config_t config {};
      config.width = output_width;
      config.height = 128;
      config.pyrowave_frame_budget = 65536;
      config.pyrowave_frame_limit = 131072;
      config.dynamicRange = mode & 1;
      config.chromaSamplingType = (mode >> 1) & 1;
      generated_display display;
      display.hdr = config.dynamicRange;
      image.buffer.assign(16 * 16 * 4, 255);
      image.x = image.y = 32;
      image.width = image.height = image.src_w = image.src_h = 16;
      image.data = cursor ? image.buffer.data() : nullptr;
      prism_pyrowave::encoder encoder(config);
      EXPECT_THROW(encoder.encode(image, display, 4095), std::runtime_error);
      EXPECT_THROW(encoder.encode(image, display, config.pyrowave_frame_limit + 1), std::runtime_error);
      if (variant == 0) {
        image.sequence = 0;
        EXPECT_THROW(encoder.encode(image, display), std::runtime_error);
        image.sequence = 1;
        image.y_invert = true;
        EXPECT_THROW(encoder.encode(image, display), std::runtime_error);
        image.y_invert = false;
        display.hdr = !display.hdr;
        EXPECT_THROW(encoder.encode(image, display), std::runtime_error);
        display.hdr = !display.hdr;
      }
      auto frame = variant & 1 ? encoder.encode(image, display, 98304) : encoder.encode(image, display);
      auto packets = prism_pyrowave::unpack(frame.data(), frame.size(), mode);
      ASSERT_FALSE(packets.empty());
      ASSERT_TRUE(prism_pyrowave::validate_bitstream(packets, output_width, 128, mode));
      pyrowave_decoder_create_info info {decode_device, output_width, 128, config.chromaSamplingType ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420, false};
      pyrowave_decoder decoder = nullptr;
      ASSERT_EQ(pyrowave_decoder_create(&info, &decoder), PYROWAVE_SUCCESS);
      auto destroy_decoder = util::fail_guard([&]() {
        pyrowave_decoder_destroy(decoder);
      });
      for (const auto &packet : packets) {
        ASSERT_EQ(pyrowave_decoder_push_packet(decoder, packet.data, packet.size), PYROWAVE_SUCCESS);
      }
      ASSERT_TRUE(pyrowave_decoder_decode_is_ready(decoder, false));
      std::array<std::vector<uint8_t>, 3> planes;
      pyrowave_cpu_buffer output {};
      output.width = output_width;
      output.height = 128;
      output.format = config.chromaSamplingType ? PYROWAVE_CPU_BUFFER_FORMAT_YUV444P : PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
      for (unsigned i = 0; i < 3; ++i) {
        unsigned divisor = i && !config.chromaSamplingType ? 2 : 1;
        unsigned plane_width = output_width / divisor;
        planes[i].resize(plane_width * (128 / divisor));
        output.data[i] = planes[i].data();
        output.row_stride_in_bytes[i] = plane_width;
        output.plane_size_in_bytes[i] = planes[i].size();
      }
      ASSERT_EQ(pyrowave_decoder_decode_cpu_buffer_synchronous(decoder, &output), PYROWAVE_SUCCESS);
      // The synthetic image must retain real image content, not merely emit a decodable black frame.
      EXPECT_GT(planes[0][8 * output_width + output_width / 2], 80);
      EXPECT_LT(planes[0][8 * output_width + output_width / 2], 180);
      if (!display.hdr) {
        // Full-range BT.709 for the generated RGB(192, 128, 64), before presentation.
        const unsigned divisor = config.chromaSamplingType ? 1 : 2;
        EXPECT_NEAR(planes[0][8 * output_width + output_width / 2], 137, 3);
        EXPECT_NEAR(planes[1][(8 / divisor) * (output_width / divisor) + output_width / (2 * divisor)], 88, 3);
        EXPECT_NEAR(planes[2][(8 / divisor) * (output_width / divisor) + output_width / (2 * divisor)], 162, 3);
      }
      if (output_width != 128) {
        EXPECT_LT(planes[0][8 * output_width + 8], 5);
      }
      if (cursor && !display.hdr) {
        EXPECT_GT(planes[0][40 * output_width + 40 + (output_width - 128) / 2], 230);
      }
    }
  }
}

  #ifdef PRISM_BUILD_WAYLAND
namespace platf {
  /**
   * @brief Open the specified compositor's DMA-BUF screencopy backend for this integration test.
   *
   * @param type Requested GPU memory type.
   * @param name Output name, empty to select the compositor's first output.
   * @param config Negotiated video parameters.
   * @param socket Explicit test-compositor socket.
   * @param width Expected source width, or zero for its current mode.
   * @param height Expected source height, or zero for its current mode.
   * @return Initialized capture display, or null on failure.
   */
  std::shared_ptr<display_t> wl_display(mem_type_e type, const std::string &name, const video::config_t &config, const std::string &socket, int width, int height);
}  // namespace platf

/**
 * @brief Encode real screencopy DMA-BUF frames from an explicitly provided isolated test compositor.
 */
TEST(PyroWaveGpu, EncodeWaylandScreencopy) {
  const char *socket = std::getenv("PRISM_TEST_WAYLAND_DISPLAY");
  if (!std::getenv("PRISM_TEST_GPU") || !socket || !*socket) {
    GTEST_SKIP() << "Set PRISM_TEST_GPU=1 and PRISM_TEST_WAYLAND_DISPLAY to an isolated test compositor";
  }
  for (int chroma : {0, 1}) {
    video::config_t config {};
    config.width = config.height = 128;
    config.framerate = 60;
    config.pyrowave_frame_budget = 65536;
    config.chromaSamplingType = chroma;
    auto display = platf::wl_display(platf::mem_type_e::vulkan, "", config, socket, 0, 0);
    ASSERT_NE(display, nullptr);
    ASSERT_TRUE(display->supports_pyrowave());
    prism_pyrowave::encoder encoder(config);
    unsigned frames = 0;
    bool cursor = true;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    auto push = [&](std::shared_ptr<platf::img_t> image, bool captured) {
      if (captured) {
        auto frame = encoder.encode(*image, *display);
        auto packets = prism_pyrowave::unpack(frame.data(), frame.size(), chroma << 1);
        EXPECT_FALSE(packets.empty());
        EXPECT_TRUE(prism_pyrowave::validate_bitstream(packets, 128, 128, chroma << 1));
        ++frames;
      }
      return frames < 3 && std::chrono::steady_clock::now() < deadline;
    };
    auto pull = [&](std::shared_ptr<platf::img_t> &image) {
      image = display->alloc_img();
      return bool(image);
    };
    EXPECT_EQ(display->capture(push, pull, &cursor), platf::capture_e::ok);
    EXPECT_EQ(frames, 3);
  }
}
  #endif
#endif
