/**
 * @file src/process.cpp
 * @brief Definitions for the startup and shutdown of the apps started by a streaming Session.
 */
#define BOOST_BIND_GLOBAL_PLACEHOLDERS

// standard includes
#include <cctype>
#include <charconv>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// lib includes
#include <boost/algorithm/string.hpp>
#include <boost/crc.hpp>
#include <boost/filesystem.hpp>
#include <boost/program_options/parsers.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/token_functions.hpp>
#include <openssl/evp.h>
#include <openssl/sha.h>

// local includes
#include "config.h"
#include "crypto.h"
#include "display_device.h"
#include "logging.h"
#include "platform/common.h"
#include "process.h"
#include "steam_games.h"
#include "system_tray.h"
#include "utility.h"

namespace proc {
  using namespace std::literals;
  namespace pt = boost::property_tree;

  proc_t proc;  ///< Global process registry used to track and terminate child processes.

  /**
   * @brief RAII helper that runs shutdown cleanup when destroyed.
   */
  class deinit_t: public platf::deinit_t {
  public:
    /**
     * @brief Destroy the process subsystem deinitializer.
     */
    ~deinit_t() {
      proc.terminate();
    }
  };

  std::unique_ptr<platf::deinit_t> init() {
    return std::make_unique<deinit_t>();
  }

  void terminate_process_group(boost::process::v1::child &proc, boost::process::v1::group &group, std::chrono::seconds exit_timeout) {
    if (group.valid() && platf::process_group_running((std::uintptr_t) group.native_handle())) {
      if (exit_timeout.count() > 0) {
        // Request processes in the group to exit gracefully
        if (platf::request_process_group_exit((std::uintptr_t) group.native_handle())) {
          // If the request was successful, wait for a little while for them to exit.
          BOOST_LOG(info) << "Successfully requested the app to exit. Waiting up to "sv << exit_timeout.count() << " seconds for it to close."sv;

          // group::wait_for() and similar functions are broken and deprecated, so we use a simple polling loop
          while (platf::process_group_running((std::uintptr_t) group.native_handle()) && (--exit_timeout).count() >= 0) {
            std::this_thread::sleep_for(1s);
          }

          if (exit_timeout.count() < 0) {
            BOOST_LOG(warning) << "App did not fully exit within the timeout. Terminating the app's remaining processes."sv;
          } else {
            BOOST_LOG(info) << "All app processes have successfully exited."sv;
          }
        } else {
          BOOST_LOG(info) << "App did not respond to a graceful termination request. Forcefully terminating the app's processes."sv;
        }
      } else {
        BOOST_LOG(info) << "No graceful exit timeout was specified for this app. Forcefully terminating the app's processes."sv;
      }

      // We always call terminate() even if we waited successfully for all processes above.
      // This ensures the process group state is consistent with the OS in boost.
      std::error_code ec;
      group.terminate(ec);
      group.detach();
    }

    if (proc.valid()) {
      // avoid zombie process
      proc.detach();
    }
  }

  /**
   * @brief Resolve the working directory for a configured command.
   *
   * @param cmd Command line to execute or inspect.
   * @param env Environment variables for the child process.
   * @return Directory used to launch the command, falling back to PATH lookup when needed.
   */
  boost::filesystem::path find_working_directory(const std::string &cmd, boost::process::v1::environment &env) {
    // Parse the raw command string into parts to get the actual command portion
    std::vector<std::string> parts;
    try {
      parts = boost::program_options::split_unix(cmd);
    } catch (boost::escaped_list_error &err) {
      BOOST_LOG(error) << "Boost failed to parse command ["sv << cmd << "] because " << err.what();
      return boost::filesystem::path();
    }
    if (parts.empty()) {
      BOOST_LOG(error) << "Unable to parse command: "sv << cmd;
      return boost::filesystem::path();
    }

    BOOST_LOG(debug) << "Parsed target ["sv << parts.at(0) << "] from command ["sv << cmd << ']';

    // If the target is a URL, don't parse any further here
    if (parts.at(0).find("://") != std::string::npos) {
      return boost::filesystem::path();
    }

    // If the cmd path is not an absolute path, resolve it using our PATH variable
    boost::filesystem::path cmd_path(parts.at(0));
    if (!cmd_path.is_absolute()) {
      cmd_path = boost::process::v1::search_path(parts.at(0));
      if (cmd_path.empty()) {
        BOOST_LOG(error) << "Unable to find executable ["sv << parts.at(0) << "]. Is it in your PATH?"sv;
        return boost::filesystem::path();
      }
    }

    BOOST_LOG(debug) << "Resolved target ["sv << parts.at(0) << "] to path ["sv << cmd_path << ']';

    // Now that we have a complete path, we can just use parent_path()
    return cmd_path.parent_path();
  }

  /**
   * @brief Get the runtime directory used for Prism's per-stream capture override file.
   * @return `$XDG_RUNTIME_DIR`, falling back to `/run/user/<uid>`.
   */
  static std::string prism_runtime_dir() {
    const char *runtime_dir = std::getenv("XDG_RUNTIME_DIR");
    if (runtime_dir != nullptr && *runtime_dir != '\0') {
      return runtime_dir;
    }
    return "/run/user/" + std::to_string(::getuid());
  }

  /**
   * @brief Check whether an app name indicates a Steam app.
   * @param name Application name.
   * @return True when the name contains "steam" (any case).
   */
  static bool prism_name_is_steam(const std::string &name) {
    return boost::to_lower_copy(name).find("steam") != std::string::npos;
  }

  /**
   * @brief Check whether an app command launches a Steam game directly.
   *
   * Such apps always need Steam session behavior (desktop Steam handoff,
   * session Steam client, launch wrapper) regardless of the app's name or how
   * its capture mode was set — e.g. after a synced game was imported as an
   * override with a plain "headless" mode.
   *
   * @param app Application context.
   * @return True when the command is a Steam rungameid URL launch.
   */
  static bool prism_cmd_is_steam_game(const ctx_t &app) {
    return app.cmd.rfind("steam steam://rungameid/"s, 0) == 0;
  }

