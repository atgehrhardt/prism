/**
 * @file tests/unit/platform/test_inputtino_gamepad.cpp
 * @brief Tests for Linux inputtino virtual gamepad selection.
 */
#include <gtest/gtest.h>
#include <src/platform/linux/input/inputtino_gamepad.h>

namespace {

  /**
   * @brief Build controller arrival metadata for a selection test.
   *
   * @param type Client-reported controller family.
   * @param capabilities Client-reported controller capabilities.
   * @param supported_buttons Client-reported supported button mask.
   * @return Populated controller arrival metadata.
   */
  platf::gamepad_arrival_t metadata(
    std::uint8_t type = LI_CTYPE_UNKNOWN,
    std::uint16_t capabilities = 0,
    std::uint32_t supported_buttons = 0
  ) {
    return {
      .type = type,
      .capabilities = capabilities,
      .supportedButtons = supported_buttons,
    };
  }

}  // namespace

TEST(InputtinoGamepadSelection, HonorsEachManualSelection) {
  const auto empty = metadata();

  EXPECT_EQ(platf::gamepad::select_controller_type("xone", empty, true, true), platf::gamepad::XboxOneWired);
  EXPECT_EQ(platf::gamepad::select_controller_type("ds5", empty, true, true), platf::gamepad::DualSenseWired);
  EXPECT_EQ(platf::gamepad::select_controller_type("ds5-edge", empty, true, true), platf::gamepad::DualSenseEdgeWired);
  EXPECT_EQ(platf::gamepad::select_controller_type("switch", empty, true, true), platf::gamepad::SwitchProWired);
}

TEST(InputtinoGamepadSelection, RearButtonsSelectDualSenseEdgeInAutomaticMode) {
  constexpr std::uint32_t rear_buttons[] {
    platf::PADDLE1,
    platf::PADDLE2,
    platf::PADDLE3,
    platf::PADDLE4,
    platf::PADDLE1 | platf::PADDLE2 | platf::PADDLE3 | platf::PADDLE4,
  };

  for (const auto buttons : rear_buttons) {
    const auto xbox_with_rear_buttons = metadata(LI_CTYPE_XBOX, 0, buttons);
    EXPECT_EQ(
      platf::gamepad::select_controller_type("auto", xbox_with_rear_buttons, false, false),
      platf::gamepad::DualSenseEdgeWired
    );
  }
}

TEST(InputtinoGamepadSelection, ClientControllerTypePrecedesSensors) {
  constexpr auto sensors = LI_CCAP_ACCEL | LI_CCAP_GYRO | LI_CCAP_TOUCHPAD;

  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(LI_CTYPE_XBOX, sensors), true, true),
    platf::gamepad::XboxOneWired
  );
  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(LI_CTYPE_PS, sensors), true, true),
    platf::gamepad::DualSenseWired
  );
  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(LI_CTYPE_NINTENDO, sensors), true, true),
    platf::gamepad::SwitchProWired
  );
}

TEST(InputtinoGamepadSelection, SensorsCanSelectDualSense) {
  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(LI_CTYPE_UNKNOWN, LI_CCAP_GYRO), true, false),
    platf::gamepad::DualSenseWired
  );
  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(LI_CTYPE_UNKNOWN, LI_CCAP_TOUCHPAD), false, true),
    platf::gamepad::DualSenseWired
  );
}

TEST(InputtinoGamepadSelection, DefaultsToXboxWithoutSelectionSignals) {
  EXPECT_EQ(
    platf::gamepad::select_controller_type("auto", metadata(), true, true),
    platf::gamepad::XboxOneWired
  );
  EXPECT_EQ(
    platf::gamepad::select_controller_type("unknown", metadata(LI_CTYPE_UNKNOWN, LI_CCAP_GYRO), false, false),
    platf::gamepad::XboxOneWired
  );
}

TEST(InputtinoGamepadSelection, DualSenseNamesRetainUdevCompatiblePrefix) {
  constexpr auto udev_prefix = "Prism PS5 (virtual) pad"sv;

  EXPECT_EQ(platf::gamepad::dualsense_device_name(false), udev_prefix);
  EXPECT_EQ(platf::gamepad::dualsense_device_name(true), "Prism PS5 (virtual) pad (DualSense Edge)"sv);
  EXPECT_TRUE(platf::gamepad::dualsense_device_name(true).starts_with(udev_prefix));
}
