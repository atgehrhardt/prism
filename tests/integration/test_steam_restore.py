#!/usr/bin/env python3
"""@file
@brief Test Steam restoration with isolated display and service probes.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "contrib/virtual-session/prism-steam-restore.sh"
READY = "DP-1 connected primary 3440x1440+0+0 (normal)\n"
HARNESS = r'''
source "$RESTORE_SCRIPT"
prism_unit_live() { [ "${LIVE_UNIT:-0}" = 1 ]; }
prism_unit_has_comm() {
  if [ "${HANDOFF:-0}" = 1 ]; then
    HANDOFF=0
    echo 'Supervising Steam after launcher exit'
    return 0
  fi
  return 1
}
flock() {
  [ "${LOCK_FAILURE:-0}" = 0 ] || return 1
  /usr/bin/flock "$@"
}
pgrep() {
  [ "$*" = "-u $(id -u) -x steam" ] || exit 99
  [ "${EXISTING_STEAM:-0}" = 1 ]
}
timeout() {
  [ "$1" = 2 ] || exit 99
  shift
  "$@"
}
xrandr() {
  [ "$*" = --query ] || exit 99
  cat "$XDG_RUNTIME_DIR/output"
  return "${PROBE_STATUS:-0}"
}
command() {
  if [ "${MISSING_XRANDR:-0}" = 1 ] && [ "$*" = '-v xrandr' ]; then
    return 1
  fi
  builtin command "$@"
}
sleep() {
  if [ "$1" = 2 ] && [ ! -e "$XDG_RUNTIME_DIR/launched" ]; then
    # Waiting must release the capture lock so another stream can start.
    (exec 9>&-; flock -n "$XDG_RUNTIME_DIR/prism-capture.lock" true) || exit 98
    if [ "${EXTRA_WAIT:-0}" = 1 ]; then
      EXTRA_WAIT=0
      return 0
    fi
    case "${AFTER_WAIT:-ready}" in
      ready)
        printf '%s\n' 'DP-1 connected 1920x1080-1920+0 (normal)' \
          > "$XDG_RUNTIME_DIR/output" ;;
      state) touch "$XDG_RUNTIME_DIR/prism-headless.state" ;;
      override) touch "$XDG_RUNTIME_DIR/prism-capture-override" ;;
      unit) LIVE_UNIT=1 ;;
      steam) EXISTING_STEAM=1 ;;
    esac
  fi
  /bin/sleep 0.01
}
steam() {
  [ ! -e "/proc/$BASHPID/fd/9" ] || exit 97
  printf '%s\n' "$*" > "$XDG_RUNTIME_DIR/launched"
}
if [ "${PROBE_ONLY:-0}" = 1 ]; then
  prism_steam_desktop_ready
else
  prism_steam_restore_main
fi
'''


class SteamRestoreTest(unittest.TestCase):
    """@brief Test readiness and cancellation without touching Steam."""

    def run_restore(self, output=READY, markers=(), **variables):
        """@brief Run restoration with deterministic process and display stubs.
        @param output Initial xrandr response.
        @param markers Session ownership files that should prevent restoration.
        @param variables Environment values controlling the test probes.
        @return Process result and optional Steam arguments.
        """
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            (runtime / "output").write_text(output)
            for marker in markers:
                (runtime / marker).touch()
            environment = dict(os.environ, XDG_RUNTIME_DIR=temporary,
                               RESTORE_SCRIPT=str(SCRIPT), DISPLAY=":0")
            environment.update(variables)
            result = subprocess.run(
                ["bash", "-c", HARNESS], env=environment, capture_output=True,
                text=True, timeout=5,
            )
            launched = runtime / "launched"
            arguments = launched.read_text() if launched.exists() else None
            return result, arguments

    def test_active_outputs(self):
        """@brief Accept active outputs at positive or negative positions."""
        for output in (READY, "HDMI-1 connected 1920x1080-1920-100 (normal)\n",
                       "DP-1 disconnected\n"
                       "HDMI-1 connected 800x600+0+0 (normal)\n"):
            with self.subTest(output=output):
                result, arguments = self.run_restore(output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(arguments, "-silent\n")
                self.assertNotIn("Waiting", result.stdout)

    def test_unusable_outputs(self):
        """@brief Reject disconnected outputs and inactive modes."""
        for output in ("", "DP-1 disconnected 1920x1080+0+0\n",
                       "DP-1 connected (normal)\n  1920x1080 60.00\n",
                       "Screen 0: current 3440 x 1440\n"):
            with self.subTest(output=output):
                result, arguments = self.run_restore(output, PROBE_ONLY="1")
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(arguments)

    def test_probe_errors(self):
        """@brief Reject failed or timed-out display queries."""
        for status in ("1", "124"):
            with self.subTest(status=status):
                result, _ = self.run_restore(
                    PROBE_ONLY="1", PROBE_STATUS=status)
                self.assertNotEqual(result.returncode, 0)

    def test_missing_display(self):
        """@brief Require an explicit desktop DISPLAY."""
        result, _ = self.run_restore(PROBE_ONLY="1", DISPLAY="")
        self.assertNotEqual(result.returncode, 0)

    def test_output_returns(self):
        """@brief Wait for an output without holding the capture lock."""
        result, arguments = self.run_restore(
            "DP-1 connected (normal)\n", EXTRA_WAIT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments, "-silent\n")
        self.assertEqual(result.stdout.count(
            "Waiting for a desktop output"), 1)

    def test_cancel_before_launch(self):
        """@brief Respect session markers and an existing Steam client."""
        for markers, variables in (
            (("prism-headless.state",), {}),
            (("prism-capture-override",), {}),
            ((), {"LIVE_UNIT": "1"}),
            ((), {"EXISTING_STEAM": "1"}),
        ):
            with self.subTest(markers=markers, variables=variables):
                result, arguments = self.run_restore(
                    markers=markers, **variables)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(arguments)

    def test_cancel_while_waiting(self):
        """@brief Cancel deferred restoration when a new session starts."""
        for event in ("state", "override", "unit", "steam"):
            with self.subTest(event=event):
                result, arguments = self.run_restore("", AFTER_WAIT=event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(arguments)
                self.assertIn("Waiting for a desktop output", result.stdout)

    def test_lock_failure(self):
        """@brief Do not launch if lifecycle serialization fails."""
        result, arguments = self.run_restore(LOCK_FAILURE="1")
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(arguments)

    def test_launcher_handoff(self):
        """@brief Keep supervising an owned client after its launcher exits."""
        result, arguments = self.run_restore(HANDOFF="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(arguments, "-silent\n")
        self.assertIn("Supervising Steam after launcher exit", result.stdout)

    def test_missing_probe(self):
        """@brief Report a missing xrandr dependency."""
        result, arguments = self.run_restore(MISSING_XRANDR="1")
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(arguments)
        self.assertIn("requires xrandr", result.stderr)


if __name__ == "__main__":
    unittest.main()