  prism_capture_mode_t prism_resolve_capture_mode(const ctx_t &app) {
    if (!app.prism_capture.empty()) {
      if (app.prism_capture == "steamos"s) {
        // Legacy alias: headless session with Steam behavior.
        return {"headless"s, true};
      }
      if (app.prism_capture == "headless"s) {
        return {"headless"s, prism_name_is_steam(app.name) || prism_cmd_is_steam_game(app)};
      }
      return {app.prism_capture, false};
    }
    // A direct Steam game launch always needs a Steam headless session,
    // regardless of name heuristics or the configured default.
    if (prism_cmd_is_steam_game(app)) {
      return {"headless"s, true};
    }
    const std::string lower_name = boost::to_lower_copy(app.name);
    if (lower_name.find("virtual") != std::string::npos) {
      return {"virtual"s, false};
    }
    if (lower_name.find("headless") != std::string::npos) {
      return {"headless"s, prism_name_is_steam(app.name) || prism_cmd_is_steam_game(app)};
    }
    if (prism_name_is_steam(app.name)) {
      return {"headless"s, true};
    }
    // Configured global default for apps without an explicit mode; unknown or
    // empty values fall back to mirroring the session. (Non-Steam names reach
    // this point, so a headless default never implies Steam behavior.)
    if (!config::stream.prism_capture_default.empty()) {
      return {config::stream.prism_capture_default, false};
    }
    return {"default"s, false};
  }

  std::optional<std::string> prism_parse_wlroots_capture_override(
    const std::string_view capture_override
  ) {
    constexpr auto prefix = "wlroots:"sv;
    if (!capture_override.starts_with(prefix)) {
      return std::nullopt;
    }

    const auto session_id = capture_override.substr(prefix.size());
    if (session_id.empty() || session_id.size() > 128 ||
        !std::all_of(
          session_id.begin(),
          session_id.end(),
          [](const unsigned char character) {
            return std::isalnum(character) != 0 ||
                   character == '_' || character == '.' || character == '-';
          }
        )) {
      return std::nullopt;
    }
    return std::string(session_id);
  }

  std::optional<prism_headless_state_t> prism_read_headless_state(
    const std::filesystem::path &path,
    const std::string &expected_session_id
  ) {
    std::ifstream state_file(path);
    if (!state_file) {
      return std::nullopt;
    }

    std::unordered_map<std::string, std::string> values;
    std::string line;
    while (std::getline(state_file, line)) {
      const auto separator = line.find('=');
      if (separator == std::string::npos || separator == 0) {
        return std::nullopt;
      }
      auto [iter, inserted] = values.emplace(line.substr(0, separator), line.substr(separator + 1));
      if (!inserted) {
        return std::nullopt;
      }
    }
    constexpr std::size_t headless_state_field_count = 18;  ///< Exact version-four state field count.
    if (values.size() != headless_state_field_count) {
      return std::nullopt;
    }

    const auto required = [&values](const std::string &key) -> const std::string * {
      const auto iter = values.find(key);
      return iter == values.end() ? nullptr : &iter->second;
    };
    const auto *version = required("version"s);
    const auto *session_id = required("session_id"s);
    const auto *backend = required("backend"s);
    const auto *unit = required("unit"s);
    const auto *input_unit = required("input_unit"s);
    const auto *steam_unit = required("steam_unit"s);
    const auto *app_unit = required("app_unit"s);
    const auto *steam = required("steam"s);
    const auto *wayland_display = required("wayland_display"s);
    const auto *output_name = required("output_name"s);
    const auto *x_display = required("x_display"s);
    const auto *width = required("width"s);
    const auto *height = required("height"s);
    const auto *framerate = required("framerate"s);
    const auto *physical_sink = required("physical_sink"s);
    const auto *capture_sink_module = required("capture_sink_module"s);
    const auto *session_sink_module = required("session_sink_module"s);
    const auto *loop_module = required("loop_module"s);
    if (version == nullptr || session_id == nullptr || backend == nullptr ||
        unit == nullptr || input_unit == nullptr || steam_unit == nullptr ||
        app_unit == nullptr || steam == nullptr || wayland_display == nullptr ||
        output_name == nullptr || x_display == nullptr || width == nullptr ||
        height == nullptr || framerate == nullptr || physical_sink == nullptr ||
        capture_sink_module == nullptr || session_sink_module == nullptr ||
        loop_module == nullptr) {
      return std::nullopt;
    }

    const auto all_digits = [](const auto begin, const auto end) {
      return begin != end && std::all_of(begin, end, [](const unsigned char character) {
               return std::isdigit(character) != 0;
             });
    };
    const bool valid_session_id = !session_id->empty() && session_id->size() <= 128 &&
                                  std::all_of(session_id->begin(), session_id->end(), [](const unsigned char character) {
                                    return std::isalnum(character) != 0 ||
                                           character == '_' || character == '.' || character == '-';
                                  });
    const bool valid_x_display = x_display->size() > 1 && x_display->front() == ':' &&
                                 all_digits(x_display->begin() + 1, x_display->end());
    const bool valid_physical_sink = !physical_sink->empty() && physical_sink->size() <= 255 &&
                                     std::all_of(
                                       physical_sink->begin(),
                                       physical_sink->end(),
                                       [](const unsigned char character) {
                                         return std::isalnum(character) != 0 ||
                                                character == '_' || character == '.' || character == '-';
                                       }
                                     );
    const auto parse_bounded = [&all_digits](const std::string &value, std::uint64_t maximum) -> std::optional<std::uint64_t> {
      if (!all_digits(value.begin(), value.end())) {
        return std::nullopt;
      }
      std::uint64_t parsed = 0;
      const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
      if (result.ec != std::errc {} || result.ptr != value.data() + value.size() || parsed == 0 || parsed > maximum) {
        return std::nullopt;
      }
      return parsed;
    };
    const auto parse_module = [&all_digits](const std::string &value) -> std::optional<std::uint32_t> {
      if (!all_digits(value.begin(), value.end())) {
        return std::nullopt;
      }
      std::uint32_t parsed = 0;
      const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
      if (result.ec != std::errc {} || result.ptr != value.data() + value.size()) {
        return std::nullopt;
      }
      return parsed;
    };
    const bool valid_wayland_prefix = wayland_display->rfind("wayland-", 0) == 0;
    const auto parsed_wayland_display = valid_wayland_prefix ?
                                          parse_module(wayland_display->substr(8)) :
                                          std::nullopt;
    const auto parsed_width = parse_bounded(*width, 16384);
    const auto parsed_height = parse_bounded(*height, 16384);
    const auto parsed_framerate = parse_bounded(*framerate, 1000);
    const auto parsed_x_display = valid_x_display ?
                                    parse_module(x_display->substr(1)) :
                                    std::nullopt;
    const auto parsed_capture_module = capture_sink_module->empty() ?
                                         std::optional<std::uint32_t> {0} :
                                         parse_module(*capture_sink_module);
    const auto parsed_session_module = parse_module(*session_sink_module);
    const auto parsed_loop_module = parse_module(*loop_module);
    if (*version != "4"sv || *session_id != expected_session_id ||
        !valid_session_id || *backend != "systemd"sv ||
        *unit != "prism-headless-session.service"sv ||
        *input_unit != "prism-input-bridge.service"sv ||
        *steam_unit != "prism-headless-steam.service"sv ||
        *app_unit != "prism-headless-app-"s + expected_session_id + ".scope"s ||
        (*steam != "0"sv && *steam != "1"sv) ||
        !parsed_wayland_display || *parsed_wayland_display > 127 ||
        *output_name != "HEADLESS-1"sv ||
        !valid_x_display || !valid_physical_sink || !parsed_width ||
        !parsed_height || !parsed_framerate || !parsed_x_display ||
        *parsed_x_display > 127 ||
        !parsed_capture_module || !parsed_session_module || !parsed_loop_module) {
      return std::nullopt;
    }

    return prism_headless_state_t {
      .version = 4,
      .session_id = *session_id,
      .backend = *backend,
      .unit = *unit,
      .input_unit = *input_unit,
      .steam_unit = *steam_unit,
      .app_unit = *app_unit,
      .steam = *steam == "1"sv,
      .wayland_display = *wayland_display,
      .output_name = *output_name,
      .x_display = *x_display,
      .width = static_cast<int>(*parsed_width),
      .height = static_cast<int>(*parsed_height),
      .framerate = static_cast<int>(*parsed_framerate),
      .physical_sink = *physical_sink,
      .capture_sink_module = *capture_sink_module,
      .session_sink_module = *session_sink_module,
      .loop_module = *loop_module,
    };
  }

