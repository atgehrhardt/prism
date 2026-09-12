/**
 * @file tests/unit/platform/test_dmabuf_sync.cpp
 * @brief Verify captured DMA-BUF fence waits, deadlines, and failure handling.
 */
#ifdef __linux__
  #include "src/platform/linux/dmabuf_sync.h"

  #include <gtest/gtest.h>
  #include <unistd.h>

using namespace std::chrono_literals;

/**
 * @brief Use a real pollable pipe to model an unsignaled and signaled write fence.
 */
TEST(DmabufSyncTest, WaitsForReadableDescriptors) {
  int pipe_fds[2];
  ASSERT_EQ(pipe(pipe_fds), 0);
  const int planes[4] = {pipe_fds[0], -1, pipe_fds[0], -1};
  EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 5ms), wl::dmabuf_sync_e::timeout);
  EXPECT_EQ(write(pipe_fds[1], "x", 1), 1);
  EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 1s), wl::dmabuf_sync_e::ready);
  close(pipe_fds[0]);
  close(pipe_fds[1]);
}

/**
 * @brief Reject missing frames and expired deadlines without polling.
 */
TEST(DmabufSyncTest, RejectsMissingPlanesAndExpiredDeadline) {
  const int missing[4] = {-1, -1, -1, -1};
  const int valid[4] = {42, -1, -1, -1};
  auto unexpected_poll = [](pollfd *, nfds_t, int) {
    ADD_FAILURE() << "Invalid or expired frames must not be polled";
    return 0;
  };
  EXPECT_EQ(wl::wait_for_dmabuf(missing, std::chrono::steady_clock::now() + 1s, unexpected_poll), wl::dmabuf_sync_e::error);
  EXPECT_EQ(wl::wait_for_dmabuf(valid, std::chrono::steady_clock::now() - 1s, unexpected_poll), wl::dmabuf_sync_e::timeout);
}

/**
 * @brief Keep waiting for remaining planes after only some fences signal.
 */
TEST(DmabufSyncTest, WaitsForEveryPlane) {
  const int planes[4] = {40, 41, 42, 43};
  int calls = 0;
  auto partial_poll = [&](pollfd *fds, nfds_t count, int timeout) {
    EXPECT_EQ(count, 4);
    EXPECT_GT(timeout, 0);
    for (int i = 0; i < calls; ++i) {
      EXPECT_EQ(fds[i].fd, -1);
    }
    EXPECT_EQ(fds[calls].fd, 40 + calls);
    EXPECT_EQ(fds[calls].events, POLLIN);
    fds[calls++].revents = POLLIN;
    return 1;
  };
  EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 1s, partial_poll), wl::dmabuf_sync_e::ready);
  EXPECT_EQ(calls, 4);
}

/**
 * @brief Retry interrupted waits without treating the frame as readable.
 */
TEST(DmabufSyncTest, RetriesInterruptedWaits) {
  const int planes[4] = {42, -1, -1, -1};
  int calls = 0;
  auto interrupted_poll = [&](pollfd *fds, nfds_t, int) {
    if (++calls == 1) {
      errno = EINTR;
      return -1;
    }
    fds[0].revents = POLLIN;
    return 1;
  };
  EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 1s, interrupted_poll), wl::dmabuf_sync_e::ready);
  EXPECT_EQ(calls, 2);
}

/**
 * @brief Propagate poll failures and every terminal descriptor error.
 */
TEST(DmabufSyncTest, RejectsFailedFences) {
  const int planes[4] = {42, -1, -1, -1};
  auto failed_poll = [](pollfd *, nfds_t, int) {
    errno = EIO;
    return -1;
  };
  EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 1s, failed_poll), wl::dmabuf_sync_e::error);
  for (const short error : {POLLERR, POLLHUP, POLLNVAL}) {
    auto invalid_poll = [&](pollfd *fds, nfds_t, int) {
      fds[0].revents = error | POLLIN;
      return 1;
    };
    EXPECT_EQ(wl::wait_for_dmabuf(planes, std::chrono::steady_clock::now() + 1s, invalid_poll), wl::dmabuf_sync_e::error);
  }
}
#endif
