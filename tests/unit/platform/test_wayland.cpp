/**
 * @file tests/unit/platform/test_wayland.cpp
 * @brief Exercise HDR negotiation and capture lifetime with a real Wayland wire.
 */
#ifdef PRISM_BUILD_WAYLAND

  #include "src/platform/linux/wayland.h"

  #include <atomic>
  #include <color-management-v1-server.h>
  #include <drm_fourcc.h>
  #include <filesystem>
  #include <gbm.h>
  #include <gtest/gtest.h>
  #include <thread>
  #include <wayland-server.h>
  #include <wlr-screencopy-unstable-v1-server.h>

/** @brief Minimal compositor serving controlled output descriptions and delayed frames. */
class WaylandCaptureTest: public testing::Test {
protected:
  /** @brief Start an isolated protocol server without a GPU or a desktop session. */
  void SetUp() override {
    char pattern[] = "/tmp/prism-wayland-XXXXXX";
    const auto directory = mkdtemp(pattern);
    ASSERT_NE(directory, nullptr);
    runtime = directory;
    server = wl_display_create();
    ASSERT_NE(server, nullptr);
    socket = runtime + "/wayland-test";
    ASSERT_EQ(wl_display_add_socket(server, socket.c_str()), 0);
    wl_global_create(server, &wl_output_interface, 2, this, [](wl_client *client, void *, uint32_t version, uint32_t id) {
      auto resource = wl_resource_create(client, &wl_output_interface, version, id);
      wl_output_send_geometry(resource, 0, 0, 0, 0, WL_OUTPUT_SUBPIXEL_UNKNOWN, "Prism", "Test", WL_OUTPUT_TRANSFORM_NORMAL);
      wl_output_send_mode(resource, WL_OUTPUT_MODE_CURRENT, 1920, 1080, 60000);
      wl_output_send_done(resource);
    });
    wl_global_create(server, &wp_color_manager_v1_interface, 1, this, bind_color_manager);
    wl_global_create(server, &zwlr_screencopy_manager_v1_interface, 3, this, bind_screencopy);
    running = true;
    worker = std::thread([this]() {
      while (running) {
        wl_event_loop_dispatch(wl_display_get_event_loop(server), 10);
        wl_display_flush_clients(server);
      }
    });
    display = std::make_unique<wl::display_t>();
    ASSERT_EQ(display->init(socket.c_str()), 0);
    interfaces.listen(display->registry());
    ASSERT_TRUE(display->roundtrip());
    ASSERT_TRUE(display->roundtrip());
    ASSERT_EQ(interfaces.monitors.size(), 1);
  }

  /** @brief Disconnect clients and stop the server before deleting its socket. */
  void TearDown() override {
    display.reset();
    running = false;
    if (worker.joinable()) {
      worker.join();
    }
    if (server) {
      wl_display_destroy_clients(server);
      wl_display_destroy(server);
    }
    std::filesystem::remove_all(runtime);
  }

  /** @brief Destroy a protocol resource in response to its destructor request. */
  static void destroy_resource(wl_client *, wl_resource *resource) {
    wl_resource_destroy(resource);
  }

  /** @brief Emit the fixture's selected colorimetry and mastering data. */
  static void get_information(wl_client *client, wl_resource *description, uint32_t id) {
    auto self = static_cast<WaylandCaptureTest *>(wl_resource_get_user_data(description));
    auto resource = wl_resource_create(client, &wp_image_description_info_v1_interface, 1, id);
    wp_image_description_info_v1_send_primaries_named(resource, self->primaries);
    wp_image_description_info_v1_send_tf_named(resource, self->transfer);
    wp_image_description_info_v1_send_target_primaries(resource, 708000, 292000, 170000, 797000, 131000, 46000, 312700, 329000);
    wp_image_description_info_v1_send_target_luminance(resource, 50, self->max_luminance);
    wp_image_description_info_v1_send_target_max_cll(resource, 900);
    wp_image_description_info_v1_send_target_max_fall(resource, 400);
    wp_image_description_info_v1_send_done(resource);
    wl_resource_destroy(resource);
  }

  /** @brief Supply a ready or deliberately failed output description. */
  static void get_description(wl_client *client, wl_resource *output, uint32_t id) {
    auto self = static_cast<WaylandCaptureTest *>(wl_resource_get_user_data(output));
    static const struct wp_image_description_v1_interface implementation = {
      .destroy = destroy_resource,
      .get_information = get_information,
    };
    auto resource = wl_resource_create(client, &wp_image_description_v1_interface, 1, id);
    wl_resource_set_implementation(resource, &implementation, self, nullptr);
    if (self->failed_description) {
      wp_image_description_v1_send_failed(resource, WP_IMAGE_DESCRIPTION_V1_CAUSE_NO_OUTPUT, "test output unavailable");
    } else {
      wp_image_description_v1_send_ready(resource, 1);
    }
  }