  /**
   * @brief Resolve an installed session helper.
   *
   * @param script Session helper file name without directory components.
   * @return Executable helper path, or an empty path when it is unavailable.
   */
  static std::filesystem::path prism_session_script_path(const std::string &script) {
    if (script.empty() || script == "."sv || script == ".."sv || script.find('/') != std::string::npos || script.find('\\') != std::string::npos) {
      return {};
    }

    const auto executable_script = [&script](const std::filesystem::path &directory) {
      const auto candidate = directory / script;
      std::error_code error;
      const auto status = std::filesystem::status(candidate, error);
      if (error || !std::filesystem::is_regular_file(status)) {
        return std::filesystem::path {};
      }
      const auto permissions = status.permissions();
      constexpr auto executable = std::filesystem::perms::owner_exec |
                                  std::filesystem::perms::group_exec |
                                  std::filesystem::perms::others_exec;
      return (permissions & executable) == std::filesystem::perms::none ?
               std::filesystem::path {} :
               candidate;
    };

    if (const char *override_dir = std::getenv("PRISM_SESSION_DIR"); override_dir != nullptr && *override_dir != '\0') {
      return executable_script(override_dir);
    }

    if (auto candidate = executable_script(PRISM_SESSION_DIR); !candidate.empty()) {
      return candidate;
    }
    if (const char *home = std::getenv("HOME"); home != nullptr && *home != '\0') {
      return executable_script(std::filesystem::path(home) / ".local/bin");
    }
    return {};
  }

  /**
   * @brief Run one of Prism's session scripts synchronously, like a prep command.
   *
   * @param script Session helper file name.
   * @param env Environment for the child process (carries the PRISM_CLIENT_* variables).
   * @param pipe Optional log sink for the script's output.
   * @return 0 on success, -1 on failure.
   */
  static int prism_run_session_script(const std::string &script, boost::process::v1::environment &env, FILE *pipe) {
    const auto script_path = prism_session_script_path(script);
    if (script_path.empty()) {
      BOOST_LOG(error) << "[prism] Session helper is unavailable: "sv << script;
      return -1;
    }
    std::error_code ec;
    const std::string command = script_path.string();
    boost::filesystem::path working_dir = find_working_directory(command, env);
    BOOST_LOG(info) << "[prism] Executing: ["sv << command << ']';
    auto child = platf::run_command(false, true, command, working_dir, env, pipe, ec, nullptr);
    if (ec) {
      BOOST_LOG(error) << "[prism] Couldn't run ["sv << command << "]: System: "sv << ec.message();
      return -1;
    }
    child.wait(ec);
    if (ec) {
      BOOST_LOG(error) << "[prism] ["sv << command << "] wait failed with error code ["sv << ec << ']';
      return -1;
    }
    auto ret = child.exit_code();
    if (ret != 0) {
      BOOST_LOG(error) << "[prism] ["sv << command << "] exited with code ["sv << ret << ']';
      return -1;
    }
    return 0;
  }

  int reconcile_stale_capture_state() {
#ifdef __linux__
    boost::process::v1::environment environment = boost::this_process::environment();
    return prism_run_session_script("prism-session-cleanup.sh"s, environment, nullptr);
#else
    return 0;
#endif
  }

  /**
   * @brief Serializes Prism capture bring-up and teardown.
   *
   * proc_t::prism_capture_begin() and proc_t::prism_capture_end() run on
   * several threads (nvhttp launch, the app-exit poll, the web UI closeApp
   * handler); without mutual exclusion a delayed teardown can interleave with
   * the next bring-up and undo its state (e.g. deleting the capture override
   * the new session just armed). File-scope rather than a member so proc_t
   * stays movable; the guarded resources (session scripts, override file)
   * are process-global anyway.
   */
  static std::mutex prism_capture_mutex;

