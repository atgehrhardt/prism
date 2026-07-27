/**
 * @file src/nvenc/nvenc_utils.h
 * @brief Declarations for NVENC utilities.
 */
#pragma once

// lib includes
#include <ffnvcodec/nvEncodeAPI.h>

// local includes
#include "nvenc_colorspace.h"
#include "src/platform/common.h"
#include "src/video_colorspace.h"

namespace nvenc {

  /**
   * @brief Convert a Prism pixel format to the matching NVENC buffer format.
   *
   * @param format Pixel, audio, or protocol format being converted.
   * @return NVENC buffer format compatible with the Prism pixel format.
   */
  NV_ENC_BUFFER_FORMAT nvenc_format_from_prism_format(platf::pix_fmt_e format);

  /**
   * @brief Convert Prism colorspace metadata to NVENC VUI metadata.
   *
   * @param prism_colorspace Prism colorspace.
   * @return NVENC colorspace and VUI fields for the Prism metadata.
   */
  nvenc_colorspace_t nvenc_colorspace_from_prism_colorspace(const video::prism_colorspace_t &prism_colorspace);

}  // namespace nvenc
