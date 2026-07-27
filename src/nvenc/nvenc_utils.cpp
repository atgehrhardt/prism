/**
 * @file src/nvenc/nvenc_utils.cpp
 * @brief Definitions for NVENC utilities.
 */
// standard includes
#include <cassert>

// local includes
#include "nvenc_utils.h"

namespace nvenc {

  /**
   * @brief Convert a Prism pixel format to the matching NVENC buffer format.
   */
  NV_ENC_BUFFER_FORMAT nvenc_format_from_prism_format(platf::pix_fmt_e format) {
    switch (format) {
      case platf::pix_fmt_e::nv12:
        return NV_ENC_BUFFER_FORMAT_NV12;

      case platf::pix_fmt_e::p010:
        return NV_ENC_BUFFER_FORMAT_YUV420_10BIT;

      case platf::pix_fmt_e::ayuv:
        return NV_ENC_BUFFER_FORMAT_AYUV;

      case platf::pix_fmt_e::yuv444p:
        return NV_ENC_BUFFER_FORMAT_YUV444;

      case platf::pix_fmt_e::yuv444p16:
        return NV_ENC_BUFFER_FORMAT_YUV444_10BIT;

      default:
        return NV_ENC_BUFFER_FORMAT_UNDEFINED;
    }
  }

  /**
   * @brief Convert Prism colorspace metadata to NVENC VUI metadata.
   */
  nvenc_colorspace_t nvenc_colorspace_from_prism_colorspace(const video::prism_colorspace_t &prism_colorspace) {
    nvenc_colorspace_t colorspace;

    switch (prism_colorspace.colorspace) {
      case video::colorspace_e::rec601:
        // Rec. 601
        colorspace.primaries = NV_ENC_VUI_COLOR_PRIMARIES_SMPTE170M;
        colorspace.tranfer_function = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_SMPTE170M;
        colorspace.matrix = NV_ENC_VUI_MATRIX_COEFFS_SMPTE170M;
        break;

      case video::colorspace_e::rec709:
        // Rec. 709
        colorspace.primaries = NV_ENC_VUI_COLOR_PRIMARIES_BT709;
        colorspace.tranfer_function = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
        colorspace.matrix = NV_ENC_VUI_MATRIX_COEFFS_BT709;
        break;

      case video::colorspace_e::bt2020sdr:
        // Rec. 2020
        colorspace.primaries = NV_ENC_VUI_COLOR_PRIMARIES_BT2020;
        assert(prism_colorspace.bit_depth == 10);
        colorspace.tranfer_function = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT2020_10;
        colorspace.matrix = NV_ENC_VUI_MATRIX_COEFFS_BT2020_NCL;
        break;

      case video::colorspace_e::bt2020:
        // Rec. 2020 with ST 2084 perceptual quantizer
        colorspace.primaries = NV_ENC_VUI_COLOR_PRIMARIES_BT2020;
        assert(prism_colorspace.bit_depth == 10);
        colorspace.tranfer_function = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_SMPTE2084;
        colorspace.matrix = NV_ENC_VUI_MATRIX_COEFFS_BT2020_NCL;
        break;
    }

    colorspace.full_range = prism_colorspace.full_range;

    return colorspace;
  }

}  // namespace nvenc