  int proc_t::prism_capture_begin() {
    // Serialize with prism_capture_end(): a delayed teardown from the previous
    // app must fully finish before this bring-up arms new session state.
    std::lock_guard<std::mutex> lock(prism_capture_mutex);
    const auto resolved = prism_resolve_capture_mode(_app);
    const std::string &mode = resolved.mode;
    BOOST_LOG(info) << "[prism] Capture mode for app '"sv << _app.name << "': "sv << mode
                    << (resolved.steam ? " (steam)"sv : ""sv);
    // Remember the mode for prism_capture_end(): _app may be mutated below
    // (Steam game launches rewrite _app.cmd) or be stale by the time teardown
    // runs, so re-resolving at end time can pick the wrong teardown path.
    _prism_active_mode = mode;

    if (mode == "headless"sv) {
      // A generated Steam game app carries its launch target as
      // "steam steam://rungameid/<appid>". Hand the appid to the start script
      // (PRISM_STEAM_APP_ID), which brings up a silent background Steam client
      // with the game URL on its initial command line. Replace
      // the app command with the lifecycle monitor, which exits with the game
      // so closing the game ends the app and therefore the stream.
      const bool had_steam_app = _env.count("PRISM_STEAM_APP_ID") != 0;
      const std::string old_steam_app = had_steam_app ? _env["PRISM_STEAM_APP_ID"].to_string() : std::string();
      constexpr std::string_view rungameid_prefix = "steam steam://rungameid/"sv;
      if (resolved.steam && _app.cmd.rfind(std::string(rungameid_prefix), 0) == 0) {
        const std::string appid = _app.cmd.substr(rungameid_prefix.size());
        _env["PRISM_STEAM_APP_ID"] = appid;
        _app.cmd = "prism-steam-game.sh "s + appid;
      } else {
        _env.erase("PRISM_STEAM_APP_ID");
      }
      // PRISM_STEAM controls whether the session runs Steam (SteamOS behavior);
      // export it for the start script only, then restore the previous state.
      const bool had_prism_steam = _env.count("PRISM_STEAM") != 0;
      const std::string old_prism_steam = had_prism_steam ? _env["PRISM_STEAM"].to_string() : std::string();
      _env["PRISM_STEAM"] = resolved.steam ? "1" : "0";
      const int rc = prism_run_session_script("prism-headless-start.sh"s, _env, _pipe.get());
      if (had_prism_steam) {
        _env["PRISM_STEAM"] = old_prism_steam;
      } else {
        _env.erase("PRISM_STEAM");
      }
      if (had_steam_app) {
        _env["PRISM_STEAM_APP_ID"] = old_steam_app;
      } else {
        _env.erase("PRISM_STEAM_APP_ID");
      }
      if (rc != 0) {
        return -1;
      }
      const std::string expected_session_id = _env["PRISM_SESSION_ID"].to_string();
      const auto state = prism_read_headless_state(
        prism_runtime_dir() + "/prism-headless.state",
        expected_session_id
      );
      if (!state) {
        BOOST_LOG(error) << "[prism] Headless session did not publish valid state for launch "sv
                         << expected_session_id;
        return -1;
      }
      _env["PRISM_HEADLESS_BACKEND"] = state->backend;
      _env["PRISM_HEADLESS_UNIT"] = state->unit;
      _env["PRISM_HEADLESS_INPUT_UNIT"] = state->input_unit;
      _env["PRISM_HEADLESS_STEAM_UNIT"] = state->steam_unit;
      _env["PRISM_HEADLESS_APP_UNIT"] = state->app_unit;
      _prism_had_pulse_prop = _env.count("PULSE_PROP") != 0;
      _prism_old_pulse_prop = _prism_had_pulse_prop ? _env["PULSE_PROP"].to_string() : std::string();
      _env["PULSE_PROP"] = (_prism_old_pulse_prop.empty() ? std::string() : _prism_old_pulse_prop + " "s) +
                           "prism.session.id="s + state->session_id;
      _prism_env_overridden = true;
      if (!_app.cmd.empty()) {
        // Run the app's own command directly inside the private labwc session.
        // Only verified,
        // session-owned socket names are accepted from its atomic state.
        _env["WAYLAND_DISPLAY"] = state->wayland_display;
        _env["DISPLAY"] = state->x_display;
        // Route the app's audio to the headless session's dedicated sink so
        // only session audio is captured (see prism-headless-audio.sh).
        _env["PULSE_SINK"] = "prism-headless"s;
        _env["PRISM_HEADLESS_APP_COMMAND"] = _app.cmd;
        if (_app.working_dir.empty()) {
          _app.working_dir = find_working_directory(_app.cmd, _env).string();
        }
        _app.cmd = "prism-headless-exec.sh"s;
        BOOST_LOG(info) << "[prism] App command will run inside the private labwc session (WAYLAND_DISPLAY="sv
                        << state->wayland_display << ", DISPLAY="sv << state->x_display
                        << ", session="sv << state->session_id << ')';
      }
      return 0;
    }

    if (mode == "virtual"sv) {
      return prism_run_session_script("prism-virtual-start.sh"s, _env, _pipe.get());
    }

    if (mode.rfind("portal:", 0) == 0) {
      const std::string override_path = prism_runtime_dir() + "/prism-capture-override";
      std::error_code ec;
      std::filesystem::create_directories(std::filesystem::path(override_path).parent_path(), ec);
      std::ofstream override_file(override_path, std::ios::trunc);
      override_file << mode << '\n';
      if (!override_file) {
        BOOST_LOG(error) << "[prism] Failed to write capture override file ["sv << override_path << ']';
        return -1;
      }
      BOOST_LOG(info) << "[prism] Wrote capture override '"sv << mode << "' to ["sv << override_path << ']';
      // Portal outputs show the desktop; route desktop audio like mirror mode.
      return prism_run_session_script("prism-mirror-audio.sh"s, _env, _pipe.get());
    }

    if (mode != "default"sv) {
      BOOST_LOG(warning) << "[prism] Unknown capture mode '"sv << mode << "'; using default capture"sv;
    }
    // Mirror (default) capture: Prism records the dedicated "prism-stream"
    // capture sink, so desktop audio must be looped into it explicitly.
    return prism_run_session_script("prism-mirror-audio.sh"s, _env, _pipe.get());
  }

