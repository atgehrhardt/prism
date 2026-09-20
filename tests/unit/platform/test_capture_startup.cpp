/**
 * @file tests/unit/platform/test_capture_startup.cpp
 * @brief Verify graphics initialization against a compositor with no outputs.
 */
#if defined(PRISM_BUILD_WAYLAND) && defined(PRISM_BUILD_KWIN)

  #include "src/config.h"
  #include "src/platform/common.h"

  #include <atomic>
  #include <cstdlib>
  #include <filesystem>
  #include <glad/egl.h>
  #include <gtest/gtest.h>
  #include <kde-output-order-v1.h>
  #include <thread>
  #include <wayland-server.h>

namespace platf {
  /**
   * @brief Detect KWin support without requiring a connected output.
   *
   * @return True when KWin support is available.
   */
  bool verify_kwin();
}  // namespace platf

/**
 * @brief Test startup both with KWin support and with no desktop capture backend.
 */
class CaptureStartupTest: public testing::TestWithParam<bool> {
protected:
  /**
   * @brief Run initialization in an isolated child with a minimal, outputless compositor.
   *
   * @param advertise_kwin Whether to expose KWin's output-order protocol.
   * @return Zero when graphics initialized and KWin detection matched the protocol registry.
   */
  static int initializeWithoutOutputs(bool advertise_kwin) {
    char pattern[] = "/tmp/prism-capture-startup-XXXXXX";
    const auto directory = mkdtemp(pattern);
    if (!directory) {
      return 1;
    }
    const std::string socket = std::string(directory) + "/wayland-test";
    auto server = wl_display_create();
    if (!server || wl_display_add_socket(server, socket.c_str()) != 0) {
      return 2;
    }
    if (advertise_kwin) {
      wl_global_create(server, &kde_output_order_v1_interface, 1, nullptr, [](wl_client *client, void *, uint32_t version, uint32_t id) {
        auto resource = wl_resource_create(client, &kde_output_order_v1_interface, version, id);
        // The protocol has only a destroy request; no output events are sent.
        static void (*implementation[])(wl_client *, wl_resource *) = {
          [](wl_client *, wl_resource *target) {
            wl_resource_destroy(target);
          },
        };
        wl_resource_set_implementation(resource, implementation, nullptr, nullptr);
      });
    }
    std::atomic<bool> running {true};
    std::thread worker([&]() {
      while (running) {
        wl_event_loop_dispatch(wl_display_get_event_loop(server), 10);
        wl_display_flush_clients(server);
      }
    });
    setenv("WAYLAND_DISPLAY", socket.c_str(), 1);
    config::video.capture = "kwin";
    const auto lifetime = platf::init();
    const bool initialized = lifetime && glad_eglGetDisplay != nullptr;
    const bool detected = platf::verify_kwin() == advertise_kwin;
    running = false;
    worker.join();
    wl_display_destroy_clients(server);
    wl_display_destroy(server);
    std::filesystem::remove_all(directory);
    return initialized && detected ? 0 : 3;
  }
};

/**
 * @brief Outputless startup must still load EGL and retain available KWin support.
 */
TEST_P(CaptureStartupTest, InitializesGraphicsWithoutPhysicalDisplay) {
  // Isolate environment, EGL globals, and platform backend selection from other tests.
  const bool advertise_kwin = GetParam();
  // Bypass process-global logger destruction in the death-test child.
  ASSERT_EXIT(std::_Exit(initializeWithoutOutputs(advertise_kwin)), testing::ExitedWithCode(0), ".*");
}

INSTANTIATE_TEST_SUITE_P(OutputlessCompositor, CaptureStartupTest, testing::Bool());

#endif
