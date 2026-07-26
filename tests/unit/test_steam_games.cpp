/**
 * @file tests/unit/test_steam_games.cpp
 * @brief Test src/steam_games.* functions.
 */
// test imports
#include "../tests_common.h"

// standard imports
#include <filesystem>
#include <fstream>

// local imports
#include <src/steam_games.h>

namespace fs = std::filesystem;

class SteamGamesTest: public BaseTest {
protected:
  void SetUp() override {
    BaseTest::SetUp();
    test_dir = fs::temp_directory_path() / "prism_steam_games_test";  // NOSONAR(cpp:S5443): safe for tests
    steamapps = test_dir / "steamapps";
    fs::create_directories(steamapps);

    // Main library manifest set: two games and a non-game runtime.
    write_manifest("appmanifest_440.acf", "440", "Team Fortress 2");
    write_manifest("appmanifest_730.acf", "730", "Counter-Strike 2");
    write_manifest("appmanifest_1391110.acf", "1391110", "Steam Linux Runtime 2.0 (soldier)");

    // A second library with one more game, referenced from libraryfolders.vdf.
    const fs::path lib2 = test_dir / "library2";
    fs::create_directories(lib2 / "steamapps");
    write_manifest(lib2 / "steamapps" / "appmanifest_570.acf", "570", "Dota 2");

    std::ofstream vdf(steamapps / "libraryfolders.vdf");
    vdf << R"vdf("libraryfolders"
{
	"0"
	{
		"path"		")vdf"
        << test_dir.string()
        << R"vdf("
	}
	"1"
	{
		"path"		")vdf"
        << lib2.string()
        << R"vdf("
	}
}
)vdf";
  }

  void TearDown() override {
    if (fs::exists(test_dir)) {
      fs::remove_all(test_dir);
    }
    BaseTest::TearDown();
  }

  /**
   * @brief Write a minimal Steam app manifest into a steamapps directory.
   * @param path Manifest file path (or filename inside the main steamapps dir).
   * @param appid Steam app id string.
   * @param name Display name to store in the manifest.
   */
  void write_manifest(const fs::path &path, const std::string &appid, const std::string &name) const {
    const fs::path full = path.is_absolute() ? path : steamapps / path;
    std::ofstream f(full);
    f << "\"AppState\"\n{\n\t\"appid\"\t\t\"" << appid << "\"\n\t\"name\"\t\t\"" << name << "\"\n}\n";
  }

  fs::path test_dir;  ///< Temporary Steam root for the test.
  fs::path steamapps;  ///< steamapps directory inside the test root.
};

TEST_F(SteamGamesTest, FindsGamesAcrossLibraries) {
  const auto games = prism::steam::installed_games(test_dir);
  ASSERT_EQ(games.size(), 3);

  // Sorted by name.
  EXPECT_EQ(games[0].name, "Counter-Strike 2");
  EXPECT_EQ(games[0].appid, 730u);
  EXPECT_EQ(games[1].name, "Dota 2");
  EXPECT_EQ(games[1].appid, 570u);
  EXPECT_EQ(games[2].name, "Team Fortress 2");
  EXPECT_EQ(games[2].appid, 440u);
}

TEST_F(SteamGamesTest, FiltersNonGameEntries) {
  const auto games = prism::steam::installed_games(test_dir);
  for (const auto &game : games) {
    EXPECT_NE(game.appid, 1391110u);
    EXPECT_EQ(game.name.rfind("Steam Linux Runtime", 0), std::string::npos);
  }
}

TEST_F(SteamGamesTest, SkipsManifestsWithoutName) {
  std::ofstream f(steamapps / "appmanifest_999.acf");
  f << "\"AppState\"\n{\n\t\"appid\"\t\t\"999\"\n}\n";
  f.close();
  const auto games = prism::steam::installed_games(test_dir);
  for (const auto &game : games) {
    EXPECT_NE(game.appid, 999u);
  }
  EXPECT_EQ(games.size(), 3);
}

TEST_F(SteamGamesTest, MissingSteamappsReturnsEmpty) {
  const fs::path empty_root = test_dir / "not_steam";
  fs::create_directories(empty_root);
  EXPECT_TRUE(prism::steam::installed_games(empty_root).empty());
}

TEST(SteamRootTest, FindSteamRootWithoutHome) {
  // With no HOME set, no root can be located (CI sandboxes have no Steam).
  // Just ensure it does not crash; result depends on the environment.
  (void) prism::steam::find_steam_root();
}
