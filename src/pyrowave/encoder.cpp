/**
 * @file src/pyrowave/encoder.cpp
 * @brief PyroWave C API adapter with bounded packetization and DMA-BUF synchronization.
 */
#include "encoder.h"

#include "compositor.h"
#include "protocol.h"
#include "src/video.h"

#if defined(PRISM_ENABLE_PYROWAVE) && defined(PRISM_BUILD_VULKAN)
  #include "api.h"
  #include "src/platform/linux/graphics.h"
  #include "src/platform/linux/misc.h"

  #include <drm_fourcc.h>
  #include <linux/dma-buf.h>
  #include <sys/ioctl.h>
  #include <sys/stat.h>
  #include <sys/sysmacros.h>
  #include <unistd.h>

namespace prism_pyrowave {
  namespace {
    /**
     * @brief Turn a failed codec operation into a session failure.
     * @param result Upstream status.
     * @param operation Operation for diagnostic reporting.
     */
    void check(pyrowave_result result, const char *operation) {
      if (result != PYROWAVE_SUCCESS) {
        throw std::runtime_error(std::string("PyroWave ") + operation + " failed (" + std::to_string(result) + ")");
      }
    }

    /**
     * @brief Match the configured DRM render node instead of silently choosing another GPU.
     * @return Owned codec device.
     */
    pyrowave_device create_device() {
      uint32_t major_version, minor_version, patch;
      pyrowave_get_api_version(&major_version, &minor_version, &patch);
      if (major_version != PYROWAVE_API_VERSION_MAJOR || minor_version != PYROWAVE_API_VERSION_MINOR) {
        throw std::runtime_error("PyroWave library API version mismatch");
      }
      auto render_node = platf::resolve_render_device();
      struct stat node {};
      if (render_node.empty() || stat(render_node.c_str(), &node) != 0) {
        throw std::runtime_error("PyroWave requires a valid DRM render-device path");
      }
      VkApplicationInfo app {VK_STRUCTURE_TYPE_APPLICATION_INFO};
      app.apiVersion = VK_API_VERSION_1_3;
      VkInstanceCreateInfo info {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
      info.pApplicationInfo = &app;
      VkInstance instance = VK_NULL_HANDLE;
      if (vkCreateInstance(&info, nullptr, &instance) != VK_SUCCESS) {
        throw std::runtime_error("PyroWave requires Vulkan 1.3");
      }
      auto cleanup = util::fail_guard([&]() {
        vkDestroyInstance(instance, nullptr);
      });
      uint32_t count = 0;
      vkEnumeratePhysicalDevices(instance, &count, nullptr);
      std::vector<VkPhysicalDevice> devices(count);
      vkEnumeratePhysicalDevices(instance, &count, devices.data());
      for (auto gpu : devices) {
        VkPhysicalDeviceIDProperties ids {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceDrmPropertiesEXT drm {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT};
        drm.pNext = &ids;
        VkPhysicalDeviceProperties2 properties {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        properties.pNext = &drm;
        vkGetPhysicalDeviceProperties2(gpu, &properties);
        if (!drm.hasRender || drm.renderMajor != int64_t(major(node.st_rdev)) || drm.renderMinor != int64_t(minor(node.st_rdev))) {
          continue;
        }
        pyrowave_uuid uuid {};
        std::memcpy(uuid.uuid, ids.deviceUUID, sizeof(uuid.uuid));
        pyrowave_device device = nullptr;
        check(pyrowave_create_device_by_compat(0, 0, &uuid, nullptr, nullptr, &device), "device creation");
        if (!pyrowave_device_confirm_interop_support(device)) {
          pyrowave_device_destroy(device);
          throw std::runtime_error("PyroWave requires external memory and semaphore interoperability");
        }
        return device;
      }
      throw std::runtime_error("PyroWave could not match the capture render device to a Vulkan GPU");
    }

    /**
     * @brief Map supported RGB capture layouts without guessing unknown formats.
     * @param fourcc DRM capture format.
     * @return Matching Vulkan format.
     */
    VkFormat image_format(uint32_t fourcc) {
      switch (fourcc) {
        case DRM_FORMAT_XRGB8888:
        case DRM_FORMAT_ARGB8888:
          return VK_FORMAT_B8G8R8A8_UNORM;
        case DRM_FORMAT_XBGR8888:
        case DRM_FORMAT_ABGR8888:
          return VK_FORMAT_R8G8B8A8_UNORM;
        case DRM_FORMAT_XRGB2101010:
        case DRM_FORMAT_ARGB2101010:
          return VK_FORMAT_A2R10G10B10_UNORM_PACK32;
        case DRM_FORMAT_XBGR2101010:
        case DRM_FORMAT_ABGR2101010:
          return VK_FORMAT_A2B10G10R10_UNORM_PACK32;
        case DRM_FORMAT_XBGR16161616:
        case DRM_FORMAT_ABGR16161616:
          return VK_FORMAT_R16G16B16A16_UNORM;
        default:
          throw std::runtime_error("PyroWave does not support this capture pixel format");
      }
    }
  }  // namespace

  /**
   * @brief Codec resources, destroyed in encoder-before-device order.
   */
  struct encoder::state {
    video::config_t config;  ///< Negotiated stream parameters.
    pyrowave_device device = nullptr;  ///< Owned Vulkan device wrapper.
    std::unique_ptr<compositor> composite;  ///< Optional cursor and aspect-fit compositor.
    pyrowave_encoder codec = nullptr;  ///< Owned encoder.

    /**
     * @brief Retain negotiated settings until initialization.
     * @param config Negotiated configuration.
     */
    explicit state(const video::config_t &config):
        config(config) {}

    /**
     * @brief Wait for pending work and release upstream objects.
     */
    ~state() {
      composite.reset();
      if (codec) {
        pyrowave_encoder_destroy(codec);
      }
      if (device) {
        pyrowave_device_destroy(device);
      }
    }
  };

  encoder::encoder(const video::config_t &config):
      impl(std::make_unique<state>(config)) {
    if (!config.pyrowave_frame_budget ||
        !valid_mode(config.width, config.height, config.dynamicRange, config.chromaSamplingType)) {
      throw std::runtime_error("Invalid PyroWave stream mode or frame budget");
    }
    impl->device = create_device();
    pyrowave_encoder_create_info info {};
    info.device = impl->device;
    info.width = config.width;
    info.height = config.height;
    info.chroma = config.chromaSamplingType ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
    check(pyrowave_encoder_create(&info, &impl->codec), "encoder creation");
  }

  encoder::~encoder() = default;

  std::vector<uint8_t> encoder::encode(platf::img_t &image, platf::display_t &display, size_t frame_budget) {
    if (!frame_budget) {
      frame_budget = impl->config.pyrowave_frame_budget;
    }
    const size_t limit = impl->config.pyrowave_frame_limit ? impl->config.pyrowave_frame_limit : impl->config.pyrowave_frame_budget;
    if (frame_budget < 4096 || frame_budget > limit) {
      throw std::runtime_error("PyroWave frame budget exceeds negotiated transport limits");
    }
    bool hdr = display.is_hdr();
    auto *descriptor = dynamic_cast<egl::img_descriptor_t *>(&image);
    if (!descriptor || !descriptor->sequence || descriptor->y_invert) {
      throw std::runtime_error("PyroWave requires an upright GPU DMA-BUF image");
    }
    if (bool(impl->config.dynamicRange) != hdr) {
      throw std::runtime_error("PyroWave capture HDR mode does not match the requested mode");
    }
    const auto &sd = descriptor->sd;
    auto format = image_format(sd.fourcc);
    if (sd.modifier == DRM_FORMAT_MOD_INVALID || sd.fds[0] < 0) {
      throw std::runtime_error("PyroWave requires an explicit DMA-BUF modifier");
    }
    std::array<VkSubresourceLayout, 4> planes {};
    uint32_t plane_count = 0;
    struct stat first {};
    if (fstat(sd.fds[0], &first)) {
      throw std::runtime_error("Invalid capture DMA-BUF");
    }
    for (unsigned i = 0; i < planes.size() && sd.fds[i] >= 0; ++i) {
      struct stat other {};
      if (fstat(sd.fds[i], &other) || other.st_dev != first.st_dev || other.st_ino != first.st_ino) {
        throw std::runtime_error("PyroWave requires a single DMA-BUF allocation");
      }
      planes[i].offset = sd.offsets[i];
      planes[i].rowPitch = sd.pitches[i];
      ++plane_count;
    }
    VkImageDrmFormatModifierExplicitCreateInfoEXT modifier {VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT};
    modifier.drmFormatModifier = sd.modifier;
    modifier.drmFormatModifierPlaneCount = plane_count;
    modifier.pPlaneLayouts = planes.data();
    VkImageCreateInfo image_info {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    image_info.pNext = &modifier;
    image_info.imageType = VK_IMAGE_TYPE_2D;
    image_info.format = format;
    image_info.extent = {uint32_t(sd.width), uint32_t(sd.height), 1};
    image_info.mipLevels = image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    image_info.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
    pyrowave_image_create_info import {};
    import.device = impl->device;
    int fd = dup(sd.fds[0]);
    if (fd < 0) {
      throw std::runtime_error("Cannot duplicate capture DMA-BUF");
    }
    auto fd_cleanup = util::fail_guard([&]() {
      if (fd >= 0) {
        close(fd);
      }
    });
    import.external_handle = fd;
    import.handle_type = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    import.image_create_info = &image_info;
    pyrowave_image imported = nullptr;
    check(pyrowave_image_create(&import, &imported), "DMA-BUF import");
    fd = -1;
    auto image_cleanup = util::fail_guard([&]() {
      pyrowave_image_destroy(imported);
    });

    dma_buf_export_sync_file exported {};
    exported.flags = DMA_BUF_SYNC_READ;
    exported.fd = -1;
    if (ioctl(sd.fds[0], DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &exported)) {
      throw std::runtime_error("PyroWave cannot export the capture synchronization fence");
    }
    auto fence_cleanup = util::fail_guard([&]() {
      if (exported.fd >= 0) {
        close(exported.fd);
      }
    });
    pyrowave_sync_object_create_info sync_info {};
    sync_info.device = impl->device;
    sync_info.external_handle = exported.fd;
    sync_info.handle_type = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    sync_info.semaphore_type = VK_SEMAPHORE_TYPE_BINARY;
    sync_info.import_flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT;
    pyrowave_sync_object sync = nullptr;
    check(pyrowave_sync_object_create(&sync_info, &sync), "capture fence import");
    exported.fd = -1;
    auto sync_cleanup = util::fail_guard([&]() {
      pyrowave_sync_object_destroy(sync);
    });
    pyrowave_gpu_external_reference reference {imported, VK_QUEUE_FAMILY_FOREIGN_EXT};
    pyrowave_gpu_sync_operation acquire {&reference, 1, {pyrowave_sync_object_get_semaphore(sync), 0}};
    pyrowave_gpu_sync_operation release {&reference, 1, {VK_NULL_HANDLE, 0}};
    pyrowave_scaled_encode_info scaling {};
    check(pyrowave_image_get_image_view(imported, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_USAGE_SAMPLED_BIT, &scaling.view), "capture view");
    scaling.input_color_space = scaling.output_color_space = hdr ? VK_COLOR_SPACE_HDR10_ST2084_EXT : VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    scaling.intermediate_plane_format = hdr ? VK_FORMAT_R16_UNORM : VK_FORMAT_R8_UNORM;
    scaling.ycbcr_chroma_midpoint = 0.5f;
    auto [offset_x, offset_y] = display.pyrowave_capture_offset();
    VkRect2D crop {{offset_x, offset_y}, {uint32_t(display.width), uint32_t(display.height)}};
    if (offset_x < 0 || offset_y < 0 || uint64_t(offset_x) + crop.extent.width > uint64_t(sd.width) ||
        uint64_t(offset_y) + crop.extent.height > uint64_t(sd.height)) {
      throw std::runtime_error("Invalid PyroWave capture crop");
    }
    scaling.crop_rect = &crop;
    pyrowave_rate_control rate {frame_budget};
    bool needs_composition = descriptor->data || uint64_t(display.width) * impl->config.height != uint64_t(display.height) * impl->config.width;
    if (needs_composition) {
      if (!impl->composite) {
        impl->composite = std::make_unique<compositor>(impl->device, impl->config.width, impl->config.height);
      }
      scaling.view = impl->composite->compose(scaling.view, acquire.sync.semaphore, *descriptor, display);
      scaling.crop_rect = nullptr;
      check(pyrowave_encoder_encode_gpu_scaled_synchronous(impl->codec, nullptr, nullptr, &scaling, &rate), "encoding composited frame");
    } else {
      check(pyrowave_encoder_encode_gpu_scaled_synchronous(impl->codec, &acquire, &release, &scaling, &rate), "encoding");
    }
    // Packetization waits for completion before the capture buffer can be recycled.
    size_t count = 0;
    check(pyrowave_encoder_compute_num_packets(impl->codec, packet_boundary, &count), "packet count");
    if (!count || count > maximum_frame_size / 12) {
      throw std::runtime_error("PyroWave packet count exceeds transport limits");
    }
    std::vector<pyrowave_packet> packets(count);
    std::vector<uint8_t> bytes(maximum_frame_size);
    size_t written = 0;
    check(pyrowave_encoder_packetize(impl->codec, packets.data(), packet_boundary, &written, bytes.data(), bytes.size()), "packetization");
    if (written > count) {
      throw std::runtime_error("Invalid upstream packet count");
    }
    std::vector<packet_view> views;
    for (size_t i = 0; i < written; ++i) {
      const auto &packet = packets[i];
      if (packet.offset > bytes.size() || packet.size > bytes.size() - packet.offset) {
        throw std::runtime_error("Invalid upstream packet extent");
      }
      views.push_back({bytes.data() + packet.offset, packet.size});
    }
    return pack(views, uint8_t(impl->config.dynamicRange | impl->config.chromaSamplingType << 1));
  }

  uint32_t encoder_capabilities() {
    try {
      video::config_t config {};
      config.width = config.height = 128;
      config.pyrowave_frame_budget = 65536;
      encoder probe(config);
      config.chromaSamplingType = 1;
      encoder probe444(config);
      return server_mask;
    } catch (const std::exception &error) {
      BOOST_LOG(debug) << error.what();
      return 0;
    }
  }
}  // namespace prism_pyrowave
#else
namespace prism_pyrowave {
  struct encoder::state {};

  encoder::encoder(const video::config_t &) {
    throw std::runtime_error("PyroWave support was disabled at build time");
  }

  encoder::~encoder() = default;

  std::vector<uint8_t> encoder::encode(platf::img_t &, platf::display_t &) {
    throw std::runtime_error("PyroWave support was disabled at build time");
  }

  uint32_t encoder_capabilities() {
    return 0;
  }
}  // namespace prism_pyrowave
#endif
