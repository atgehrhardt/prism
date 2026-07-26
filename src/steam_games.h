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

}  // namespace prism::steam
