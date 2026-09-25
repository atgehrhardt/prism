/**
 * @file tests/unit/test_pyrowave.cpp
 * @brief PyroWave frame framing and negotiated FEC budget regression tests.
 */
#include "src/pyrowave/protocol.h"
#include "src/pyrowave/rate_control.h"

#include <array>
#include <gtest/gtest.h>
#include <random>

/**
 * @brief Spend the selected bandwidth at actual capture cadence even when Warp requests twice the FPS.
 */
TEST(PyroWaveRateControl, UsesActualCaptureCadence) {
  using namespace std::chrono_literals;
  prism_pyrowave::rate_control rate(240000, 125000, 700000);
  EXPECT_EQ(rate.next(0ns), 125000);
  EXPECT_EQ(rate.next(8333333ns), 249996);
  EXPECT_EQ(rate.next(8333334ns), 250004);
  EXPECT_EQ(rate.next(4166667ns), 125000);
  EXPECT_EQ(rate.next(4166666ns), 125000);
}

/**
 * @brief Preserve fractional credits and prevent rapid callbacks, pauses, or clock regressions from overspending.
 */
TEST(PyroWaveRateControl, BoundsCreditAndRetainsSmallIntervals) {
  using namespace std::chrono_literals;
  prism_pyrowave::rate_control rate(8000, 4096, 16384);
  EXPECT_EQ(rate.next(0ns), 4096);
  EXPECT_EQ(rate.next(0ns), 0);
  EXPECT_EQ(rate.next(-1s), 0);
  EXPECT_EQ(rate.next(1ms), 0);
  EXPECT_EQ(rate.next(3096us), 4096);
  EXPECT_EQ(rate.next(24h), 16384);
  EXPECT_EQ(rate.next(0ns), 0);
  EXPECT_EQ(rate.next(4096999ns), 4096);
  EXPECT_EQ(rate.next(4097001ns), 4096);
}

/**
 * @brief Require valid bounded budgets before constructing a per-session controller.
 */
TEST(PyroWaveRateControl, RejectsInvalidConfiguration) {
  for (int bitrate : {0, -1}) {
    EXPECT_THROW((prism_pyrowave::rate_control(bitrate, 4096, 8192)), std::invalid_argument);
  }
  EXPECT_THROW((prism_pyrowave::rate_control(8000, 4095, 8192)), std::invalid_argument);
  EXPECT_THROW((prism_pyrowave::rate_control(8000, 8192, 4096)), std::invalid_argument);
  EXPECT_THROW((prism_pyrowave::rate_control(8000, 4096, prism_pyrowave::maximum_frame_size + 1)), std::invalid_argument);
}

/**
 * @brief Keep variable-cadence spending within the selected bitrate without losing fractional credit.
 */
TEST(PyroWaveRateControl, AccountsForJitterWithoutOverspending) {
  prism_pyrowave::rate_control rate(240000, 125000, 700000);
  uint64_t spent = rate.next(std::chrono::nanoseconds(0));
  uint64_t elapsed = 0;
  for (int i = 0; i < 10000; ++i) {
    const uint64_t interval = 70001 + (i * 7919u) % 9000000;
    elapsed += interval;
    spent += rate.next(std::chrono::nanoseconds(interval));
    const uint64_t earned = 125000 + elapsed * 30000000 / 1000000000;
    EXPECT_LE(spent, earned);
    EXPECT_LT(earned - spent, 4096);
  }
  prism_pyrowave::rate_control extreme(INT32_MAX, 4096, prism_pyrowave::maximum_frame_size);
  EXPECT_EQ(extreme.next(std::chrono::nanoseconds::max()), prism_pyrowave::maximum_frame_size);
  EXPECT_EQ(extreme.next(std::chrono::nanoseconds::min()), 0);
}

/**
 * @brief Adaptive budgets must fit all four FEC blocks and the receiver's envelope allocation bound.
 */