  void proc_t::prism_capture_end() {
    // Serialize with prism_capture_begin(): see the mutex comment there.
    std::lock_guard<std::mutex> lock(prism_capture_mutex);
    // Use the mode captured at bring-up so teardown is symmetric with it.
    // Fall back to resolving the (possibly stale) app only if begin never ran.
    std::string mode = _prism_active_mode;
    if (mode.empty()) {
      if (_app_id <= 0) {
        // No app is (or was) running and no capture mode was brought up;
        // nothing to tear down.
        return;
      }
      mode = prism_resolve_capture_mode(_app).mode;
    }
    _prism_active_mode.clear();
    BOOST_LOG(info) << "[prism] Tearing down capture mode '"sv << mode << "' for app '"sv << _app.name << "'";

    // Restore the environment that prism_capture_begin() may have overridden
    // for a headless app command, so the next app launches on the desktop again.
    // _env is a copy made at parse time; the process environment still holds
    // the original values.
    if (_prism_env_overridden) {
      _prism_env_overridden = false;
      for (const char *var : {"WAYLAND_DISPLAY", "DISPLAY", "PULSE_SINK"}) {
        const char *original = std::getenv(var);
        if (original != nullptr) {
          _env[var] = original;
        } else {
          _env.erase(var);
        }
      }
      _env.erase("PRISM_HEADLESS_BACKEND");
      _env.erase("PRISM_HEADLESS_UNIT");
      _env.erase("PRISM_HEADLESS_INPUT_UNIT");
      _env.erase("PRISM_HEADLESS_STEAM_UNIT");
      _env.erase("PRISM_HEADLESS_APP_UNIT");
      _env.erase("PRISM_HEADLESS_APP_COMMAND");
      if (_prism_had_pulse_prop) {
        _env["PULSE_PROP"] = _prism_old_pulse_prop;
      } else {
        _env.erase("PULSE_PROP");
      }
      _prism_had_pulse_prop = false;
      _prism_old_pulse_prop.clear();
    }

    if (mode == "headless"sv) {
      prism_run_session_script("prism-headless-stop.sh"s, _env, _pipe.get());
      _env.erase("PRISM_SESSION_ID");
    } else if (mode == "virtual"sv) {
      prism_run_session_script("prism-virtual-stop.sh"s, _env, _pipe.get());
    } else {
      if (mode.rfind("portal:", 0) == 0) {
        const std::string override_path = prism_runtime_dir() + "/prism-capture-override";
        std::error_code ec;
        std::filesystem::remove(override_path, ec);
        if (ec) {
          BOOST_LOG(warning) << "[prism] Failed to remove capture override file ["sv << override_path << "]: "sv << ec.message();
        }
      }
      // Mirror and portal-output streams both use the mirror audio router.
      _env["PRISM_AUDIO_ACTION"] = "stop"s;
      prism_run_session_script("prism-mirror-audio.sh"s, _env, _pipe.get());
      _env.erase("PRISM_AUDIO_ACTION");
    }
  }

  int proc_t::execute(int app_id, std::shared_ptr<rtsp_stream::launch_session_t> launch_session) {
    // Ensure starting from a clean slate
    terminate();

    auto iter = std::find_if(_apps.begin(), _apps.end(), [&app_id](const auto app) {
      return app.id == std::to_string(app_id);
    });

    if (iter == _apps.end()) {
      BOOST_LOG(error) << "Couldn't find app with ID ["sv << app_id << ']';
      return 404;
    }

    _app_id = app_id;
    _app = *iter;
    _app_prep_begin = std::begin(_app.prep_cmds);
    _app_prep_it = _app_prep_begin;

    // Add Stream-specific environment variables
    _env["PRISM_APP_ID"] = std::to_string(_app_id);
    _env["PRISM_APP_NAME"] = _app.name;
    _env["PRISM_SESSION_ID"] = std::to_string(launch_session->id);
    _env["PRISM_CLIENT_WIDTH"] = std::to_string(launch_session->width);
    _env["PRISM_CLIENT_HEIGHT"] = std::to_string(launch_session->height);
    _env["PRISM_CLIENT_FPS"] = std::to_string(launch_session->fps);
    _env["PRISM_CLIENT_HDR"] = launch_session->enable_hdr ? "true" : "false";
    _env["PRISM_CLIENT_GCMAP"] = std::to_string(launch_session->gcmap);
    _env["PRISM_CLIENT_HOST_AUDIO"] = launch_session->host_audio ? "true" : "false";
    _env["PRISM_CLIENT_ENABLE_SOPS"] = launch_session->enable_sops ? "true" : "false";
    int channelCount = launch_session->surround_info & 65535;
    switch (channelCount) {
      case 2:
        _env["PRISM_CLIENT_AUDIO_CONFIGURATION"] = "2.0";
        break;
      case 6:
        _env["PRISM_CLIENT_AUDIO_CONFIGURATION"] = "5.1";
        break;
      case 8:
        _env["PRISM_CLIENT_AUDIO_CONFIGURATION"] = "7.1";
        break;
    }
    _env["PRISM_CLIENT_AUDIO_SURROUND_PARAMS"] = launch_session->surround_params;

    if (!_app.output.empty() && _app.output != "null"sv) {
      _pipe.reset(fopen(_app.output.c_str(), "a"));
    }

    std::error_code ec;
    // Executed when returning from function
    auto fg = util::fail_guard([&]() {
      terminate();
    });

    // Prism: act on the app's capture mode before any prep commands run and
    // long before the stream's display initializes (display() reads the
    // capture override file at display init).
    if (prism_capture_begin() != 0) {
      return -1;
    }

    for (; _app_prep_it != std::end(_app.prep_cmds); ++_app_prep_it) {
      auto &cmd = *_app_prep_it;

      // Skip empty commands
      if (cmd.do_cmd.empty()) {
        continue;
      }

      boost::filesystem::path working_dir = _app.working_dir.empty() ?
                                              find_working_directory(cmd.do_cmd, _env) :
                                              boost::filesystem::path(_app.working_dir);
      BOOST_LOG(info) << "Executing Do Cmd: ["sv << cmd.do_cmd << ']';
      auto child = platf::run_command(cmd.elevated, true, cmd.do_cmd, working_dir, _env, _pipe.get(), ec, nullptr);

      if (ec) {
        BOOST_LOG(error) << "Couldn't run ["sv << cmd.do_cmd << "]: System: "sv << ec.message();
        // We don't want any prep commands failing launch of the desktop.
        // This is to prevent the issue where users reboot their PC and need to log in with Prism.
        // permission_denied is typically returned when the user impersonation fails, which can happen when user is not signed in yet.
        if (!(_app.cmd.empty() && ec == std::errc::permission_denied)) {
          return -1;
        }
      }

      child.wait(ec);
      if (ec) {
        BOOST_LOG(error) << '[' << cmd.do_cmd << "] wait failed with error code ["sv << ec << ']';
        return -1;
      }
      auto ret = child.exit_code();
      if (ret != 0) {
        BOOST_LOG(error) << '[' << cmd.do_cmd << "] exited with code ["sv << ret << ']';
        return -1;
      }
    }

    for (auto &cmd : _app.detached) {
      boost::filesystem::path working_dir = _app.working_dir.empty() ?
                                              find_working_directory(cmd, _env) :
                                              boost::filesystem::path(_app.working_dir);
      BOOST_LOG(info) << "Spawning ["sv << cmd << "] in ["sv << working_dir << ']';
      auto child = platf::run_command(_app.elevated, true, cmd, working_dir, _env, _pipe.get(), ec, nullptr);
      if (ec) {
        BOOST_LOG(warning) << "Couldn't spawn ["sv << cmd << "]: System: "sv << ec.message();
      } else {
        child.detach();
      }
    }

    if (_app.cmd.empty()) {
      BOOST_LOG(info) << "Executing [Desktop]"sv;
      placebo = true;
    } else {
      boost::filesystem::path working_dir = _app.working_dir.empty() ?
                                              find_working_directory(_app.cmd, _env) :
                                              boost::filesystem::path(_app.working_dir);
      BOOST_LOG(info) << "Executing: ["sv << _app.cmd << "] in ["sv << working_dir << ']';
      _process = platf::run_command(_app.elevated, true, _app.cmd, working_dir, _env, _pipe.get(), ec, &_process_group);
      if (ec) {
        BOOST_LOG(warning) << "Couldn't run ["sv << _app.cmd << "]: System: "sv << ec.message();
        return -1;
      }
    }

    _app_launch_time = std::chrono::steady_clock::now();

    fg.disable();

    return 0;
  }

