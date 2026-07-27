/**
 * @file tests/unit/test_process.cpp
 * @brief Test src/process.* functions.
 */
// test imports
#include "../tests_common.h"

// standard imports
#include <filesystem>
#include <fstream>

// local imports
#include <src/config.h>
#include <src/process.h>

namespace fs = std::filesystem;

class ProcessPNGTest: public BaseTest {
protected:
  void SetUp() override {
    BaseTest::SetUp();
    // Create test directory
    test_dir = fs::temp_directory_path() / "prism_process_png_test";  // NOSONAR(cpp:S5443): safe for tests
    fs::create_directories(test_dir);
  }

  void TearDown() override {
    // Clean up test directory
    if (fs::exists(test_dir)) {
      fs::remove_all(test_dir);
    }
    BaseTest::TearDown();
  }

  // Helper function to create a file with specific content
  void createTestFile(const fs::path &path, const std::vector<unsigned char> &content) const {
    std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char *>(content.data()), content.size());
    file.close();
  }

  fs::path test_dir;
};

// Tests for check_valid_png function
TEST_F(ProcessPNGTest, CheckValidPNG_ValidSignature) {
  // Valid PNG signature
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,  // PNG signature
    // Add some dummy data to make it more realistic
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "valid.png";
  createTestFile(test_file, valid_png_data);

  EXPECT_TRUE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_WrongSignature) {
  // Invalid PNG signature (wrong magic bytes)
  const std::vector<unsigned char> invalid_png_data = {
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "invalid.png";
  createTestFile(test_file, invalid_png_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_TooShort) {
  // File too short (less than 8 bytes)
  const std::vector<unsigned char> short_data = {
    0x89,
    0x50,
    0x4E,
    0x47
  };

  const fs::path test_file = test_dir / "short.png";
  createTestFile(test_file, short_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_EmptyFile) {
  // Empty file
  const std::vector<unsigned char> empty_data = {};

  const fs::path test_file = test_dir / "empty.png";
  createTestFile(test_file, empty_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_NonExistentFile) {
  // File doesn't exist
  const fs::path test_file = test_dir / "nonexistent.png";

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_RealFile) {
  // Test with the actual prism.png from the project root

  // Only run this test if the file exists
  if (const fs::path prism_png = fs::path(PRISM_SOURCE_DIR) / "prism.png"; fs::exists(prism_png)) {
    EXPECT_TRUE(proc::check_valid_png(prism_png));
  } else {
    GTEST_SKIP() << "prism.png not found in project root";
  }
}

TEST_F(ProcessPNGTest, CheckValidPNG_JPEGFile) {
  // JPEG signature (not PNG)
  const std::vector<unsigned char> jpeg_data = {
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46
  };

  const fs::path test_file = test_dir / "fake.png";
  createTestFile(test_file, jpeg_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

TEST_F(ProcessPNGTest, CheckValidPNG_PartialSignature) {
  // Partial PNG signature (first 4 bytes correct, rest wrong)
  const std::vector<unsigned char> partial_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "partial.png";
  createTestFile(test_file, partial_png_data);

  EXPECT_FALSE(proc::check_valid_png(test_file));
}

// Tests for validate_app_image_path function
TEST_F(ProcessPNGTest, ValidateAppImagePath_EmptyPath) {
  // Empty path should return default
  const std::string result = proc::validate_app_image_path("");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_NonPNGExtension) {
  // Non-PNG extension should return default
  const std::string result = proc::validate_app_image_path("image.jpg");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_CaseInsensitiveExtension) {
  // Test that .PNG (uppercase) is recognized
  // Create a valid PNG file
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "test.PNG";
  createTestFile(test_file, valid_png_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  // Should accept uppercase .PNG extension
  EXPECT_NE(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_NonExistentFile) {
  // Non-existent PNG file should return default
  const std::string result = proc::validate_app_image_path("/nonexistent/path/image.png");
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_InvalidPNGSignature) {
  // File with .png extension but invalid signature should return default
  const std::vector<unsigned char> invalid_data = {
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  };

  const fs::path test_file = test_dir / "invalid.png";
  createTestFile(test_file, invalid_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  EXPECT_EQ(result, DEFAULT_APP_IMAGE_PATH);
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_ValidPNG) {
  // Valid PNG file should return the path
  const std::vector<unsigned char> valid_png_data = {
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52
  };

  const fs::path test_file = test_dir / "valid.png";
  createTestFile(test_file, valid_png_data);

  const std::string result = proc::validate_app_image_path(test_file.string());
  EXPECT_EQ(result, test_file.string());
}

TEST_F(ProcessPNGTest, ValidateAppImagePath_OldSteamDefault) {
  // Test the special case for old steam image path
  const std::string result = proc::validate_app_image_path("./assets/steam.png");
  EXPECT_EQ(result, PRISM_ASSETS_DIR "/steam.png");
}

// Tests for parsing the Prism per-app capture mode from apps.json
class ProcessParseTest: public BaseTest {
protected:
  void SetUp() override {
    BaseTest::SetUp();
    // Steam game sync would otherwise append the host's real Steam library.
    setenv("PRISM_STEAM_SYNC", "0", 1);
    test_file = fs::temp_directory_path() / "prism_process_parse_test_apps.json";  // NOSONAR(cpp:S5443): safe for tests
  }

  void TearDown() override {
    unsetenv("PRISM_STEAM_SYNC");
    fs::remove(test_file);
    BaseTest::TearDown();
  }

  fs::path test_file;
};

TEST_F(ProcessParseTest, Parse_PrismCaptureField) {
  std::ofstream file(test_file);
  file << R"json({
    "env": {},
    "apps": [
      {"name": "Desktop"},
      {"name": "Desktop (Virtual)", "prism-capture": "virtual"},
      {"name": "SteamOS (Headless)", "prism-capture": "steamos"},
      {"name": "TV", "prism-capture": "portal:HDMI-A-1"},
      {"name": "My Game", "prism-capture": "headless"},
      {"name": "Steam Game", "prism-capture": "headless"}
    ]
  })json";
  file.close();

  auto proc_opt = proc::parse(test_file.string());
  ASSERT_TRUE(proc_opt.has_value());
  const auto &apps = proc_opt->get_apps();
  ASSERT_EQ(apps.size(), 6);
  EXPECT_TRUE(apps[0].prism_capture.empty());
  EXPECT_EQ(apps[1].prism_capture, "virtual");
  EXPECT_EQ(apps[2].prism_capture, "steamos");
  EXPECT_EQ(apps[3].prism_capture, "portal:HDMI-A-1");
  EXPECT_EQ(apps[4].prism_capture, "headless");
  EXPECT_EQ(apps[5].prism_capture, "headless");
}

// Tests for Prism capture mode resolution precedence.
class CaptureModeResolveTest: public BaseTest {
protected:
  void SetUp() override {
    BaseTest::SetUp();
    saved_default = config::stream.prism_capture_default;
  }

  void TearDown() override {
    config::stream.prism_capture_default = saved_default;
    BaseTest::TearDown();
  }

  /**
   * @brief Build a minimal app context.
   * @param name Application name.
   * @param capture Explicit prism-capture value (may be empty).
   * @param cmd Application command (may be empty).
   * @return Application context with the fields the resolver reads set.
   */
  static proc::ctx_t makeApp(const std::string &name, const std::string &capture = "", const std::string &cmd = "") {
    proc::ctx_t ctx {};
    ctx.name = name;
    ctx.prism_capture = capture;
    ctx.cmd = cmd;
    return ctx;
  }

  std::string saved_default;  ///< Saved prism_capture_default to restore after each test.
};

TEST_F(CaptureModeResolveTest, ExplicitValueWinsOverNameAndConfig) {
  config::stream.prism_capture_default = "headless";
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("My Steam Game", "virtual"));
  EXPECT_EQ(resolved.mode, "virtual");
  EXPECT_FALSE(resolved.steam);
}

TEST_F(CaptureModeResolveTest, SteamosAliasEnablesSteam) {
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("Anything", "steamos"));
  EXPECT_EQ(resolved.mode, "headless");
  EXPECT_TRUE(resolved.steam);
}

TEST_F(CaptureModeResolveTest, NameHeuristicsBeatConfiguredDefault) {
  config::stream.prism_capture_default = "headless";
  const auto virtual_app = proc::prism_resolve_capture_mode(makeApp("Desktop (Virtual)"));
  EXPECT_EQ(virtual_app.mode, "virtual");
  const auto steam_app = proc::prism_resolve_capture_mode(makeApp("Steam Headless"));
  EXPECT_EQ(steam_app.mode, "headless");
  EXPECT_TRUE(steam_app.steam);
}

TEST_F(CaptureModeResolveTest, ConfiguredDefaultAppliesToPlainNames) {
  config::stream.prism_capture_default = "headless";
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("My Game"));
  EXPECT_EQ(resolved.mode, "headless");
  EXPECT_FALSE(resolved.steam);
}

TEST_F(CaptureModeResolveTest, PortalDefaultPassesThrough) {
  config::stream.prism_capture_default = "portal:HDMI-A-1";
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("My Game"));
  EXPECT_EQ(resolved.mode, "portal:HDMI-A-1");
}

TEST_F(CaptureModeResolveTest, EmptyDefaultFallsBackToDesktopMirror) {
  config::stream.prism_capture_default = "";
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("My Game"));
  EXPECT_EQ(resolved.mode, "default");
  EXPECT_FALSE(resolved.steam);
}

TEST_F(CaptureModeResolveTest, RungameidCommandForcesSteamSession) {
  // A synced game imported with a plain "headless" mode must still get Steam
  // session behavior (session Steam + launch wrapper), or the game launches
  // on the desktop and its exit never ends the stream.
  const auto imported = proc::prism_resolve_capture_mode(makeApp("9 Kings", "headless", "steam steam://rungameid/2784470"));
  EXPECT_EQ(imported.mode, "headless");
  EXPECT_TRUE(imported.steam);

  // Even with no explicit mode and a configured global default.
  config::stream.prism_capture_default = "virtual";
  const auto generated = proc::prism_resolve_capture_mode(makeApp("9 Kings", "", "steam steam://rungameid/2784470"));
  EXPECT_EQ(generated.mode, "headless");
  EXPECT_TRUE(generated.steam);
}

TEST_F(CaptureModeResolveTest, ExplicitNonHeadlessModeStillWinsForGames) {
  const auto resolved = proc::prism_resolve_capture_mode(makeApp("9 Kings", "virtual", "steam steam://rungameid/2784470"));
  EXPECT_EQ(resolved.mode, "virtual");
  EXPECT_FALSE(resolved.steam);
}

/**
 * @brief Tests validation of atomically published headless session state.
 */
class HeadlessStateTest: public BaseTest {
protected:
  void SetUp() override {
    BaseTest::SetUp();
    state_path = fs::temp_directory_path() / "prism_headless_state_test";
  }

  void TearDown() override {
    fs::remove(state_path);
    BaseTest::TearDown();
  }

  /**
   * @brief Write headless state content for one parser test.
   *
   * @param content Complete state file content.
   */
  void writeState(const std::string &content) const {
    std::ofstream state(state_path);
    state << content;
  }

  fs::path state_path;  ///< Temporary state file used by the test.
};

TEST_F(HeadlessStateTest, AcceptsCompleteMatchingState) {
  writeState(
    "version=2\n"
    "session_id=42\n"
    "backend=systemd\n"
    "unit=prism-headless-session.service\n"
    "app_unit=prism-headless-app-42.scope\n"
    "steam=1\n"
    "wayland_display=gamescope-7\n"
    "x_display=:9\n"
    "physical_sink=speakers\n"
    "capture_sink_module=\n"
    "session_sink_module=123\n"
    "loop_module=456\n"
  );

  const auto state = proc::prism_read_headless_state(state_path, "42");
  ASSERT_TRUE(state.has_value());
  EXPECT_EQ(state->version, 2);
  EXPECT_EQ(state->session_id, "42");
  EXPECT_TRUE(state->steam);
  EXPECT_EQ(state->wayland_display, "gamescope-7");
  EXPECT_EQ(state->x_display, ":9");
  EXPECT_EQ(state->session_sink_module, "123");
}

TEST_F(HeadlessStateTest, RejectsAnotherLaunchSession) {
  writeState(
    "version=2\nsession_id=41\nbackend=systemd\n"
    "unit=prism-headless-session.service\napp_unit=prism-headless-app-41.scope\nsteam=0\n"
    "wayland_display=gamescope-0\nx_display=:2\nphysical_sink=\n"
    "capture_sink_module=\nsession_sink_module=123\nloop_module=456\n"
  );
  EXPECT_FALSE(proc::prism_read_headless_state(state_path, "42").has_value());
}

TEST_F(HeadlessStateTest, RejectsLegacyOrIncompleteState) {
  writeState("steam=1\nwayland_display=gamescope-0\nx_display=:2\n");
  EXPECT_FALSE(proc::prism_read_headless_state(state_path, "42").has_value());
}

TEST_F(HeadlessStateTest, RejectsGuessedOrMalformedDisplays) {
  writeState(
    "version=2\nsession_id=42\nbackend=systemd\n"
    "unit=prism-headless-session.service\napp_unit=prism-headless-app-42.scope\nsteam=0\n"
    "wayland_display=wayland-prism\nx_display=desktop\nphysical_sink=\n"
    "capture_sink_module=\nsession_sink_module=123\nloop_module=456\n"
  );
  EXPECT_FALSE(proc::prism_read_headless_state(state_path, "42").has_value());
}

TEST_F(HeadlessStateTest, RejectsDuplicateKeys) {
  writeState(
    "version=2\nsession_id=42\nsession_id=43\nbackend=systemd\n"
    "unit=prism-headless-session.service\napp_unit=prism-headless-app-42.scope\nsteam=0\n"
    "wayland_display=gamescope-0\nx_display=:2\nphysical_sink=\n"
    "capture_sink_module=\nsession_sink_module=123\nloop_module=456\n"
  );
  EXPECT_FALSE(proc::prism_read_headless_state(state_path, "42").has_value());
}
