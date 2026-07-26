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
      {},
    };
  }

  /**
   * @brief Quote a path for safe use in a shell command.
   *
   * @param path Path to quote.
   * @return Single-quoted path with embedded quotes escaped.
   */
  std::string shell_quote(const std::string &path) {
    std::string quoted {"'"};
    for (const char c : path) {
      if (c == '\'') {
        quoted += "'\\''";
      } else {
        quoted += c;
      }
    }
    quoted += "'";
    return quoted;
  }

  /**
   * @brief Find a game's box art in Steam's library cache.
   *
   * Prefers the portrait capsule (library_600x900.jpg) used for game grids,
   * falling back to the landscape header.
   *
   * @param steam_root Steam root directory.
   * @param appid Steam app id.
   * @return Path to the JPEG, or an empty path when no art is cached.
   */
  fs::path find_box_art(const fs::path &steam_root, std::uint32_t appid) {
    const fs::path cache_dir = steam_root / "appcache" / "librarycache" / std::to_string(appid);
    std::error_code ec;
    for (const char *filename : {"library_600x900.jpg", "header.jpg"}) {
      if (fs::path candidate = cache_dir / filename; fs::is_regular_file(candidate, ec)) {
        return candidate;
      }
    }
    // Legacy flat layout: librarycache/<appid>_header.jpg
    if (fs::path legacy = steam_root / "appcache" / "librarycache" / (std::to_string(appid) + "_header.jpg"); fs::is_regular_file(legacy, ec)) {
      return legacy;
    }
    return {};
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
            game->box_art = find_box_art(steam_root, game->appid);
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

  fs::path box_art_png(std::uint32_t appid, const fs::path &source) {
    const char *cache_home = std::getenv("XDG_CACHE_HOME");
    fs::path cache_root;
    if (cache_home != nullptr && *cache_home != '\0') {
      cache_root = fs::path(cache_home);
    } else if (const char *home = std::getenv("HOME"); home != nullptr && *home != '\0') {
      cache_root = fs::path(home) / ".cache";
    } else {
      return {};
    }

    std::error_code ec;

    // No local art: download from Steam's public CDN (cached, with a 24h
    // negative-cache marker so missing art is not retried on every sync).
    fs::path jpg = source;
    if (jpg.empty() || !fs::is_regular_file(jpg, ec)) {
      const fs::path art_dir = cache_root / "prism" / "steam-art";
      fs::create_directories(art_dir, ec);
      jpg = art_dir / (std::to_string(appid) + ".jpg");
      const fs::path marker = art_dir / (std::to_string(appid) + ".none");
      if (!fs::is_regular_file(jpg, ec)) {
        const auto marker_age = fs::is_regular_file(marker, ec) ? fs::last_write_time(marker, ec) : fs::file_time_type::min();
        if (marker_age < fs::file_time_type::clock::now() - std::chrono::hours(24)) {
          bool downloaded = false;
          for (const char *asset : {"library_600x900", "header"}) {
            const std::string url = "https://cdn.cloudflare.steamstatic.com/steam/apps/"s + std::to_string(appid) + "/"s + asset + ".jpg"s;
            const std::string cmd = "curl -fsSL --max-time 10 -o "s + shell_quote(jpg.string()) + " "s + shell_quote(url);
            if (std::system(cmd.c_str()) == 0 && fs::is_regular_file(jpg, ec)) {
              downloaded = true;
              break;
            }
          }
          if (!downloaded) {
            // Unreleased/very new games have no static CDN assets yet; the
            // store API still serves a header image.
            const std::string api_cmd = "curl -fsSL --max-time 10 "s + shell_quote("https://store.steampowered.com/api/appdetails?appids="s + std::to_string(appid) + "&filters=basic"s);
            if (FILE *pipe = popen(api_cmd.c_str(), "r")) {
              std::string json;
              char buf[4096];
              while (fgets(buf, sizeof(buf), pipe)) {
                json += buf;
              }
              pclose(pipe);
              static const std::regex header_re {R"re("header_image"\s*:\s*"([^"]+)")re"};
              if (std::smatch match; std::regex_search(json, match, header_re)) {
                std::string url = match[1].str();
                // JSON-escaped slashes
                size_t pos = 0;
                while ((pos = url.find("\\/", pos)) != std::string::npos) {
                  url.replace(pos, 2, "/");
                }
                const std::string cmd = "curl -fsSL --max-time 10 -o "s + shell_quote(jpg.string()) + " "s + shell_quote(url);
                downloaded = std::system(cmd.c_str()) == 0 && fs::is_regular_file(jpg, ec);
              }
            }
          }
          if (!downloaded) {
            std::ofstream(marker) << "no art";
            BOOST_LOG(debug) << "[prism] No Steam CDN box art for app "sv << appid;
            return {};
          }
        } else {
          return {};
        }
      }
    }

    const fs::path dir = cache_root / "prism" / "covers";
    fs::create_directories(dir, ec);
    if (ec) {
      return {};
    }

    const fs::path dst = dir / (std::to_string(appid) + ".png");
    // Reuse the cached PNG while it is at least as new as the JPEG source.
    if (fs::is_regular_file(dst, ec) && fs::last_write_time(dst, ec) >= fs::last_write_time(jpg, ec)) {
      return dst;
    }

    const std::string cmd = "ffmpeg -y -loglevel error -i "s + shell_quote(jpg.string()) + " "s + shell_quote(dst.string());
    if (std::system(cmd.c_str()) != 0 || !fs::is_regular_file(dst, ec)) {
      BOOST_LOG(warning) << "[prism] Could not convert Steam box art to PNG (is ffmpeg installed?): "sv << jpg;
      return {};
    }
    return dst;
  }

}  // namespace prism::steam