TEST(PyroWaveRateControl, TransportCapacity) {
  for (int packet : {-1, 0, 255, 65501}) {
    EXPECT_EQ(prism_pyrowave::transport_frame_budget(packet, 20), 0);
  }
  for (int fec : {-1, 101}) {
    EXPECT_EQ(prism_pyrowave::transport_frame_budget(1392, fec), 0);
  }
  for (int packet : {256, 1024, 1392, 65500}) {
    for (int fec = 0; fec <= 100; ++fec) {
      const auto budget = prism_pyrowave::transport_frame_budget(packet, fec);
      EXPECT_GE(budget, 4096);
      EXPECT_EQ(budget % 4, 0);
      const auto envelope = budget + (budget / 8 + 1) * 4 + prism_pyrowave::header_size;
      EXPECT_LE(envelope + 8, size_t(4 * (25500 / (100 + fec)) * (packet - 16)));
      EXPECT_LE(envelope, prism_pyrowave::maximum_frame_size);
    }
  }
}

/**
 * @brief Round-trip all SDR/HDR and chroma modes without altering upstream packet bytes.
 */
TEST(PyroWaveProtocol, RoundTripModes) {
  const std::array<uint8_t, 8> first {1, 2, 3, 4, 5, 6, 7, 8};
  const std::array<uint8_t, 12> second {9, 10, 11, 12};
  for (uint8_t mode = 0; mode < 4; ++mode) {
    auto frame = prism_pyrowave::pack({{first.data(), first.size()}, {second.data(), second.size()}}, mode);
    auto packets = prism_pyrowave::unpack(frame.data(), frame.size(), mode);
    ASSERT_EQ(packets.size(), 2);
    EXPECT_EQ(std::vector<uint8_t>(packets[0].data, packets[0].data + packets[0].size), std::vector<uint8_t>(first.begin(), first.end()));
    EXPECT_EQ(std::vector<uint8_t>(packets[1].data, packets[1].data + packets[1].size), std::vector<uint8_t>(second.begin(), second.end()));
    EXPECT_TRUE(prism_pyrowave::unpack(frame.data(), frame.size(), mode ^ 1).empty());
  }
}

/**
 * @brief Reject truncation, trailing bytes, invalid lengths, and incompatible versions before decoding.
 */
TEST(PyroWaveProtocol, RejectMalformedFrames) {
  std::array<uint8_t, 8> packet {};
  auto good = prism_pyrowave::pack({{packet.data(), packet.size()}}, 0);
  for (size_t size = 0; size < good.size(); ++size) {
    EXPECT_TRUE(prism_pyrowave::unpack(good.data(), size, 0).empty());
  }
  EXPECT_TRUE(prism_pyrowave::unpack(nullptr, good.size(), 0).empty());
  EXPECT_TRUE(prism_pyrowave::unpack(good.data(), good.size(), 4).empty());
  EXPECT_TRUE(prism_pyrowave::unpack(good.data(), prism_pyrowave::maximum_frame_size + 1, 0).empty());
  for (size_t offset : {size_t(0), size_t(4), size_t(6), size_t(7)}) {
    auto frame = good;
    frame[offset] ^= 0xff;
    EXPECT_TRUE(prism_pyrowave::unpack(frame.data(), frame.size(), 0).empty());
  }
  for (uint32_t count : {0u, 2u, UINT32_MAX}) {
    auto frame = good;
    for (unsigned i = 0; i < 4; ++i) {
      frame[8 + i] = uint8_t(count >> (8 * i));
    }
    EXPECT_TRUE(prism_pyrowave::unpack(frame.data(), frame.size(), 0).empty());
  }
  for (uint32_t length : {0u, 4u, 9u, 12u, UINT32_MAX}) {
    auto frame = good;
    for (unsigned i = 0; i < 4; ++i) {
      frame[12 + i] = uint8_t(length >> (8 * i));
    }
    EXPECT_TRUE(prism_pyrowave::unpack(frame.data(), frame.size(), 0).empty());
  }
  good.push_back(0);
  EXPECT_TRUE(prism_pyrowave::unpack(good.data(), good.size(), 0).empty());
}

