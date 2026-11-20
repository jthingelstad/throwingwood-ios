"""Capture the practice pitch's meters on simulators of your own choosing.

Each shot launches the installed app with PITCH_REVIEW (aim, wind, marks, ...)
and the meter preferences as launch arguments (they are not saved), waits for
the board's ready file and saves a screenshot. Pass the devices by name or
UDID with --device; nothing here boots or shuts down a device it was not given.
--landscape left|right turns the interface on its side (a phone held sideways
lays out as the web's wide screen, the linear meter at its edge) and names the shots
<phone>-landscape-*. An iPad turns as a device (review_turn.py); pass --prefix
ipad-mini or ipad-pro-13 for its pictures' names.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from review_turn import is_ipad, turn as turn_device  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = "com.throwingwood.app"
# name: (PITCH_REVIEW mode, meter, side, extra environment)
SHOTS = {
    "clock-idle": ("aim", "clock", "right", {}),
    "clock-wind": ("wind", "clock", "right", {}),
    "clock-beside": ("beside", "clock", "right", {}),
    "clock-marks": ("marks", "clock", "right", {}),
    "linear-right-idle": ("aim", "linear", "right", {}),
    "linear-right-wind": ("wind", "linear", "right", {}),
    "linear-right-marks": ("marks", "linear", "right", {}),
    "linear-left-idle": ("aim", "linear", "left", {}),
    "linear-left-wind": ("wind", "linear", "left", {}),
    # the nudge, frozen: the press, the slow draw back, the beat, the fast flick
    "clock-nudge-press": ("nudge", "clock", "right", {"NUDGE_AT": "0.25"}),
    "clock-nudge-back": ("nudge", "clock", "right", {"NUDGE_AT": "1.0"}),
    "clock-nudge-flick": ("nudge", "clock", "right", {"NUDGE_AT": "1.7"}),
    "clock-nudge-still": ("nudge", "clock", "right", {"NUDGE_STILL": "1"}),
    "linear-right-nudge-press": ("nudge", "linear", "right", {"NUDGE_AT": "0.25"}),
    "linear-right-nudge-back": ("nudge", "linear", "right", {"NUDGE_AT": "1.0"}),
    "linear-right-nudge-flick": ("nudge", "linear", "right", {"NUDGE_AT": "1.7"}),
    "linear-right-nudge-still": ("nudge", "linear", "right", {"NUDGE_STILL": "1"}),
    "linear-left-nudge-back": ("nudge", "linear", "left", {"NUDGE_AT": "1.4"}),
    # the coach line following the stroke, for a device yet to make 3 throws
    "clock-coach-wind": ("wind", "clock", "right", {"THROWS_MADE": "0"}),
    "linear-right-coach-wind": ("wind", "linear", "right", {"THROWS_MADE": "0"}),
}


def sim(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kwargs)


def udid_of(device):
    devices = json.loads(sim("list", "devices", "available", "-j", capture_output=True).stdout)
    for runtime in devices["devices"].values():
        for d in runtime:
            if device in (d["name"], d["udid"]):
                return d["udid"], d["name"], d["state"]
    raise SystemExit(f"no simulator {device}")


def capture(device, args):
    udid, name, state = udid_of(device)
    if state == "Shutdown":
        sim("boot", udid)
    sim("bootstatus", udid, "-b", stdout=subprocess.DEVNULL)
    if args.app:
        sim("install", udid, str(args.app))
    sim("status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
        "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
    tmp = Path(sim("get_app_container", udid, APP, "data", capture_output=True,
                   text=True).stdout.strip()) / "tmp"
    if is_ipad(name):
        turn_device(udid, args.landscape)  # an iPad turns as a device, not from the app
    prefix = args.prefix or name.lower().replace(" ", "-") + ("-landscape" if args.landscape else "")
    try:
        for shot, (mode, meter, side, extra) in SHOTS.items():
            if args.only and shot not in args.only:
                continue
            ready = tmp / "review-ready"
            ready.unlink(missing_ok=True)
            env = {**os.environ, "SIMCTL_CHILD_PITCH_REVIEW": mode}
            env.update({"SIMCTL_CHILD_" + k: v for k, v in extra.items()})
            if args.landscape:
                env["SIMCTL_CHILD_REVIEW_ORIENTATION"] = args.landscape
            sim("launch", "--terminate-running-process", udid, APP,
                "-pitch.meter", meter, "-pitch.meterSide", side,
                # a learned device unless the shot asks for the coach line
                "-pitch.throwsMade", extra.get("THROWS_MADE", "9"), env=env, stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 30
            while not ready.exists():
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{name} did not reach {shot}")
                time.sleep(0.1)
            time.sleep(0.8)
            file = args.out / f"{prefix}-{shot}.png"
            sim("io", udid, "screenshot", str(file), capture_output=True)
            print(file, flush=True)
    finally:
        sim("status_bar", udid, "clear")
        subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
        if is_ipad(name) and args.landscape:
            turn_device(udid, None)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--device", action="append", required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "build/meter-shots")
    parser.add_argument("--only", action="append")
    parser.add_argument("--prefix")
    parser.add_argument("--landscape", choices=["left", "right"])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for device in args.device:
        capture(device, args)
