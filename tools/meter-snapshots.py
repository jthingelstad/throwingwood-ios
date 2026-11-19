"""Capture the practice pitch's meters on simulators of your own choosing.

Each shot launches the installed app with PITCH_REVIEW (aim, wind, marks, ...)
and the meter preferences as launch arguments (they are not saved), waits for
the board's ready file and saves a screenshot. Pass the devices by name or
UDID with --device; nothing here boots or shuts down a device it was not given.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

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
    prefix = args.prefix or name.lower().replace(" ", "-")
    try:
        for shot, (mode, meter, side, extra) in SHOTS.items():
            if args.only and shot not in args.only:
                continue
            ready = tmp / "review-ready"
            ready.unlink(missing_ok=True)
            env = {**os.environ, "SIMCTL_CHILD_PITCH_REVIEW": mode}
            env.update({"SIMCTL_CHILD_" + k: v for k, v in extra.items()})
            sim("launch", "--terminate-running-process", udid, APP,
                "-pitch.meter", meter, "-pitch.meterSide", side, env=env, stdout=subprocess.DEVNULL)
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--device", action="append", required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "build/meter-shots")
    parser.add_argument("--only", action="append")
    parser.add_argument("--prefix")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for device in args.device:
        capture(device, args)
