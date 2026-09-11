/**
 * @file src/platform/linux/kwin_output.h
 * @brief Select KWin outputs without falling back from an explicitly named display.
 */
#pragma once

#include <algorithm>
#include <string_view>

namespace kwin {
  /**
   * @brief Find the requested output, using the first output only for an empty name.
   *
   * @tparam Outputs Map of output handles to pointers to named output parameters.
   * @param outputs Available compositor outputs.
   * @param name Requested output name, or empty for the default output.
   * @return Matching iterator, or end when the requested output is unavailable.
   */
  template<class Outputs>
  auto find_output(Outputs &outputs, std::string_view name) {
    if (name.empty()) {
      return outputs.begin();
    }
    return std::find_if(outputs.begin(), outputs.end(), [name](const auto &output) {
      return output.second->name == name;
    });
  }
}  // namespace kwin