  int proc_t::running() {
    // On POSIX OSes, we must periodically wait for our children to avoid
    // them becoming zombies. This must be synchronized carefully with
    // calls to bp::wait() and platf::process_group_running() which both
    // invoke waitpid() under the hood.
    auto reaper = util::fail_guard([]() {
      while (waitpid(-1, nullptr, WNOHANG) > 0);
    });

    if (placebo) {
      return _app_id;
    } else if (_app.wait_all && _process_group && platf::process_group_running((std::uintptr_t) _process_group.native_handle())) {
      // The app is still running if any process in the group is still running
      return _app_id;
    } else if (_process.running()) {
      // The app is still running only if the initial process launched is still running
      return _app_id;
    } else if (_app.auto_detach && _process.native_exit_code() == 0 && std::chrono::steady_clock::now() - _app_launch_time < 5s) {
      BOOST_LOG(info) << "App exited gracefully within 5 seconds of launch. Treating the app as a detached command."sv;
      BOOST_LOG(info) << "Adjust this behavior in the Applications tab or apps.json if this is not what you want."sv;
      placebo = true;
      return _app_id;
    }

    // Perform cleanup actions now if needed
    if (_process) {
      BOOST_LOG(info) << "App exited with code ["sv << _process.native_exit_code() << ']';
      terminate();
    }

    return 0;
  }

  void proc_t::terminate() {
    std::error_code ec;
    placebo = false;
    terminate_process_group(_process, _process_group, _app.exit_timeout);
    _process = boost::process::v1::child();
    _process_group = boost::process::v1::group();

    // Prism: undo the capture mode before running prep "undo" commands.
    prism_capture_end();

    for (; _app_prep_it != _app_prep_begin; --_app_prep_it) {
      auto &cmd = *(_app_prep_it - 1);

      if (cmd.undo_cmd.empty()) {
        continue;
      }

      boost::filesystem::path working_dir = _app.working_dir.empty() ?
                                              find_working_directory(cmd.undo_cmd, _env) :
                                              boost::filesystem::path(_app.working_dir);
      BOOST_LOG(info) << "Executing Undo Cmd: ["sv << cmd.undo_cmd << ']';
      auto child = platf::run_command(cmd.elevated, true, cmd.undo_cmd, working_dir, _env, _pipe.get(), ec, nullptr);

      if (ec) {
        BOOST_LOG(warning) << "System: "sv << ec.message();
      }

      child.wait();
      auto ret = child.exit_code();

      if (ret != 0) {
        BOOST_LOG(warning) << "Return code ["sv << ret << ']';
      }
    }

    _pipe.reset();

    bool has_run = _app_id > 0;

    // Only show the Stopped notification if we actually have an app to stop
    // Since terminate() is always run when a new app has started
    if (proc::proc.get_last_run_app_name().length() > 0 && has_run) {
#if defined PRISM_TRAY && PRISM_TRAY >= 1
      system_tray::update_tray_stopped(proc::proc.get_last_run_app_name());
#endif

      display_device::revert_configuration();
    }

    _app_id = -1;
  }

  const std::vector<ctx_t> &proc_t::get_apps() const {
    return _apps;
  }

  void proc_t::replace_apps(std::vector<ctx_t> &&apps) {
    _apps = std::move(apps);
  }

  std::vector<ctx_t> &proc_t::get_apps() {
    return _apps;
  }

  // Gets application image from application list.
  // Returns image from assets directory if found there.
  // Returns default image if image configuration is not set.
  // Returns http content-type header compatible image type.
  std::string proc_t::get_app_image(int app_id) {
    auto iter = std::find_if(_apps.begin(), _apps.end(), [&app_id](const auto app) {
      return app.id == std::to_string(app_id);
    });
    auto app_image_path = iter == _apps.end() ? std::string() : iter->image_path;

    return validate_app_image_path(app_image_path);
  }

  std::string proc_t::get_last_run_app_name() {
    return _app.name;
  }

  proc_t::~proc_t() {
    // It's not safe to call terminate() here because our proc_t is a static variable
    // that may be destroyed after the Boost loggers have been destroyed. Instead,
    // we return a deinit_t to main() to handle termination when we're exiting.
    // Once we reach this point here, termination must have already happened.
    assert(!placebo);
    assert(!_process.running());
  }

  /**
   * @brief Find the closing parenthesis for an environment-variable expression.
   *
   * @param begin Iterator positioned at the opening parenthesis.
   * @param end End iterator for the expression being scanned.
   * @return Iterator for the matching closing parenthesis, or end when unmatched.
   */
  std::string_view::iterator find_match(std::string_view::iterator begin, std::string_view::iterator end) {
    int stack = 0;

    --begin;
    do {
      ++begin;
      switch (*begin) {
        case '(':
          ++stack;
          break;
        case ')':
          --stack;
      }
    } while (begin != end && stack != 0);

    if (begin == end) {
      throw std::out_of_range("Missing closing bracket \')\'");
    }
    return begin;
  }

