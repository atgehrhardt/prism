/**
 * @file steam_games.h
 * @brief Enumerate installed Steam games so Prism can sync them into the app list.
 */
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace prism::steam {

  /**
   * @brief One installed Steam game.
   */
  struct game_t {
    std::uint32_t appid;  ///< Steam app id.
    std::string name;  ///< Display name from the app manifest.
    std::filesystem::path box_art;  ///< JPEG box art from Steam's library cache (may be empty).
  };

  /**
   * @brief Locate the user's Steam installation root.
   *
   * Checks the common native and Flatpak locations.
   *
   * @return Path to the Steam root, or std::nullopt when Steam is not installed.
   */
  std::optional<std::filesystem::path> find_steam_root();

  /**
   * @brief Enumerate installed Steam games under an explicit Steam root.
   *
   * Parses `steamapps/libraryfolders.vdf` for library paths and each library's
   * `steamapps/appmanifest_*.acf` for app ids and names. Non-game entries
   * (Proton, Steam Linux Runtimes, Steamworks Common Redistributables, SteamVR)
   * are filtered out.
   *
   * @param steam_root Steam root directory containing `steamapps`.
   * @return Installed games sorted by name; empty when none are found.
   */
  std::vector<game_t> installed_games(const std::filesystem::path &steam_root);

  /**
   * @brief Enumerate installed Steam games for the current user.
   *
   * @return Installed games sorted by name; empty when Steam is not installed.
   */
  std::vector<game_t> installed_games();

  /**
   * @brief Convert a game's JPEG box art to the PNG format Sunshine requires.
   *
   * When the source is empty, the art is first downloaded from Steam's public
   * CDN into the cache. Converts with ffmpeg into
   * `$XDG_CACHE_HOME/prism/covers/<appid>.png` (default `~/.cache`), reusing
   * the cached PNG while it is newer than the source. Steam art is JPEG-only,
   * but Sunshine's image validation requires PNG, so this bridge is needed
   * for box art to reach Moonlight clients.
   *
   * @param appid Steam app id (used as the cache file name).
   * @param source JPEG source image (typically from game_t::box_art; may be
   *   empty to trigger a CDN download).
   * @return Path to the PNG, or an empty path when art is unavailable.
   */
  std::filesystem::path box_art_png(std::uint32_t appid, const std::filesystem::path &source);

}  // namespace prism::steam
