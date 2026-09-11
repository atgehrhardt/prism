/**
 * @file tests/unit/platform/test_kwin_output.cpp
 * @brief Verify that named KWin capture never falls back to a physical desktop.
 */
#include "src/platform/linux/kwin_output.h"

#include <gtest/gtest.h>
#include <map>
#include <memory>
#include <string>

namespace {
  /**
   * @brief Minimal compositor output description for selection tests.
   */
  struct output_t {
    std::string name;  ///< Compositor output name.
  };
}  // namespace

/**
 * @brief Select the virtual output even when a physical output is first.
 */
TEST(KWinOutput, SelectsExactName) {
  std::map<int, std::shared_ptr<output_t>> outputs {
    {1, std::make_shared<output_t>("DP-1")},
    {2, std::make_shared<output_t>("Virtual-Prism-Virtual")},
  };
  EXPECT_EQ(kwin::find_output(outputs, "Virtual-Prism-Virtual"), outputs.find(2));
  EXPECT_EQ(kwin::find_output(outputs, "DP-1"), outputs.find(1));
  EXPECT_EQ(kwin::find_output(outputs, ""), outputs.begin());
}

/**
 * @brief Reject missing or partially matching virtual outputs instead of capturing the desktop.
 */
TEST(KWinOutput, MissingOutputFailsClosed) {
  std::map<int, std::shared_ptr<output_t>> outputs {
    {1, std::make_shared<output_t>("DP-1")},
  };
  EXPECT_EQ(kwin::find_output(outputs, "Virtual-Prism-Virtual"), outputs.end());
  EXPECT_EQ(kwin::find_output(outputs, "DP"), outputs.end());
  EXPECT_EQ(kwin::find_output(outputs, "dp-1"), outputs.end());
}

/**
 * @brief Handle an empty compositor output registry for both named and default capture.
 */
TEST(KWinOutput, EmptyRegistry) {
  std::map<int, std::shared_ptr<output_t>> outputs;
  EXPECT_EQ(kwin::find_output(outputs, "Virtual-Prism-Virtual"), outputs.end());
  EXPECT_EQ(kwin::find_output(outputs, ""), outputs.end());
}
