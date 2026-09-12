/**
 * @file tests/unit/test_headless_hdr.cpp
 * @brief Validate device-profile isolation, atomic persistence and HDR calibration values.
 */
#include "src/headless_hdr.h"

#include <gtest/gtest.h>
#include <unistd.h>

/**
 * @brief Private temporary profile directory for each test.
 */
class HeadlessHdrTest: public testing::Test {
protected:
  std::filesystem::path directory;  ///< Test-owned profile directory.

  /**
   * @brief Allocate an isolated fixture directory.
   */
  void SetUp() override {
    char pattern[] = "/tmp/prism-hdr-test-XXXXXX";
    const auto path = mkdtemp(pattern);
    ASSERT_NE(path, nullptr);
    directory = path;
  }

  /**
   * @brief Remove fixture profiles and temporary files.
   */
  void TearDown() override {
    std::filesystem::remove_all(directory);
  }
};

TEST_F(HeadlessHdrTest, RejectsInvalidOrUnsupportedProfiles) {
  const auto path = directory / "profile";
  EXPECT_FALSE(prism::hdr::read(path));
  for (const auto *content : {"", "1", "2 203 1000", "1 79 1000", "1 501 1000", "1 203 202", "1 203 4001", "1 203 1000 extra", "1 nan 1000", "1 9999999999999999999 1000"}) {
    std::ofstream(path) << content;
    EXPECT_FALSE(prism::hdr::read(path)) << content;
  }
  std::ofstream(path) << "1 80 80\n";
  ASSERT_TRUE(prism::hdr::read(path));
  std::ofstream(path) << "1 500 4000\n";
  ASSERT_TRUE(prism::hdr::read(path));
}

TEST_F(HeadlessHdrTest, PersistsSeparateDevicesAndReplacesAtomically) {
  const auto odin = directory / "devices" / "certificate-a.conf";
  const auto other = directory / "devices" / "certificate-b.conf";
  prism::hdr::write(odin, {300, 750});
  prism::hdr::write(other, {203, 1000});
  prism::hdr::write(odin, {350, 800});
  ASSERT_TRUE(prism::hdr::read(odin));
  EXPECT_EQ(prism::hdr::read(odin)->sdr_white, 350);
  EXPECT_EQ(prism::hdr::read(odin)->peak, 800);
  EXPECT_EQ(prism::hdr::read(other)->sdr_white, 203);
  EXPECT_FALSE(std::filesystem::exists(odin.string() + ".tmp"));
  EXPECT_THROW(prism::hdr::write(odin, {501, 1000}), std::invalid_argument);
  EXPECT_EQ(prism::hdr::read(odin)->sdr_white, 350);
}

TEST_F(HeadlessHdrTest, ReportsSaveFailureAndCleansTemporaryFile) {
  const auto destination = directory / "occupied";
  std::filesystem::create_directory(destination);
  std::ofstream(destination / "keep") << "keep";
  EXPECT_THROW(prism::hdr::write(destination, {}), std::filesystem::filesystem_error);
  EXPECT_FALSE(std::filesystem::exists(destination.string() + ".tmp"));
  const auto file = directory / "file";
  std::ofstream(file) << "not a directory";
  EXPECT_THROW(prism::hdr::write(file / "profile", {}), std::filesystem::filesystem_error);
}

TEST(HeadlessHdrCalibration, BoundsControllerAdjustmentsAndPreservesReview) {
  prism::hdr::calibration_t state;
  state.adjust(1);
  EXPECT_EQ(state.profile.sdr_white, 213);
  for (int i = 0; i < 100; ++i) {
    state.adjust(-1);
  }
  EXPECT_EQ(state.profile.sdr_white, 80);
  for (int i = 0; i < 100; ++i) {
    state.adjust(1);
  }
  EXPECT_EQ(state.profile.sdr_white, 500);
  state.page = 1;
  for (int i = 0; i < 200; ++i) {
    state.adjust(-1);
  }
  EXPECT_EQ(state.profile.peak, 500);
  for (int i = 0; i < 200; ++i) {
    state.adjust(1);
  }
  EXPECT_EQ(state.profile.peak, 4000);
  state.page = 2;
  state.adjust(-1);
  EXPECT_EQ(state.profile.peak, 4000);
  state.profile = {203, 210};
  state.page = 0;
  state.adjust(1);
  EXPECT_EQ(state.profile.sdr_white, 210);
}

TEST(HeadlessHdrCalibration, EncodesAbsolutePqReferenceValues) {
  EXPECT_NEAR(prism::hdr::pq(0), 0, 0.000001);
  EXPECT_NEAR(prism::hdr::pq(100), 0.508078, 0.000001);
  EXPECT_NEAR(prism::hdr::pq(203), 0.580689, 0.000001);
  EXPECT_NEAR(prism::hdr::pq(1000), 0.751827, 0.000001);
  EXPECT_NEAR(prism::hdr::pq(10000), 1, 0.000001);
  EXPECT_EQ(prism::hdr::pq(-1), prism::hdr::pq(0));
  EXPECT_EQ(prism::hdr::pq(20000), prism::hdr::pq(10000));
}
