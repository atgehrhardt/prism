/**
 * @file src/input_batch.h
 * @brief Overflow-safe batching of relative mouse and wheel input packets.
 */
#pragma once

#include "utility.h"

extern "C" {
#include <moonlight-common-c/src/Input.h>
}

namespace input {
  /**
   * @brief Enumerates supported batch result options.
   */
  enum class batch_result_e {
    batched,  ///< This entry was batched with the source entry
    not_batchable,  ///< Not eligible to batch but continue attempts to batch
    terminate_batch,  ///< Stop trying to batch with this entry
  };

  /**
   * @brief Combine relative movement only when both signed deltas fit without wrapping.
   *
   * @param dest The original packet to batch into.
   * @param src A later packet to attempt to batch.
   * @return The status of the batching operation.
   */
  inline batch_result_e batch(PNV_REL_MOUSE_MOVE_PACKET dest, PNV_REL_MOUSE_MOVE_PACKET src) {
    short deltaX;
    short deltaY;

    // Batching is safe as long as the result doesn't overflow a 16-bit integer
    if (__builtin_add_overflow(util::endian::big(dest->deltaX), util::endian::big(src->deltaX), &deltaX)) {
      return batch_result_e::terminate_batch;
    }
    if (__builtin_add_overflow(util::endian::big(dest->deltaY), util::endian::big(src->deltaY), &deltaY)) {
      return batch_result_e::terminate_batch;
    }

    // Take the sum of deltas
    dest->deltaX = util::endian::big(deltaX);
    dest->deltaY = util::endian::big(deltaY);
    return batch_result_e::batched;
  }

  /**
   * @brief Batch two vertical scroll messages.
   *
   * @param dest The original packet to batch into.
   * @param src A later packet to attempt to batch.
   * @return The status of the batching operation.
   */
  inline batch_result_e batch(PNV_SCROLL_PACKET dest, PNV_SCROLL_PACKET src) {
    short scrollAmt;

    // Batching is safe as long as the result doesn't overflow a 16-bit integer
    if (__builtin_add_overflow(util::endian::big(dest->scrollAmt1), util::endian::big(src->scrollAmt1), &scrollAmt)) {
      return batch_result_e::terminate_batch;
    }

    // Take the sum of delta
    dest->scrollAmt1 = util::endian::big(scrollAmt);
    dest->scrollAmt2 = util::endian::big(scrollAmt);
    return batch_result_e::batched;
  }

  /**
   * @brief Batch two horizontal scroll messages.
   *
   * @param dest The original packet to batch into.
   * @param src A later packet to attempt to batch.
   * @return The status of the batching operation.
   */
  inline batch_result_e batch(PSS_HSCROLL_PACKET dest, PSS_HSCROLL_PACKET src) {
    short scrollAmt;

    // Batching is safe as long as the result doesn't overflow a 16-bit integer
    if (__builtin_add_overflow(util::endian::big(dest->scrollAmount), util::endian::big(src->scrollAmount), &scrollAmt)) {
      return batch_result_e::terminate_batch;
    }

    // Take the sum of delta
    dest->scrollAmount = util::endian::big(scrollAmt);
    return batch_result_e::batched;
  }

}  // namespace input