  /**
   * @brief Parse env val.
   *
   * @param env Environment variables for the child process.
   * @param val_raw Raw value that may contain $(NAME) substitutions.
   * @return Value with recognized environment-variable substitutions expanded.
   */
  std::string parse_env_val(boost::process::v1::native_environment &env, const std::string_view &val_raw) {
    auto pos = std::begin(val_raw);
    auto dollar = std::find(pos, std::end(val_raw), '$');

    std::stringstream ss;

    while (dollar != std::end(val_raw)) {
      auto next = dollar + 1;
      if (next != std::end(val_raw)) {
        switch (*next) {
          case '(':
            {
              ss.write(pos, (dollar - pos));
              auto var_begin = next + 1;
              auto var_end = find_match(next, std::end(val_raw));
              auto var_name = std::string {var_begin, var_end};

              ss << env[var_name].to_string();

              pos = var_end + 1;
              next = var_end;

              break;
            }
          case '$':
            ss.write(pos, (next - pos));
            pos = next + 1;
            ++next;
            break;
        }

        dollar = std::find(next, std::end(val_raw), '$');
      } else {
        dollar = next;
      }
    }

    ss.write(pos, (dollar - pos));

    return ss.str();
  }

  /**
   * @brief Validates a path whether it is a valid PNG.
   * @param path The path to the PNG file.
   * @return true if the file has a valid PNG signature, false otherwise.
   */
  bool check_valid_png(const std::filesystem::path &path) {
    // PNG signature as defined in PNG specification
    // http://www.libpng.org/pub/png/spec/1.2/PNG-Structure.html
    static constexpr std::array<unsigned char, 8> PNG_SIGNATURE = {
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A
    };

    std::ifstream file(path, std::ios::binary);
    if (!file) {
      return false;
    }

    std::array<unsigned char, 8> header;
    file.read(reinterpret_cast<char *>(header.data()), 8);

    if (file.gcount() != 8) {
      return false;
    }

    return header == PNG_SIGNATURE;
  }

  /**
   * @brief Validate app image path.
   */
  std::string validate_app_image_path(std::string app_image_path) {
    if (app_image_path.empty()) {
      return DEFAULT_APP_IMAGE_PATH;
    }

    // get the image extension and convert it to lowercase
    auto image_extension = std::filesystem::path(app_image_path).extension().string();
    boost::to_lower(image_extension);

    // return the default box image if the extension is not "png"
    if (image_extension != ".png") {
      return DEFAULT_APP_IMAGE_PATH;
    }

    // check if image is in assets directory
    if (auto full_image_path = std::filesystem::path(PRISM_ASSETS_DIR) / app_image_path; std::filesystem::exists(full_image_path)) {
      // Validate PNG signature
      if (!check_valid_png(full_image_path)) {
        BOOST_LOG(warning) << "Invalid PNG file at path ["sv << full_image_path << ']';
        return DEFAULT_APP_IMAGE_PATH;
      }
      return full_image_path.string();
    }

    if (app_image_path == "./assets/steam.png") {
      // handle old default steam image definition
      return PRISM_ASSETS_DIR "/steam.png";
    }

    // check if specified image exists
    if (std::error_code code; !std::filesystem::exists(app_image_path, code)) {
      // return default box image if image does not exist
      BOOST_LOG(warning) << "Couldn't find app image at path ["sv << app_image_path << ']';
      return DEFAULT_APP_IMAGE_PATH;
    }

    // Validate PNG signature
    if (!check_valid_png(app_image_path)) {
      BOOST_LOG(warning) << "Invalid PNG file at path ["sv << app_image_path << ']';
      return DEFAULT_APP_IMAGE_PATH;
    }

    // image is a png, and not in assets directory
    // return only "content-type" http header compatible image type
    return app_image_path;
  }

  /**
   * @brief Calculate the SHA-256 digest for a file.
   *
   * @param filename File path whose contents should be hashed.
   * @return Lowercase hexadecimal SHA-256 digest, or std::nullopt on read/hash failure.
   */
  std::optional<std::string> calculate_sha256(const std::string &filename) {
    crypto::md_ctx_t ctx {EVP_MD_CTX_create()};
    if (!ctx) {
      return std::nullopt;
    }

    if (!EVP_DigestInit_ex(ctx.get(), EVP_sha256(), nullptr)) {
      return std::nullopt;
    }

    // Read file and update calculated SHA
    char buf[1024 * 16];
    std::ifstream file(filename, std::ifstream::binary);
    while (file.good()) {
      file.read(buf, sizeof(buf));
      if (!EVP_DigestUpdate(ctx.get(), buf, file.gcount())) {
        return std::nullopt;
      }
    }
    file.close();

    unsigned char result[SHA256_DIGEST_LENGTH];
    if (!EVP_DigestFinal_ex(ctx.get(), result, nullptr)) {
      return std::nullopt;
    }

    // Transform byte-array to string
    std::stringstream ss;
    ss << std::hex << std::setfill('0');
    for (const auto &byte : result) {
      ss << std::setw(2) << (int) byte;
    }
    return ss.str();
  }

  /**
   * @brief Calculate the CRC-32 checksum for a string.
   *
   * @param input Bytes to include in the checksum.
   * @return CRC-32 value for the input bytes.
   */
  uint32_t calculate_crc32(const std::string &input) {
    boost::crc_32_type result;
    result.process_bytes(input.data(), input.length());
    return result.checksum();
  }

  std::tuple<std::string, std::string> calculate_app_id(const std::string &app_name, std::string app_image_path, int index) {
    // Generate id by hashing name with image data if present
    std::vector<std::string> to_hash;
    to_hash.push_back(app_name);
    auto file_path = validate_app_image_path(app_image_path);
    if (file_path != DEFAULT_APP_IMAGE_PATH) {
      auto file_hash = calculate_sha256(file_path);
      if (file_hash) {
        to_hash.push_back(file_hash.value());
      } else {
        // Fallback to just hashing image path
        to_hash.push_back(file_path);
      }
    }

    // Create combined strings for hash
    std::stringstream ss;
    for_each(to_hash.begin(), to_hash.end(), [&ss](const std::string &s) {
      ss << s;
    });
    auto input_no_index = ss.str();
    ss << index;
    auto input_with_index = ss.str();

    // CRC32 then truncate to signed 32-bit range due to client limitations
    auto id_no_index = std::to_string(abs((int32_t) calculate_crc32(input_no_index)));
    auto id_with_index = std::to_string(abs((int32_t) calculate_crc32(input_with_index)));

    return std::make_tuple(id_no_index, id_with_index);
  }

