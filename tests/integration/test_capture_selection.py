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
    """@brief Verify backend selection and absence of unnecessary portal requests."""

    def test_backend_matrix(self):
        """@brief Exercise availability, explicit choices, and optional builds."""
        source = (ROOT / "src/platform/linux/misc.cpp").read_text()
        init = source.index("std::unique_ptr<deinit_t> init()")
        start = source.index("#ifdef PRISM_BUILD_CUDA\n    if (((", init)
        end = source.index("\n    if (sources.none())", start)
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
  const char *names[] = {"nvfbc", "wlr", "kms", "x11", "kwin", "portal", "", "invalid"};
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
        (choice == source::PORTAL || (choice == 6 && (available.to_ulong() & 31) == 0));
      if (sources != expected || probed[source::PORTAL] != expect_portal_probe) {
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
            # Include builds with either or both optional desktop backends absent.
            for kwin, portal in ((True, True), (False, True), (True, False), (False, False)):
                with self.subTest(kwin=kwin, portal=portal):
                    definitions = ["CUDA", "WAYLAND", "DRM", "X11"]
                    if kwin:
                        definitions.append("KWIN")
                    if portal:
                        definitions.append("PORTAL")
                    subprocess.run([
                        os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        *[f"-DPRISM_BUILD_{name}" for name in definitions],
                        f"-DBUILD_MASK={15 | (16 if kwin else 0) | (32 if portal else 0)}",
                        str(cpp), "-o", str(binary),
                    ], check=True)
                    subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
