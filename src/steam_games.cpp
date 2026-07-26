/**
 * @file steam_games.cpp
 * @brief Enumerate installed Steam games so Prism can sync them into the app list.
 */
#include "steam_games.h"

#include "logging.h"

#include <algorithm>
#include <fstream>
#include <regex>
#include <set>

namespace fs = std::filesystem;
using namespace std::literals;

namespace {

  /**
   * @brief Names that are Steam support tools rather than launchable games.
   *
   * Matched as a prefix against the manifest name.
   */
  const std::vector<std::string> NON_GAME_PREFIXES = {
    "Proton "s,
    "Steam Linux Runtime"s,
    "Steamworks Common"s,
    "SteamVR"s,
    "Steam Deck"s,
  };

  /**
   * @brief Read an entire text file.
   *
   * @param path File to read.
   * @return File contents, or an empty string when the file cannot be read.
   */
  std::string read_text_file(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
      return {};
    }
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
  }

  /**
   * @brief Extract Steam library paths from libraryfolders.vdf plus the root library.
   *
   * @param steam_root Steam root directory.
   * @return Unique library directories (each containing a `steamapps` subdir).
   */
  std::vector<fs::path> library_paths(const fs::path &steam_root) {
    std::set<fs::path> paths {steam_root};
    static const std::regex path_re {R"re("path"\s+"([^"]+)")re"};
    const std::string content = read_text_file(steam_root / "steamapps" / "libraryfolders.vdf");
    for (std::sregex_iterator it(content.begin(), content.end(), path_re), end; it != end; ++it) {
      // VDF escapes backslashes; double them back for Windows-style paths.
      std::string p = (*it)[1].str();
      paths.emplace(p);
    }
    return {paths.begin(), paths.end()};
  }

  /**
   * @brief Parse one appmanifest_*.acf file into a game entry.
   *
   * @param manifest Path to the appmanifest file.
   * @return The game, or std::nullopt when the manifest lacks appid/name or is not a game.
   */
  std::optional<prism::steam::game_t> parse_manifest(const fs::path &manifest) {
    const std::string content = read_text_file(manifest);
    if (content.empty()) {
      return std::nullopt;
    }
    static const std::regex appid_re {R"re("appid"\s+"(\d+)")re"};
    static const std::regex name_re {R"re("name"\s+"([^"]*)")re"};
    std::smatch appid_match, name_match;
    if (!std::regex_search(content, appid_match, appid_re) || !std::regex_search(content, name_match, name_re)) {
      return std::nullopt;
    }
    const std::string name = name_match[1].str();
    for (const auto &prefix : NON_GAME_PREFIXES) {
      if (name.rfind(prefix, 0) == 0) {
        return std::nullopt;
      }
    }
    return prism::steam::game_t {
      static_cast<std::uint32_t>(std::stoul(appid_match[1].str())),
      name,
    };
  }

}  // namespace

namespace prism::steam {

  std::optional<fs::path> find_steam_root() {
    const char *home = std::getenv("HOME");
    if (home == nullptr || *home == '\0') {
      return std::nullopt;
    }
    const fs::path home_dir {home};
    const std::vector<fs::path> candidates = {
      home_dir / ".steam" / "root",
      home_dir / ".steam" / "steam",
      home_dir / ".local" / "share" / "Steam",
      home_dir / ".var" / "app" / "com.valvesoftware.Steam" / ".local" / "share" / "Steam",
    };
    for (const auto &candidate : candidates) {
      std::error_code ec;
      if (fs::is_directory(candidate / "steamapps", ec)) {
        return candidate;
      }
    }
    return std::nullopt;
  }

  std::vector<game_t> installed_games(const fs::path &steam_root) {
    std::vector<game_t> games;
    std::set<std::uint32_t> seen;
    for (const auto &library : library_paths(steam_root)) {
      const fs::path steamapps = library / "steamapps";
      std::error_code ec;
      if (!fs::is_directory(steamapps, ec)) {
        continue;
      }
      for (const auto &entry : fs::directory_iterator(steamapps, ec)) {
        const std::string filename = entry.path().filename().string();
        if (filename.rfind("appmanifest_", 0) != 0 || entry.path().extension() != ".acf") {
          continue;
        }
        if (auto game = parse_manifest(entry.path())) {
          if (seen.insert(game->appid).second) {
            games.emplace_back(std::move(*game));
          }
        }
      }
    }
    std::sort(games.begin(), games.end(), [](const game_t &a, const game_t &b) {
      return a.name < b.name;
    });
    return games;
  }

  std::vector<game_t> installed_games() {
    auto root = find_steam_root();
    if (!root) {
      return {};
    }
    auto games = installed_games(*root);
    BOOST_LOG(debug) << "[prism] Found "sv << games.size() << " installed Steam games"sv;
    return games;
  }

}  // namespace prism::steam