  /**
   * @brief Parse serialized text into the corresponding runtime representation.
   */
  std::optional<proc::proc_t> parse(const std::string &file_name) {
    pt::ptree tree;

    try {
      pt::read_json(file_name, tree);

      auto &apps_node = tree.get_child("apps"s);
      auto &env_vars = tree.get_child("env"s);

      auto this_env = boost::this_process::environment();

      for (auto &[name, val] : env_vars) {
        this_env[name] = parse_env_val(this_env, val.get_value<std::string>());
      }

      std::set<std::string> ids;
      std::vector<proc::ctx_t> apps;
      int i = 0;
      for (auto &[_, app_node] : apps_node) {
        proc::ctx_t ctx;

        auto prep_nodes_opt = app_node.get_child_optional("prep-cmd"s);
        auto detached_nodes_opt = app_node.get_child_optional("detached"s);
        auto exclude_global_prep = app_node.get_optional<bool>("exclude-global-prep-cmd"s);
        auto output = app_node.get_optional<std::string>("output"s);
        auto name = parse_env_val(this_env, app_node.get<std::string>("name"s));
        auto cmd = app_node.get_optional<std::string>("cmd"s);
        auto image_path = app_node.get_optional<std::string>("image-path"s);
        auto working_dir = app_node.get_optional<std::string>("working-dir"s);
        auto elevated = app_node.get_optional<bool>("elevated"s);
        auto auto_detach = app_node.get_optional<bool>("auto-detach"s);
        auto wait_all = app_node.get_optional<bool>("wait-all"s);
        auto exit_timeout = app_node.get_optional<int>("exit-timeout"s);
        auto prism_capture = app_node.get_optional<std::string>("prism-capture"s);

        std::vector<proc::cmd_t> prep_cmds;
        if (!exclude_global_prep.value_or(false)) {
          prep_cmds.reserve(config::prism.prep_cmds.size());
          for (auto &prep_cmd : config::prism.prep_cmds) {
            auto do_cmd = parse_env_val(this_env, prep_cmd.do_cmd);
            auto undo_cmd = parse_env_val(this_env, prep_cmd.undo_cmd);

            prep_cmds.emplace_back(
              std::move(do_cmd),
              std::move(undo_cmd),
              std::move(prep_cmd.elevated)
            );
          }
        }

        if (prep_nodes_opt) {
          auto &prep_nodes = *prep_nodes_opt;

          prep_cmds.reserve(prep_cmds.size() + prep_nodes.size());
          for (auto &[_, prep_node] : prep_nodes) {
            auto do_cmd = prep_node.get_optional<std::string>("do"s);
            auto undo_cmd = prep_node.get_optional<std::string>("undo"s);
            auto elevated = prep_node.get_optional<bool>("elevated");

            prep_cmds.emplace_back(
              parse_env_val(this_env, do_cmd.value_or("")),
              parse_env_val(this_env, undo_cmd.value_or("")),
              std::move(elevated.value_or(false))
            );
          }
        }

        std::vector<std::string> detached;
        if (detached_nodes_opt) {
          auto &detached_nodes = *detached_nodes_opt;

          detached.reserve(detached_nodes.size());
          for (auto &[_, detached_val] : detached_nodes) {
            detached.emplace_back(parse_env_val(this_env, detached_val.get_value<std::string>()));
          }
        }

        if (output) {
          ctx.output = parse_env_val(this_env, *output);
        }

        if (cmd) {
          ctx.cmd = parse_env_val(this_env, *cmd);
        }

        if (prism_capture) {
          ctx.prism_capture = parse_env_val(this_env, *prism_capture);
        }

        if (working_dir) {
          ctx.working_dir = parse_env_val(this_env, *working_dir);
        }

        if (image_path) {
          ctx.image_path = parse_env_val(this_env, *image_path);
        }

        ctx.elevated = elevated.value_or(false);
        ctx.auto_detach = auto_detach.value_or(true);
        ctx.wait_all = wait_all.value_or(true);
        ctx.exit_timeout = std::chrono::seconds {exit_timeout.value_or(5)};

        auto possible_ids = calculate_app_id(name, ctx.image_path, i++);
        if (ids.count(std::get<0>(possible_ids)) == 0) {
          // Avoid using index to generate id if possible
          ctx.id = std::get<0>(possible_ids);
        } else {
          // Fallback to include index on collision
          ctx.id = std::get<1>(possible_ids);
        }
        ids.insert(ctx.id);

        ctx.name = std::move(name);
        ctx.prep_cmds = std::move(prep_cmds);
        ctx.detached = std::move(detached);

        apps.emplace_back(std::move(ctx));
      }

      // Live-sync installed Steam games as launchable headless SteamOS apps:
      // launching one brings up the same session as Steam Headless and then
      // starts the game inside it. User-defined apps win on name collision.
      // Set PRISM_STEAM_SYNC=0 to disable (used by tests).
      if (const char *sync = std::getenv("PRISM_STEAM_SYNC"); sync == nullptr || std::string_view(sync) != "0"sv) {
        std::set<std::string> app_names;
        for (const auto &app : apps) {
          app_names.insert(app.name);
        }
        for (const auto &game : prism::steam::installed_games()) {
          if (app_names.count(game.name) != 0) {
            continue;
          }
          proc::ctx_t ctx;
          ctx.name = game.name;
          ctx.cmd = "steam steam://rungameid/"s + std::to_string(game.appid);
          ctx.prism_capture = "steamos"s;
          ctx.image_path = prism::steam::box_art_png(game.appid, game.box_art).string();
          ctx.elevated = false;
          ctx.auto_detach = true;
          ctx.wait_all = true;
          ctx.exit_timeout = std::chrono::seconds {5};

          auto possible_ids = calculate_app_id(ctx.name, ctx.image_path, i++);
          ctx.id = ids.count(std::get<0>(possible_ids)) == 0 ? std::get<0>(possible_ids) : std::get<1>(possible_ids);
          ids.insert(ctx.id);

          apps.emplace_back(std::move(ctx));
        }
      }

      return proc::proc_t {
        std::move(this_env),
        std::move(apps)
      };
    } catch (std::exception &e) {
      BOOST_LOG(error) << e.what();
    }

    return std::nullopt;
  }

  /**
   * @brief Refresh cached platform state from the operating system.
   */
  void refresh(const std::string &file_name) {
    auto proc_opt = proc::parse(file_name);

    if (proc_opt) {
      proc = std::move(*proc_opt);
    }
  }

  void refresh_apps(const std::string &file_name) {
    auto proc_opt = proc::parse(file_name);

    if (proc_opt) {
      proc.replace_apps(std::move(proc_opt->get_apps()));
    }
  }
}  // namespace proc
