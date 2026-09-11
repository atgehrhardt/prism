/**
 * @file src/platform/linux/wayland_hdr.cpp
 * @brief Read the selected Wayland output's HDR10 color description.
 */
#include "wayland.h"

#include <algorithm>
#include <drm_fourcc.h>
#include <unistd.h>

namespace wl {
  bool is_hdr_capture_format(uint32_t fourcc) {
    switch (fourcc) {
      case DRM_FORMAT_XRGB2101010:
      case DRM_FORMAT_ARGB2101010:
      case DRM_FORMAT_XBGR2101010:
      case DRM_FORMAT_ABGR2101010:
      case DRM_FORMAT_RGBX1010102:
      case DRM_FORMAT_RGBA1010102:
      case DRM_FORMAT_BGRX1010102:
      case DRM_FORMAT_BGRA1010102:
        return true;
      default:
        return false;
    }
  }

  std::optional<SS_HDR_METADATA> read_output_hdr_metadata(display_t &display, wp_color_manager_v1 *manager, wl_output *output) {
    if (!manager) {
      return std::nullopt;
    }

    struct description_t {
      bool ready = false;  ///< Image description is available.
      bool done = false;  ///< All information events have arrived.
      uint32_t primaries = 0;  ///< Named source color primaries.
      uint32_t transfer = 0;  ///< Named source transfer function.
      SS_HDR_METADATA metadata {};  ///< Mastering metadata, zero when unspecified.
    } state;

    static const wp_color_management_output_v1_listener output_listener = {
      .image_description_changed = [](void *, wp_color_management_output_v1 *) {
      },
    };
    static const wp_image_description_v1_listener description_listener = {
      .failed = [](void *, wp_image_description_v1 *, uint32_t, const char *) {
      },
      .ready = [](void *data, wp_image_description_v1 *, uint32_t) {
        static_cast<description_t *>(data)->ready = true;
      },
    };
    static const wp_image_description_info_v1_listener info_listener = {
      .done = [](void *data, wp_image_description_info_v1 *) {
        static_cast<description_t *>(data)->done = true;
      },
      .icc_file = [](void *, wp_image_description_info_v1 *, int32_t fd, uint32_t) {
        close(fd);
      },
      .primaries = [](void *, wp_image_description_info_v1 *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t) {
      },
      .primaries_named = [](void *data, wp_image_description_info_v1 *, uint32_t primaries) {
        static_cast<description_t *>(data)->primaries = primaries;
      },
      .tf_power = [](void *, wp_image_description_info_v1 *, uint32_t) {
      },
      .tf_named = [](void *data, wp_image_description_info_v1 *, uint32_t transfer) {
        static_cast<description_t *>(data)->transfer = transfer;
      },
      .luminances = [](void *, wp_image_description_info_v1 *, uint32_t, uint32_t, uint32_t) {
      },
      .target_primaries = [](void *data, wp_image_description_info_v1 *, int32_t rx, int32_t ry, int32_t gx, int32_t gy, int32_t bx, int32_t by, int32_t wx, int32_t wy) {
        auto &metadata = static_cast<description_t *>(data)->metadata;
        const auto coordinate = [](int32_t value) -> uint16_t {
          return std::clamp(value / 20, 0, 50000);
        };
        metadata.displayPrimaries[0] = {coordinate(rx), coordinate(ry)};
        metadata.displayPrimaries[1] = {coordinate(gx), coordinate(gy)};
        metadata.displayPrimaries[2] = {coordinate(bx), coordinate(by)};
        metadata.whitePoint = {coordinate(wx), coordinate(wy)};
      },
      .target_luminance = [](void *data, wp_image_description_info_v1 *, uint32_t minimum, uint32_t maximum) {
        auto &metadata = static_cast<description_t *>(data)->metadata;
        metadata.minDisplayLuminance = std::min(minimum, 65535u);
        metadata.maxDisplayLuminance = std::min(maximum, 65535u);
      },
      .target_max_cll = [](void *data, wp_image_description_info_v1 *, uint32_t value) {
        static_cast<description_t *>(data)->metadata.maxContentLightLevel = std::min(value, 65535u);
      },
      .target_max_fall = [](void *data, wp_image_description_info_v1 *, uint32_t value) {
        static_cast<description_t *>(data)->metadata.maxFrameAverageLightLevel = std::min(value, 65535u);
      },
    };
    auto color_output = wp_color_manager_v1_get_output(manager, output);
    wp_color_management_output_v1_add_listener(color_output, &output_listener, nullptr);
    auto description = wp_color_management_output_v1_get_image_description(color_output);
    wp_image_description_v1_add_listener(description, &description_listener, &state);
    auto cleanup = util::fail_guard([&]() {
      wp_image_description_v1_destroy(description);
      wp_color_management_output_v1_destroy(color_output);
    });
    if (!display.roundtrip() || !state.ready) {
      return std::nullopt;
    }
    auto info = wp_image_description_v1_get_information(description);
    wp_image_description_info_v1_add_listener(info, &info_listener, &state);
    const bool received = display.roundtrip() && state.done;
    wp_image_description_info_v1_destroy(info);
    if (!received || state.primaries != WP_COLOR_MANAGER_V1_PRIMARIES_BT2020 ||
        state.transfer != WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ) {
      return std::nullopt;
    }
    return state.metadata;
  }
}  // namespace wl
