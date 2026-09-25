/**
 * @file src/pyrowave/encoder.h
 * @brief Dedicated Vulkan PyroWave encoder for Linux DMA-BUF capture.
 */
#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace platf {
  struct img_t;
  struct display_t;
}  // namespace platf

namespace video {
  struct config_t;
}

namespace prism_pyrowave {
  /**
   * @brief Own all GPU resources for one independently encoded stream.
   */
  class encoder {
  public:
    /**
     * @brief Initialize a Vulkan encoder for the negotiated mode.
     * @param config Validated stream configuration.
     */
    explicit encoder(const video::config_t &config);
    /**
     * @brief Release the encoder after all submitted GPU operations finish.
     */
    ~encoder();
    encoder(const encoder &) = delete;
    encoder &operator=(const encoder &) = delete;
    /**
     * @brief Import and encode a captured GPU image.
     * @param image Captured DMA-BUF, retained by the caller until return.
     * @param display Capture display providing crop and HDR state.
     * @param frame_budget Adaptive byte budget, or zero to use the initial negotiated budget.
     * @return A complete versioned transport envelope.
     * @throws std::runtime_error If GPU import, synchronization, or encoding fails.
     */
    std::vector<uint8_t> encode(platf::img_t &image, platf::display_t &display, size_t frame_budget = 0);

  private:
    struct state;  ///< Private implementation owning native handles.
    std::unique_ptr<state> impl;  ///< Session state.
  };

  /**
   * @brief Probe encoder initialization on the configured Vulkan device.
   * @return Supported server codec bits, or zero when the backend is unavailable.
   */
  uint32_t encoder_capabilities();
}  // namespace prism_pyrowave
