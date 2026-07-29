/**
 * @file src/platform/linux/pipewire_utils.h
 * @brief Small utilities shared by PipeWire capture and its tests.
 */
#pragma once

#include "src/platform/common.h"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

namespace pipewire {
  /**
   * @brief Copy a staged mapped frame into image-owned storage.
   *
   * The image must retain independent bytes because it may remain in the
   * encoder pipeline while PipeWire replaces the producer staging buffer.
   *
   * @param producer_storage Staging storage containing the captured frame.
   * @param image_storage Storage owned by the destination capture image.
   */
  inline void copy_frame_storage(
    const std::vector<std::uint8_t> &producer_storage,
    std::vector<std::uint8_t> &image_storage
  ) {
    image_storage.assign(producer_storage.begin(), producer_storage.end());
  }

  /**
   * @brief Replace a pending PipeWire buffer without leaking its predecessor.
   *
   * PipeWire producers may deliver a newer frame before the capture thread
   * consumes the current one. The older buffer must be returned to the stream
   * before its slot is overwritten or the producer eventually exhausts its
   * buffer pool.
   *
   * @tparam Buffer PipeWire buffer or test-double type.
   * @tparam Release Callable accepting the replaced buffer pointer.
   * @param current Pending buffer slot shared with the capture thread.
   * @param replacement Newest dequeued buffer.
   * @param release Callable that returns an older buffer to its producer.
   */
  template<typename Buffer, typename Release>
  inline void replace_pending_buffer(
    Buffer *&current,
    Buffer *replacement,
    Release &&release
  ) {
    if (current != nullptr) {
      std::forward<Release>(release)(current);
    }
    current = replacement;
  }

  /**
   * @brief Back a PipeWire fallback image with an opaque black BGR0 frame.
   *
   * Software-upload encode devices must receive valid pixels during their
   * initial encoder probe. DMA-BUF encode devices may ignore these pixels and
   * continue recognizing the zero-sequence fallback descriptor.
   *
   * @param image PipeWire image descriptor to populate.
   * @param storage Image-owned storage that remains alive with the descriptor.
   * @return Zero on success, or negative one for invalid or oversized geometry.
   */
  inline int fill_black_bgr0_frame(
    platf::img_t *image,
    std::vector<std::uint8_t> &storage
  ) {
    if (image == nullptr || image->width <= 0 || image->height <= 0 ||
        image->pixel_pitch != 4 || image->row_pitch < image->width * image->pixel_pitch) {
      return -1;
    }

    const auto row_pitch = static_cast<std::size_t>(image->row_pitch);
    const auto height = static_cast<std::size_t>(image->height);
    if (height > std::numeric_limits<std::size_t>::max() / row_pitch) {
      return -1;
    }

    storage.assign(row_pitch * height, 0);
    image->data = storage.data();
    return 0;
  }
}  // namespace pipewire