/**
 * @brief Reject invalid locally generated packet lists instead of emitting an ambiguous envelope.
 */
TEST(PyroWaveProtocol, RejectInvalidOutgoingPackets) {
  std::array<uint8_t, 8> packet {};
  EXPECT_THROW(prism_pyrowave::pack({}, 0), std::invalid_argument);
  EXPECT_THROW(prism_pyrowave::pack({{packet.data(), packet.size()}}, 4), std::invalid_argument);
  EXPECT_THROW(prism_pyrowave::pack({{nullptr, 8}}, 0), std::invalid_argument);
  EXPECT_THROW(prism_pyrowave::pack({{packet.data(), 4}}, 0), std::invalid_argument);
  EXPECT_THROW(prism_pyrowave::pack({{packet.data(), 7}}, 0), std::invalid_argument);
  EXPECT_THROW(prism_pyrowave::pack({{packet.data(), prism_pyrowave::packet_boundary + 4}}, 0), std::invalid_argument);
  std::vector<uint8_t> large(prism_pyrowave::packet_boundary);
  std::vector<prism_pyrowave::packet_view> many(65, {large.data(), large.size()});
  EXPECT_THROW(prism_pyrowave::pack(many, 0), std::invalid_argument);
}

/**
 * @brief Budget against actual, potentially multiplied or fractional, stream FPS.
 */
TEST(PyroWaveProtocol, ExactRateControlAndWarpRates) {
  EXPECT_EQ(prism_pyrowave::frame_budget(200000, 6000, 1392, 20), 416666);
  EXPECT_EQ(prism_pyrowave::frame_budget(200000, 12000, 1392, 20), 208333);
  EXPECT_EQ(prism_pyrowave::frame_budget(200000, 24000, 1392, 20), 104166);
  EXPECT_EQ(prism_pyrowave::frame_budget(200000, 5994, 1392, 20), 417083);
  EXPECT_EQ(prism_pyrowave::frame_budget(1000000, 6000, 1392, 20), 0);
}

/**
 * @brief Bound untrusted settings and ensure every accepted budget fits the existing FEC capacity.
 */
TEST(PyroWaveProtocol, RejectInvalidBudgets) {
  for (int invalid : {-1, 0}) {
    EXPECT_EQ(prism_pyrowave::frame_budget(invalid, 6000, 1392, 20), 0);
    EXPECT_EQ(prism_pyrowave::frame_budget(200000, invalid, 1392, 20), 0);
  }
  for (int packet : {-1, 0, 255, 65501}) {
    EXPECT_EQ(prism_pyrowave::frame_budget(200000, 6000, packet, 20), 0);
  }
  for (int fec : {-1, 101}) {
    EXPECT_EQ(prism_pyrowave::frame_budget(200000, 6000, 1392, fec), 0);
  }
  EXPECT_EQ(prism_pyrowave::frame_budget(1, 6000, 1392, 20), 0);
  EXPECT_EQ(prism_pyrowave::frame_budget(INT32_MAX, 1, 1392, 20), 0);
  for (int fec : {0, 20, 50, 100}) {
    for (int bitrate = 1000; bitrate <= 1000000; bitrate += 1000) {
      auto budget = prism_pyrowave::frame_budget(bitrate, 6000, 1392, fec);
      if (budget) {
        EXPECT_LE(budget + (budget / 8 + 1) * 4 + 12 + 8, size_t(4 * (25500 / (100 + fec)) * (1392 - 16)));
      }
    }
  }
}

/**
 * @brief Exercise malformed network data without touching GPU resources.
 */
TEST(PyroWaveProtocol, RandomFramesAreBounded) {
  std::mt19937 random(123);
  for (unsigned iteration = 0; iteration < 1000; ++iteration) {
    std::vector<uint8_t> frame(random() % 1024);
    for (auto &byte : frame) {
      byte = uint8_t(random());
    }
    EXPECT_TRUE(prism_pyrowave::unpack(frame.data(), frame.size(), 0).empty());
  }
}

