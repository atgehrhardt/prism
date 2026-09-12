/**
 * @file src/platform/linux/dmabuf_sync.h
 * @brief Wait for compositor DMA-BUF writes before importing captured pixels.
 */
#pragma once

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <functional>
#include <limits>
#include <poll.h>

namespace wl {
  /**
   * @brief Completion status of a captured DMA-BUF's implicit write fences.
   */
  enum class dmabuf_sync_e {
    ready,  ///< Every exported plane is ready to read.
    timeout,  ///< The capture deadline expired before writes completed.
    error,  ///< A descriptor or its fence could not be polled.
  };

  /**
   * @brief Wait until every exported plane is readable without exceeding the capture deadline.
   *
   * Screencopy readiness can precede GPU completion. Explicitly polling the
   * implicit write fences prevents NVIDIA GL imports from sampling unfinished
   * compositor buffers. Interrupted waits retain the original deadline.
   *
   * @param fds Exported plane descriptors; unused entries contain negative values.
   * @param deadline Latest time at which capture may complete.
   * @param poll_fn Poll implementation used to wait for GPU writes.
   * @return Ready, timeout, or error status for the entire frame.
   */
  inline dmabuf_sync_e wait_for_dmabuf(const int (&fds)[4], std::chrono::steady_clock::time_point deadline, const std::function<int(pollfd *, nfds_t, int)> &poll_fn = ::poll) {
    pollfd planes[4] {};
    int pending = 0;
    for (int i = 0; i < 4; ++i) {
      planes[i].fd = fds[i];
      planes[i].events = POLLIN;
      pending += fds[i] >= 0;
    }
    if (pending == 0) {
      return dmabuf_sync_e::error;
    }

    while (pending > 0) {
      const auto remaining = deadline - std::chrono::steady_clock::now();
      if (remaining <= std::chrono::steady_clock::duration::zero()) {
        return dmabuf_sync_e::timeout;
      }
      const auto timeout = std::chrono::ceil<std::chrono::milliseconds>(remaining).count();
      const int result = poll_fn(planes, 4, static_cast<int>(std::min<decltype(timeout)>(timeout, std::numeric_limits<int>::max())));
      if (result < 0) {
        if (errno == EINTR) {
          continue;
        }
        return dmabuf_sync_e::error;
      }
      if (result == 0) {
        return dmabuf_sync_e::timeout;
      }
      for (auto &plane : planes) {
        if (plane.fd < 0) {
          continue;
        }
        if (plane.revents & (POLLERR | POLLHUP | POLLNVAL)) {
          return dmabuf_sync_e::error;
        }
        if (plane.revents & POLLIN) {
          plane.fd = -1;
          --pending;
        }
      }
    }
    return dmabuf_sync_e::ready;
  }
}  // namespace wl
