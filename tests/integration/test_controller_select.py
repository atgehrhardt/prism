#!/usr/bin/env python3
"""@brief Check Select passthrough on a live Linux stream's virtual gamepad.

Start a stream, pass its host /dev/input/eventN device, then press Select three
times. Run with android_back_as_guide enabled to exercise the regression.
The test observes events without grabbing the device or injecting input.
"""

import argparse
import os
import select
import struct
import time


def check_select(device, presses, timeout):
    """@brief Require paired Select presses and reject any Guide or Start event."""
    event = struct.Struct("@llHHi")
    deadline = time.monotonic() + timeout
    downs = ups = 0
    held = False
    with open(device, "rb", buffering=0) as stream:
        while time.monotonic() < deadline:
            if not select.select([stream], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            payload = os.read(stream.fileno(), event.size)
            if len(payload) != event.size:
                raise AssertionError("Virtual controller disconnected during capture")
            _, _, kind, code, value = event.unpack(payload)
            if kind != 1:  # EV_KEY
                continue
            if code in (315, 316):  # BTN_START, BTN_MODE
                raise AssertionError(f"Unexpected {'Guide' if code == 316 else 'Start'} event: {value}")
            if code != 314 or value == 2:  # BTN_SELECT; ignore repeat
                continue
            if value == 1:
                assert not held, "Select pressed twice without release"
                held = True
                downs += 1
            else:
                assert held, "Select released without press"
                held = False
                ups += 1
            print(f"Select {'down' if value else 'up'}", flush=True)
        assert not held, "Select remained held"
        assert downs == ups == presses, f"Expected {presses} presses; received {downs} down / {ups} up"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("--presses", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    check_select(args.device, args.presses, args.timeout)
    print("PASS: Select passed through without Guide or Start")
