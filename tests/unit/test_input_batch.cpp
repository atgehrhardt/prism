/**
 * @file tests/unit/test_input_batch.cpp
 * @brief Verify mouse batching preserves motion and rejects signed overflow.
 */
#include "src/input_batch.h"

#include <gtest/gtest.h>

/**
 * @brief Exercise zero, signed motion, exact limits, and overflow on either axis.
 */
TEST(InputBatchTest, RelativeMotionPreservesBothAxes) {
  const int cases[][4] = {
    {0, 0, 0, 0},
    {100, -200, 300, -400},
    {-100, 200, 100, -200},
    {32766, -32767, 1, -1},
    {32767, 0, 1, 0},
    {-32768, 0, -1, 0},
    {1, 32767, 2, 1},
    {1, -32768, 2, -1},
    {32767, 32767, 1, 1},
    {-32768, -32768, -1, -1},
  };
  for (const auto &values : cases) {
    SCOPED_TRACE(testing::PrintToString(values));
    NV_REL_MOUSE_MOVE_PACKET dest {};
    NV_REL_MOUSE_MOVE_PACKET src {};
    dest.deltaX = util::endian::big(static_cast<short>(values[0]));
    dest.deltaY = util::endian::big(static_cast<short>(values[1]));
    src.deltaX = util::endian::big(static_cast<short>(values[2]));
    src.deltaY = util::endian::big(static_cast<short>(values[3]));
    const int x = values[0] + values[2];
    const int y = values[1] + values[3];
    const bool fits = x >= -32768 && x <= 32767 && y >= -32768 && y <= 32767;
    EXPECT_EQ(input::batch(&dest, &src), fits ? input::batch_result_e::batched : input::batch_result_e::terminate_batch);
    EXPECT_EQ(util::endian::big(dest.deltaX), fits ? x : values[0]);
    EXPECT_EQ(util::endian::big(dest.deltaY), fits ? y : values[1]);
    EXPECT_EQ(util::endian::big(src.deltaX), values[2]);
    EXPECT_EQ(util::endian::big(src.deltaY), values[3]);
  }
}

/**
 * @brief Verify both wheel directions sum safely and preserve rejected packets.
 */
TEST(InputBatchTest, ScrollPreservesSignedAmounts) {
  const int cases[][2] = {{0, 0}, {120, 120}, {-120, -120}, {-120, 120}, {32766, 1}, {-32767, -1}, {32767, 1}, {-32768, -1}};
  for (const auto &values : cases) {
    SCOPED_TRACE(testing::PrintToString(values));
    NV_SCROLL_PACKET vertical {};
    NV_SCROLL_PACKET next_vertical {};
    SS_HSCROLL_PACKET horizontal {};
    SS_HSCROLL_PACKET next_horizontal {};
    vertical.scrollAmt1 = vertical.scrollAmt2 = horizontal.scrollAmount = util::endian::big(static_cast<short>(values[0]));
    next_vertical.scrollAmt1 = next_vertical.scrollAmt2 = next_horizontal.scrollAmount = util::endian::big(static_cast<short>(values[1]));
    const int sum = values[0] + values[1];
    const bool fits = sum >= -32768 && sum <= 32767;
    const auto result = fits ? input::batch_result_e::batched : input::batch_result_e::terminate_batch;
    EXPECT_EQ(input::batch(&vertical, &next_vertical), result);
    EXPECT_EQ(input::batch(&horizontal, &next_horizontal), result);
    EXPECT_EQ(util::endian::big(vertical.scrollAmt1), fits ? sum : values[0]);
    EXPECT_EQ(util::endian::big(vertical.scrollAmt2), fits ? sum : values[0]);
    EXPECT_EQ(util::endian::big(horizontal.scrollAmount), fits ? sum : values[0]);
    EXPECT_EQ(util::endian::big(next_vertical.scrollAmt1), values[1]);
    EXPECT_EQ(util::endian::big(next_horizontal.scrollAmount), values[1]);
  }
}