  /** @brief Bind the version-one color protocol used by the production client. */
  static void bind_color_manager(wl_client *client, void *data, uint32_t, uint32_t id) {
    static const struct wp_color_management_output_v1_interface output_implementation = {
      .destroy = destroy_resource,
      .get_image_description = get_description,
    };
    static const struct wp_color_manager_v1_interface implementation = {
      .destroy = destroy_resource,
      .get_output = [](wl_client *client, wl_resource *manager, uint32_t id, wl_resource *) {
        auto output = wl_resource_create(client, &wp_color_management_output_v1_interface, 1, id);
        wl_resource_set_implementation(output, &output_implementation, wl_resource_get_user_data(manager), nullptr);
      },
    };
    auto resource = wl_resource_create(client, &wp_color_manager_v1_interface, 1, id);
    wl_resource_set_implementation(resource, &implementation, data, nullptr);
    wp_color_manager_v1_send_done(resource);
  }

  /** @brief Delay every capture so repeated calls can test in-flight ownership. */
  static void bind_screencopy(wl_client *client, void *data, uint32_t, uint32_t id) {
    static const struct zwlr_screencopy_frame_v1_interface frame_implementation = {
      .destroy = destroy_resource,
    };
    static const struct zwlr_screencopy_manager_v1_interface implementation = {
      .capture_output = [](wl_client *client, wl_resource *manager, uint32_t id, int32_t, wl_resource *) {
        auto self = static_cast<WaylandCaptureTest *>(wl_resource_get_user_data(manager));
        ++self->captures;
        auto frame = wl_resource_create(client, &zwlr_screencopy_frame_v1_interface, 3, id);
        wl_resource_set_implementation(frame, &frame_implementation, nullptr, nullptr);
      },
      .destroy = destroy_resource,
    };
    auto resource = wl_resource_create(client, &zwlr_screencopy_manager_v1_interface, 3, id);
    wl_resource_set_implementation(resource, &implementation, data, nullptr);
  }

  /** @brief Query the fixture's selected output through the production HDR reader. */
  std::optional<SS_HDR_METADATA> metadata() {
    return wl::read_output_hdr_metadata(*display, interfaces.color_manager, interfaces.monitors.front()->output);
  }

  std::string runtime;  ///< Temporary socket directory.
  std::string socket;  ///< Explicit compositor socket path.
  wl_display *server = nullptr;  ///< Test compositor.
  std::atomic<bool> running = false;  ///< Worker dispatch loop state.
  std::thread worker;  ///< Server event dispatch thread.
  std::unique_ptr<wl::display_t> display;  ///< Production client connection.
  wl::interface_t interfaces;  ///< Production registry listener.
  std::atomic<uint32_t> primaries = WP_COLOR_MANAGER_V1_PRIMARIES_BT2020;  ///< Requested color gamut.
  std::atomic<uint32_t> transfer = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ;  ///< Requested transfer function.
  std::atomic<uint32_t> max_luminance = 1000;  ///< Advertised mastering peak in nits.
  std::atomic<bool> failed_description = false;  ///< Simulate output loss.
  std::atomic<int> captures = 0;  ///< Number of capture requests actually sent.
};

TEST_F(WaylandCaptureTest, ReadsActualHdr10Metadata) {
  const auto hdr = metadata();
  ASSERT_TRUE(hdr);
  EXPECT_EQ(hdr->displayPrimaries[0].x, 35400);
  EXPECT_EQ(hdr->displayPrimaries[1].y, 39850);
  EXPECT_EQ(hdr->whitePoint.x, 15635);
  EXPECT_EQ(hdr->whitePoint.y, 16450);
  EXPECT_EQ(hdr->minDisplayLuminance, 50);
  EXPECT_EQ(hdr->maxDisplayLuminance, 1000);
  EXPECT_EQ(hdr->maxContentLightLevel, 900);
  EXPECT_EQ(hdr->maxFrameAverageLightLevel, 400);
  EXPECT_EQ(hdr->maxFullFrameLuminance, 0);
}

TEST_F(WaylandCaptureTest, RejectsSdrEvenWithWideGamut) {
  transfer = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22;
  EXPECT_FALSE(metadata());
  transfer = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ;
  primaries = WP_COLOR_MANAGER_V1_PRIMARIES_SRGB;
  EXPECT_FALSE(metadata());
}

TEST_F(WaylandCaptureTest, RejectsUnavailableColorInformation) {
  EXPECT_FALSE(wl::read_output_hdr_metadata(*display, nullptr, interfaces.monitors.front()->output));
  failed_description = true;
  EXPECT_FALSE(metadata());
}

TEST_F(WaylandCaptureTest, ClampsMetadataWithoutIntegerWraparound) {
  max_luminance = 100000;
  const auto hdr = metadata();
  ASSERT_TRUE(hdr);
  EXPECT_EQ(hdr->maxDisplayLuminance, 65535);
}

