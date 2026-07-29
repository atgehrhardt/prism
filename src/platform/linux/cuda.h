/**
 * @file src/platform/linux/cuda.h
 * @brief Definitions for CUDA implementation.
 */
#pragma once

#if defined(PRISM_BUILD_CUDA)
  // standard includes
  #include <cstdint>
  #include <memory>
  #include <optional>
  #include <string>
  #include <vector>

extern "C" {
  #include <libavutil/pixfmt.h>
}

  // local includes
  #include "src/video_colorspace.h"

namespace platf {
  struct avcodec_encode_device_t;
  struct img_t;
}  // namespace platf

namespace cuda {

  namespace nvfbc {
    std::vector<std::string> display_names();
  }

  /**
   * @brief Check whether the CUDA RAM converter supports an encoder format.
   *
   * @param format FFmpeg software pixel format requested by the encoder.
   * @return True when mapped RGB frames can be converted directly on CUDA.
   */
  bool supports_ram_frame_format(AVPixelFormat format);

  std::unique_ptr<platf::avcodec_encode_device_t> make_avcodec_encode_device(int width, int height, bool vram);

  /**
   * @brief Create a GL->CUDA encoding device for consuming captured dmabufs.
   * @param in_width Width of captured frames.
   * @param in_height Height of captured frames.
   * @param offset_x Offset of content in captured frame.
   * @param offset_y Offset of content in captured frame.
   * @return FFmpeg encoding device context.
   */
  std::unique_ptr<platf::avcodec_encode_device_t> make_avcodec_gl_encode_device(int width, int height, int offset_x, int offset_y);

  int init();
}  // namespace cuda

typedef struct cudaArray *cudaArray_t;

  #if !defined(__CUDACC__)
typedef struct CUstream_st *cudaStream_t;
typedef unsigned long long cudaTextureObject_t;
  #else /* defined(__CUDACC__) */
typedef __location__(device_builtin) struct CUstream_st *cudaStream_t;
typedef __location__(device_builtin) unsigned long long cudaTextureObject_t;
  #endif /* !defined(__CUDACC__) */

namespace cuda {

  class freeCudaPtr_t {
  public:
    void operator()(void *ptr);
  };

  class freeCudaStream_t {
  public:
    void operator()(cudaStream_t ptr);
  };

  using ptr_t = std::unique_ptr<void, freeCudaPtr_t>;
  using stream_t = std::unique_ptr<CUstream_st, freeCudaStream_t>;

  stream_t make_stream(int flags = 0);

  struct viewport_t {
    int width;
    int height;
    int offsetX;
    int offsetY;
  };

  class tex_t {
  public:
    static std::optional<tex_t> make(int height, int pitch);

    tex_t();
    tex_t(tex_t &&);

    tex_t &operator=(tex_t &&other);

    ~tex_t();

    int copy(std::uint8_t *src, int height, int pitch);

    cudaArray_t array;

    struct texture {
      cudaTextureObject_t point;
      cudaTextureObject_t linear;
    } texture;
  };

  class sws_t {
  public:
    sws_t() = default;
    sws_t(int in_width, int in_height, int out_width, int out_height, int pitch, int threadsPerBlock, ptr_t &&color_matrix);

    /**
     * in_width, in_height -- The width and height of the captured image in pixels
     * out_width, out_height -- the width and height of the NV12 image in pixels
     *
     * pitch -- The size of a single row of pixels in bytes
     */
    static std::optional<sws_t> make(int in_width, int in_height, int out_width, int out_height, int pitch);

    // Converts loaded image into a CUDevicePtr
    int convert_nv12(std::uint8_t *Y, std::uint8_t *UV, std::uint32_t pitchY, std::uint32_t pitchUV, cudaTextureObject_t texture, stream_t::pointer stream);
    int convert_nv12(std::uint8_t *Y, std::uint8_t *UV, std::uint32_t pitchY, std::uint32_t pitchUV, cudaTextureObject_t texture, stream_t::pointer stream, const viewport_t &viewport);

    /**
     * @brief Convert the configured viewport from an RGBA CUDA texture to P010.
     *
     * @param Y Destination luma plane.
     * @param UV Destination interleaved chroma plane.
     * @param pitchY Luma-plane row stride in bytes.
     * @param pitchUV Chroma-plane row stride in bytes.
     * @param texture Source RGBA CUDA texture.
     * @param stream CUDA stream on which to launch the conversion.
     * @return Zero on success, otherwise a CUDA error status.
     */
    int convert_p010(std::uint8_t *Y, std::uint8_t *UV, std::uint32_t pitchY, std::uint32_t pitchUV, cudaTextureObject_t texture, stream_t::pointer stream);

    /**
     * @brief Convert an explicit RGBA texture viewport to P010.
     *
     * @param Y Destination luma plane.
     * @param UV Destination interleaved chroma plane.
     * @param pitchY Luma-plane row stride in bytes.
     * @param pitchUV Chroma-plane row stride in bytes.
     * @param texture Source RGBA CUDA texture.
     * @param stream CUDA stream on which to launch the conversion.
     * @param viewport Source and destination region to convert.
     * @return Zero on success, otherwise a CUDA error status.
     */
    int convert_p010(std::uint8_t *Y, std::uint8_t *UV, std::uint32_t pitchY, std::uint32_t pitchUV, cudaTextureObject_t texture, stream_t::pointer stream, const viewport_t &viewport);
    int convert_yuv444(std::uint8_t *Y, std::uint8_t *U, std::uint8_t *V, std::uint32_t pitch, cudaTextureObject_t texture, stream_t::pointer stream);
    int convert_yuv444(std::uint8_t *Y, std::uint8_t *U, std::uint8_t *V, std::uint32_t pitch, cudaTextureObject_t texture, stream_t::pointer stream, const viewport_t &viewport);

    void apply_colorspace(const video::prism_colorspace_t &colorspace);

    int load_ram(platf::img_t &img, cudaArray_t array);

    ptr_t color_matrix;

    int threadsPerBlock;

    viewport_t viewport;

    float scale;
  };
}  // namespace cuda

#endif
