#!/usr/bin/env python3
"""@file
@brief Compile Linux startup selection with probe spies; no desktop is needed.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CaptureSelectionTest(unittest.TestCase):
    """@brief Verify selection avoids unnecessary portal requests."""

    def test_startup_recovery(self):
        """@brief Run the real discovery function with delayed display and EGL spies."""
        source = (ROOT / "src/platform/linux/misc.cpp").read_text()
        start = source.index(
            "  std::optional<std::bitset<source::MAX_FLAGS>> init_capture()"
        )
        end = source.index("\n  }", start) + len("\n  }")
        harness = r'''
#include <bitset>
#include <iostream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include <gtest/gtest.h>
using namespace std::literals;
#define BOOST_LOG(level) std::cerr
namespace source { enum { NVFBC, WAYLAND, KMS, X11, KWIN, PORTAL, MAX_FLAGS }; }
namespace config { struct { std::string capture = "kwin"; } video; }
namespace lizardbyte::common {
  bool get_env(const char *, std::string &) { return false; }
}
enum class window_system_e { NONE, WAYLAND, X11 };
window_system_e window_system;
std::bitset<source::MAX_FLAGS> sources;
bool available = false;
bool egl_available = true;
int egl_calls = 0;
int probe_calls = 0;
bool gladLoaderLoadEGL(void *) { ++egl_calls; return egl_available; }
bool verify_kwin() { ++probe_calls; return available; }
bool verify_nvfbc() { return false; }
bool verify_wl() { return false; }
bool verify_kms() { return false; }
bool verify_x11() { return false; }
bool verify_portal() { ADD_FAILURE() << "Unexpected portal prompt"; return false; }
IMPLEMENTATION
/**
 * @brief Recover when the compositor exposes its first output after startup.
 */
TEST(CaptureStartup, DelayedDisplay) {
  auto initial = init_capture();
  ASSERT_TRUE(initial);
  EXPECT_TRUE(initial->none());
  EXPECT_EQ(egl_calls, 1);
  auto still_empty = init_capture();
  ASSERT_TRUE(still_empty);
  EXPECT_TRUE(still_empty->none());
  available = true;
  auto recovered = init_capture();
  ASSERT_TRUE(recovered);
  EXPECT_TRUE((*recovered)[source::KWIN]);
  EXPECT_EQ(probe_calls, 3);
  EXPECT_EQ(egl_calls, 1);
  // Previously returned snapshots remain valid after discovery succeeds.
  EXPECT_TRUE(initial->none());
  available = false;
  EXPECT_EQ(init_capture(), recovered);
  EXPECT_EQ(probe_calls, 3);
}
/**
 * @brief Retry a failed EGL load before probing or publishing any backend.
 */
TEST(CaptureStartup, DelayedEgl) {
  egl_available = false;
  available = true;
  EXPECT_FALSE(init_capture());
  EXPECT_EQ(probe_calls, 0);
  EXPECT_TRUE(sources.none());
  egl_available = true;
  auto recovered = init_capture();
  ASSERT_TRUE(recovered);
  EXPECT_TRUE((*recovered)[source::KWIN]);
  EXPECT_EQ(egl_calls, 2);
  EXPECT_EQ(probe_calls, 1);
}
/**
 * @brief Simultaneous capture requests initialize and publish a backend once.
 */
TEST(CaptureStartup, ConcurrentRequests) {
  available = true;
  std::vector<std::thread> threads;
  for (int i = 0; i < 16; ++i) {
    threads.emplace_back([] {
      const auto selected = init_capture();
      ASSERT_TRUE(selected);
      EXPECT_TRUE((*selected)[source::KWIN]);
    });
  }
  for (auto &thread : threads) { thread.join(); }
  EXPECT_EQ(egl_calls, 1);
  EXPECT_EQ(probe_calls, 1);
}
'''.replace("IMPLEMENTATION", source[start:end])
        gtest = Path(os.environ.get(
            "GTEST_ROOT", str(ROOT / "third-party/lizardbyte-common/"
                              "third-party/googletest/googletest")
        ))
        with tempfile.TemporaryDirectory(prefix="cmake-build-capture-") as tmp:
            build = Path(tmp)
            cpp = build / "startup.cpp"
            binary = build / "tests/test_prism"
            binary.parent.mkdir()
            cpp.write_text(harness)
            subprocess.run([
                os.environ.get("CXX", "c++"), "-std=c++17", "-pthread",
                "-Wall", "-Wextra", "-Werror",
                *[f"-DPRISM_BUILD_{name}" for name in
                  ("CUDA", "WAYLAND", "DRM", "X11", "KWIN", "PORTAL")],
                "-I", str(gtest / "include"), "-I", str(gtest),
                str(cpp), str(gtest / "src/gtest-all.cc"),
                str(gtest / "src/gtest_main.cc"), "-o", str(binary),
            ], check=True)
            # Each process starts with fresh function-local initialization state.
            for name in ("DelayedDisplay", "DelayedEgl", "ConcurrentRequests"):
                with self.subTest(name=name):
                    subprocess.run([
                        str(binary), f"--gtest_filter=CaptureStartup.{name}"
                    ], check=True)

    def test_backend_matrix(self):
        """@brief Exercise availability, explicit choices, and builds."""
        source = (ROOT / "src/platform/linux/misc.cpp").read_text()
        init = source.index("init_capture() {")
        start = source.index("#ifdef PRISM_BUILD_CUDA\n    if (((", init)
        end = source.index("\n    return sources;", start)
        selection = source[start:end]
        harness = r'''
#include <bitset>
#include <iostream>
#include <string>
namespace source {
  enum { NVFBC, WAYLAND, KMS, X11, KWIN, PORTAL };
}
namespace config {
  struct { std::string capture; } video;
}
std::bitset<6> sources;
std::bitset<6> available;
std::bitset<6> probed;
bool probe(int id) { probed[id] = true; return available[id]; }
bool verify_nvfbc() { return probe(source::NVFBC); }
bool verify_wl() { return probe(source::WAYLAND); }
bool verify_kms() { return probe(source::KMS); }
bool verify_x11() { return probe(source::X11); }
bool verify_kwin() { return probe(source::KWIN); }
bool verify_portal() { return probe(source::PORTAL); }
void select_capture() {
SELECTION
}
int main() {
  const char *names[] = {
    "nvfbc", "wlr", "kms", "x11", "kwin", "portal", "", "invalid"
  };
  for (unsigned mask = 0; mask < 64; ++mask) {
    for (int choice = 0; choice < 8; ++choice) {
      available = mask & BUILD_MASK;
      sources.reset();
      probed.reset();
      config::video.capture = names[choice];
      select_capture();
      std::bitset<6> expected;
      if (choice < 6) {
        expected[choice] = available[choice];
      } else if (choice == 6) {
        for (int id = 0; id < 6; ++id) {
          if (available[id]) { expected[id] = true; break; }
        }
        // X11 is also enumerated as the software fallback for NvFBC.
        expected[source::X11] = available[source::X11];
      }
      bool expect_portal_probe = (BUILD_MASK & (1 << source::PORTAL)) &&
        (choice == source::PORTAL ||
         (choice == 6 && (available.to_ulong() & 31) == 0));
      if (sources != expected ||
          probed[source::PORTAL] != expect_portal_probe) {
        std::cerr << "availability=" << mask << " choice=" << names[choice]
                  << " selected=" << sources << " expected=" << expected
                  << " portal_probed=" << probed[source::PORTAL] << '\n';
        return 1;
      }
    }
  }
}
'''.replace("SELECTION", selection)
        with tempfile.TemporaryDirectory(prefix="prism-capture-test-") as tmp:
            cpp = Path(tmp) / "selection.cpp"
            binary = Path(tmp) / "selection"
            cpp.write_text(harness)
            # Include builds without either or both desktop backends.
            for kwin, portal in (
                (True, True), (False, True), (True, False), (False, False)
            ):
                with self.subTest(kwin=kwin, portal=portal):
                    definitions = ["CUDA", "WAYLAND", "DRM", "X11"]
                    if kwin:
                        definitions.append("KWIN")
                    if portal:
                        definitions.append("PORTAL")
                    build_mask = (
                        15 | (16 if kwin else 0) | (32 if portal else 0)
                    )
                    subprocess.run([
                        os.environ.get("CXX", "c++"), "-std=c++17",
                        "-Wall", "-Wextra", "-Werror",
                        *[f"-DPRISM_BUILD_{name}" for name in definitions],
                        f"-DBUILD_MASK={build_mask}",
                        str(cpp), "-o", str(binary),
                    ], check=True)
                    subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