/**
 * @brief Prevent dimension downgrades and overflow in the stream-rate multiplier.
 */
TEST(PyroWaveProtocol, ValidateModesAndFrameRates) {
  EXPECT_TRUE(prism_pyrowave::valid_mode(1920, 1080, 0, 0));
  EXPECT_TRUE(prism_pyrowave::valid_mode(1919, 1079, 1, 1));
  EXPECT_FALSE(prism_pyrowave::valid_mode(1919, 1080, 1, 0));
  EXPECT_FALSE(prism_pyrowave::valid_mode(1920, 1079, 1, 0));
  for (int size : {-1, 0, 16385}) {
    EXPECT_FALSE(prism_pyrowave::valid_mode(size, 1080, 0, 1));
    EXPECT_FALSE(prism_pyrowave::valid_mode(1920, size, 0, 1));
  }
  for (int mode : {-1, 2}) {
    EXPECT_FALSE(prism_pyrowave::valid_mode(1920, 1080, mode, 0));
    EXPECT_FALSE(prism_pyrowave::valid_mode(1920, 1080, 0, mode));
  }
  EXPECT_EQ(prism_pyrowave::effective_fps(60, 5994), 5994);
  EXPECT_EQ(prism_pyrowave::effective_fps(240, 0), 24000);
  EXPECT_EQ(prism_pyrowave::effective_fps(INT32_MAX, 0), 0);
  EXPECT_EQ(prism_pyrowave::effective_fps(0, 0), 0);
  EXPECT_EQ(prism_pyrowave::effective_fps(-1, 0), 0);
}

/**
 * @brief Reject malformed upstream block lengths before they can stall the codec's packet parser.
 */
TEST(PyroWaveProtocol, ValidateUpstreamBlockFraming) {
  std::vector<uint8_t> bytes;
  prism_pyrowave::append_u32(bytes, 0x80000000u | 127 | (127 << 14));
  prism_pyrowave::append_u32(bytes, 1);
  prism_pyrowave::append_u32(bytes, 2u << 16);
  prism_pyrowave::append_u32(bytes, 0);
  auto validate = [&](const std::vector<uint8_t> &data, uint8_t mode = 0) {
    return prism_pyrowave::validate_bitstream({{data.data(), data.size()}}, 128, 128, mode);
  };
  EXPECT_TRUE(validate(bytes));
  EXPECT_TRUE(validate(bytes, 1));
  EXPECT_FALSE(validate(bytes, 4));
  EXPECT_FALSE(prism_pyrowave::validate_bitstream({}, 128, 128, 0));
  EXPECT_FALSE(prism_pyrowave::validate_bitstream({{nullptr, 8}}, 128, 128, 0));
  EXPECT_FALSE(prism_pyrowave::validate_bitstream({{bytes.data(), prism_pyrowave::packet_boundary + 1}}, 128, 128, 0));
  for (size_t index : {size_t(0), size_t(2), size_t(11)}) {
    auto bad = bytes;
    bad[index] ^= 0x10;
    EXPECT_FALSE(validate(bad));
  }
  for (uint32_t length : {0u, 1u, 3u, 4095u}) {
    auto bad = bytes;
    bad[10] = uint8_t(length);
    bad[11] = uint8_t(length >> 8);
    EXPECT_FALSE(validate(bad));
  }
  auto bad = bytes;
  bad[7] = 0x04;  // 4:4:4 signaled in a negotiated 4:2:0 frame.
  EXPECT_FALSE(validate(bad));
  bad = bytes;
  bad[7] = 0x01;  // Unknown extended header type.
  EXPECT_FALSE(validate(bad));
  bad = bytes;
  bad.push_back(0);
  EXPECT_FALSE(validate(bad));
  EXPECT_FALSE(validate(std::vector<uint8_t>(bytes.begin() + 8, bytes.end())));
}
