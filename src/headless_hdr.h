/**
 * @file src/headless_hdr.h
 * @brief Per-device headless HDR calibration profiles and controller workflow.
 */
#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <string>

namespace prism::hdr {
  constexpr const char *app_name = "Headless HDR Configuration";  ///< Built-in calibration application title.

  /**
   * @brief Calibrated SDR reference white and display highlight clipping point, in nits.
   */
  struct profile_t {
    int sdr_white = 203;  ///< SDR white luminance used inside the HDR output.
    int peak = 1000;  ///< Display peak luminance advertised to the video decoder.

    /**
     * @brief Validate supported luminance ranges and reference-white ordering.
     *
     * @return Whether the profile is usable.
     */
    bool valid() const {
      return sdr_white >= 80 && sdr_white <= 500 && peak >= sdr_white && peak <= 4000;
    }
  };

  /**
   * @brief Read a bounded, versioned profile without accepting trailing fields.
   *
   * @param path Profile file path.
   * @return Valid profile, or no value for an absent/malformed profile.
   */
  inline std::optional<profile_t> read(const std::filesystem::path &path) {
    std::ifstream input(path);
    int version = 0;
    profile_t result;
    std::string extra;
    if (!(input >> version >> result.sdr_white >> result.peak) || version != 1 ||
        !result.valid() || (input >> extra)) {
      return std::nullopt;
    }
    return result;
  }

  /**
   * @brief Atomically replace a profile so compositor readers never see partial settings.
   *
   * @param path Destination controlled by the host, never supplied by the network client.
   * @param profile Validated calibration values.
   * @throws std::exception If validation, writing, or rename fails.
   */
  inline void write(const std::filesystem::path &path, const profile_t &profile) {
    if (!profile.valid()) {
      throw std::invalid_argument("Invalid HDR calibration");
    }
    std::filesystem::create_directories(path.parent_path());
    const auto temporary = path.string() + ".tmp";
    try {
      std::ofstream output(temporary, std::ios::trunc);
      output.exceptions(std::ios::badbit | std::ios::failbit);
      output << "1 " << profile.sdr_white << ' ' << profile.peak << '\n';
      output.close();
      std::filesystem::rename(temporary, path);
    } catch (...) {
      std::error_code ignored;
      std::filesystem::remove(temporary, ignored);
      throw;
    }
  }

  /**
   * @brief Convert absolute luminance to normalized HDR10 PQ for calibration patterns.
   *
   * @param nits Luminance between zero and 10,000 nits.
   * @return Normalized PQ code value.
   */
  inline double pq(double nits) {
    const auto p = std::pow(std::clamp(nits / 10000.0, 0.0, 1.0), 2610.0 / 16384.0);
    return std::pow((3424.0 / 4096.0 + (2413.0 / 128.0) * p) / (1.0 + (2392.0 / 128.0) * p), 2523.0 / 32.0);
  }

  /**
   * @brief Controller-driven calibration state, independent of rendering and input transport.
   */
  struct calibration_t {
    profile_t profile;  ///< Current unsaved values.
    int page = 0;  ///< Zero: SDR white; one: peak clipping; two: review and save.

    /**
     * @brief Adjust the selected luminance.
     *
     * @param direction Negative decreases, positive increases.
     */
    void adjust(int direction) {
      if (page == 0) {
        profile.sdr_white = std::clamp(profile.sdr_white + direction * 10, 80, std::min(500, profile.peak));
      } else if (page == 1) {
        profile.peak = std::clamp(profile.peak + direction * 25, profile.sdr_white, 4000);
      }
    }
  };
}  // namespace prism::hdr
