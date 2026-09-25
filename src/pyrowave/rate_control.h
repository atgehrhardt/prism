/**
 * @file src/pyrowave/rate_control.h
 * @brief Allocate the selected video bandwidth to frames actually emitted by capture.
 */
#pragma once

#include "protocol.h"

#include <algorithm>
#include <chrono>

namespace prism_pyrowave {
  /**
   * @brief Byte-credit controller that preserves bandwidth when capture runs below requested FPS.
   */
  class rate_control {
  public:
    /**
     * @brief Start with one nominal frame's credit and a transport-bounded reservoir.
     * @param bitrate_kbps Video bandwidth after audio and FEC adjustments.
     * @param initial_budget Validated budget at the negotiated frame rate.
     * @param maximum_budget Largest safe bitstream for one transport frame.
     * @throws std::invalid_argument If bandwidth or budget bounds are invalid.
     */
    rate_control(int bitrate_kbps, size_t initial_budget, size_t maximum_budget):
        bytes_per_second(uint64_t(std::max(0, bitrate_kbps)) * 125),
        credit(uint64_t(initial_budget) * 1000000000),
        limit(maximum_budget) {
      if (bitrate_kbps <= 0 || initial_budget < 4096 || maximum_budget < initial_budget || maximum_budget > maximum_frame_size) {
        throw std::invalid_argument("Invalid PyroWave rate-control budget");
      }
    }

    /**
     * @brief Reserve bytes earned since the preceding capture callback, retaining fractional credit.
     * @param elapsed Monotonic time since the preceding callback; zero for the first frame.
     * @return Four-byte-aligned frame budget, or zero until a minimum-sized frame is affordable.
     */
    size_t next(std::chrono::nanoseconds elapsed) {
      const uint64_t nanoseconds = uint64_t(std::max<int64_t>(0, elapsed.count()));
      const uint64_t ceiling = uint64_t(limit) * 1000000000;
      const uint64_t room = ceiling - credit;
      // Saturate before multiplying so even long pauses and extreme bitrates cannot overflow.
      if (nanoseconds >= (room + bytes_per_second - 1) / bytes_per_second) {
        credit = ceiling;
      } else {
        credit += nanoseconds * bytes_per_second;
      }
      const size_t budget = size_t(credit / 1000000000) & ~size_t(3);
      if (budget < 4096) {
        return 0;
      }
      credit -= uint64_t(budget) * 1000000000;
      return budget;
    }

  private:
    uint64_t bytes_per_second;  ///< Negotiated video bandwidth in bytes per second.
    uint64_t credit;  ///< Unspent byte credit multiplied by one billion to retain nanosecond precision.
    size_t limit;  ///< Maximum reservoir size; stalls cannot create oversized frames or long bursts.
  };
}  // namespace prism_pyrowave
