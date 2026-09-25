/**
 * @file src/pyrowave/compositor.h
 * @brief GPU aspect-fit scaling and cursor composition on the codec's Vulkan device.
 */
#pragma once
#if defined(PRISM_ENABLE_PYROWAVE) && defined(PRISM_BUILD_VULKAN)
  #include "api.h"

  #include <memory>

namespace egl {
  class img_descriptor_t;
}

namespace platf {
  struct display_t;
}

namespace prism_pyrowave {
  /**
   * @brief Own a GPU compositor whose output remains valid until the next call.
   */
  class compositor {
  public:
    /**
     * @brief Allocate composition resources on the codec's device.
     * @param device Borrowed codec device, which must outlive this compositor.
     * @param width Encoded frame width.
     * @param height Encoded frame height.
     */
    compositor(pyrowave_device device, int width, int height);
    /**
     * @brief Wait for pending work and release owned GPU objects.
     */
    ~compositor();
    /**
     * @brief Compose an imported frame and release its external ownership.
     * @param source Imported capture image view.
     * @param ready Semaphore signaling capture completion.
     * @param descriptor Capture and cursor metadata.
     * @param display Crop and HDR metadata.
     * @return GPU view of the composited, aspect-fit RGB output.
     */
    pyrowave_image_view compose(const pyrowave_image_view &source, VkSemaphore ready, const egl::img_descriptor_t &descriptor, platf::display_t &display);

  private:
    struct state;  ///< Native resource implementation.
    std::unique_ptr<state> impl;  ///< Owned composition resources.
  };
}  // namespace prism_pyrowave
#endif