TEST_F(WaylandCaptureTest, RetainsOneCaptureAcrossTimeouts) {
  wl::dmabuf_t capture;
  const auto output = interfaces.monitors.front()->output;
  capture.listen(interfaces.screencopy_manager, nullptr, nullptr, output);
  ASSERT_TRUE(display->roundtrip());
  ASSERT_EQ(captures, 1);
  EXPECT_FALSE(display->dispatch(std::chrono::milliseconds(5)));
  capture.listen(interfaces.screencopy_manager, nullptr, nullptr, output);
  ASSERT_TRUE(display->roundtrip());
  EXPECT_EQ(captures, 1);
  capture.failed(nullptr);
  capture.listen(interfaces.screencopy_manager, nullptr, nullptr, output);
  ASSERT_TRUE(display->roundtrip());
  EXPECT_EQ(captures, 2);
}

TEST_F(WaylandCaptureTest, IgnoresNonCurrentOutputModes) {
  auto &monitor = *interfaces.monitors.front();
  monitor.wl_mode(nullptr, WL_OUTPUT_MODE_CURRENT, 2560, 1440, 120000);
  monitor.wl_mode(nullptr, WL_OUTPUT_MODE_PREFERRED, 1920, 1080, 60000);
  EXPECT_EQ(monitor.viewport.width, 2560);
  EXPECT_EQ(monitor.viewport.height, 1440);
}

TEST_F(WaylandCaptureTest, AssociatesInversionWithTheCompletedFrame) {
  wl::dmabuf_t capture;
  const auto output = interfaces.monitors.front()->output;
  capture.listen(interfaces.screencopy_manager, nullptr, nullptr, output);
  ASSERT_TRUE(display->roundtrip());
  capture.flags(nullptr, ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT);
  capture.ready(nullptr, 0, 0, 0);
  EXPECT_TRUE(capture.current_frame->y_invert);
  capture.listen(interfaces.screencopy_manager, nullptr, nullptr, output);
  ASSERT_TRUE(display->roundtrip());
  // A new request must not inherit the previous buffer's orientation.
  capture.ready(nullptr, 0, 0, 0);
  EXPECT_FALSE(capture.current_frame->y_invert);
}

TEST(WaylandFormatTest, RejectsEightBitAndUnknownHdrBuffers) {
  EXPECT_TRUE(wl::is_hdr_capture_format(DRM_FORMAT_XRGB2101010));
  EXPECT_TRUE(wl::is_hdr_capture_format(DRM_FORMAT_ABGR2101010));
  EXPECT_FALSE(wl::is_hdr_capture_format(DRM_FORMAT_XRGB8888));
  EXPECT_FALSE(wl::is_hdr_capture_format(DRM_FORMAT_NV12));
  EXPECT_FALSE(wl::is_hdr_capture_format(DRM_FORMAT_INVALID));
}

TEST(WaylandFormatTest, DoesNotInventAnUnadvertisedBufferLayout) {
  const uint64_t tiled = fourcc_mod_code(NVIDIA, 1);
  EXPECT_FALSE(wl::implicit_dmabuf_allocation({tiled}));
  EXPECT_FALSE(wl::implicit_dmabuf_allocation({tiled, DRM_FORMAT_MOD_LINEAR}));
  const auto linear = wl::implicit_dmabuf_allocation({DRM_FORMAT_MOD_LINEAR});
  ASSERT_TRUE(linear);
  EXPECT_TRUE(linear->usage & GBM_BO_USE_RENDERING);
  EXPECT_TRUE(linear->usage & GBM_BO_USE_LINEAR);
  EXPECT_EQ(linear->modifier, DRM_FORMAT_MOD_LINEAR);
}

TEST(WaylandFormatTest, PreservesImplicitModifierNegotiation) {
  const auto legacy = wl::implicit_dmabuf_allocation({});
  ASSERT_TRUE(legacy);
  EXPECT_EQ(legacy->modifier, DRM_FORMAT_MOD_INVALID);
  EXPECT_EQ(legacy->usage, GBM_BO_USE_RENDERING);
  const auto advertised = wl::implicit_dmabuf_allocation({fourcc_mod_code(AMD, 1), DRM_FORMAT_MOD_INVALID});
  ASSERT_TRUE(advertised);
  EXPECT_EQ(advertised->modifier, DRM_FORMAT_MOD_INVALID);
}

TEST_F(WaylandCaptureTest, BoundsRoundtripWhenCompositorStopsResponding) {
  running = false;
  worker.join();
  const auto start = std::chrono::steady_clock::now();
  EXPECT_FALSE(display->roundtrip());
  EXPECT_LT(std::chrono::steady_clock::now() - start, std::chrono::seconds(2));
}

TEST_F(WaylandCaptureTest, DistinguishesCompositorExitFromCaptureTimeout) {
  running = false;
  worker.join();
  wl_display_destroy_clients(server);
  EXPECT_FALSE(display->dispatch(std::chrono::milliseconds(20)));
  EXPECT_TRUE(display->has_error());
}

#endif
