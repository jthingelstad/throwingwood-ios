"""Check the actual app's solo screens against both iOS 26.2 simulator baselines."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
MODES = {
    "home": None, "options": None, "menu": "aim", "verdict": "aim", "handoff": "aim", "aim": "aim", "plan": "aim",
    "arc": "aim", "tilt": "aim", "flight": "aim", "raise": "raise", "raisemany": "raise-many",
    "raiseauto": "raise-many", "raiserest": "raise-many", "raisedrag": "raise",
    "raiserefused": "raise-refused", "punish": "punish", "computer": "computer",
    "winner": "over", "sheet": "over",
}
# The match with the linear meter (and the nudge) beside the plan's sliders:
# name: (MATCH_REVIEW mode, fixture, meter, side). The meter is a launch
# argument, never saved; every other shot runs with the clock.
METER_SHOTS = {
    "linear-right-aim": ("aim", "aim", "linear", "right"),
    "linear-right-arc": ("arc", "aim", "linear", "right"),
    "linear-right-tilt": ("tilt", "aim", "linear", "right"),
    "linear-left-aim": ("aim", "aim", "linear", "left"),
    "linear-left-arc": ("arc", "aim", "linear", "left"),
    "linear-left-tilt": ("tilt", "aim", "linear", "left"),
    "linear-right-nudge": ("nudge", "aim", "linear", "right"),
    "linear-left-nudge": ("nudge", "aim", "linear", "left"),
    "clock-nudge": ("nudge", "aim", "clock", "right"),
    # the coach line over the prompt, for a device yet to make 3 throws, and led
    # by the SLOW verdict on the throw after a slow flick
    "coach": ("coach", "aim", "clock", "right"),
    "coach-slow": ("coachslow", "aim", "clock", "right"),
    "linear-right-coach": ("coach", "aim", "linear", "right"),
    "linear-left-coach": ("coach", "aim", "linear", "left"),
    "linear-right-coach-slow": ("coachslow", "aim", "linear", "right"),
}
# every other shot is a device that has learned the throw (no coach line)
LEARNING = {"coach", "coachslow"}
SHOTS = {**{m: (m, f, "clock", "right") for m, f in MODES.items()}, **METER_SHOTS}
APP = "com.throwingwood.app"


def sim(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kwargs)


def capture(phone, args):
    devices = json.loads(sim("list", "devices", "available", "-j", capture_output=True).stdout)
    device = next(d for d in devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-2"]
                  if d["name"] == phone)
    udid = device["udid"]
    boot = device["state"] == "Shutdown"
    if boot:
        sim("boot", udid)
    try:
        sim("bootstatus", udid, "-b", stdout=subprocess.DEVNULL)
        sim("install", udid, str(args.app))
        sim("status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
        tmp = Path(sim("get_app_container", udid, APP, "data", capture_output=True,
                       text=True).stdout.strip()) / "tmp"
        prefix = phone.lower().replace(" ", "-")
        for shot, (mode, fixture, meter, side) in SHOTS.items():
            ready = tmp / "review-ready"
            ready.unlink(missing_ok=True)
            if fixture:
                src = ROOT / "ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/solo" / (fixture + ".json")
                shutil.copyfile(src, tmp / "review-solo.json")
            sim("launch", "--terminate-running-process", udid, APP,
                "-pitch.meter", meter, "-pitch.meterSide", side,
                "-pitch.throwsMade", "0" if mode in LEARNING else "9",
                env={**os.environ, "SIMCTL_CHILD_MATCH_REVIEW": mode}, stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 30
            while not ready.exists() or ready.read_text() != mode:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{phone} did not reach {mode}")
                time.sleep(0.1)
            time.sleep(0.7)  # allow the launch transition and SwiftUI transaction to finish
            file = args.out / f"{prefix}-{shot}.png"
            sim("io", udid, "screenshot", str(file), capture_output=True)
            print(f"{phone} {shot}", flush=True)
    finally:
        sim("status_bar", udid, "clear")
        subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
        if boot:
            sim("shutdown", udid)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "build/solo-snapshots")
    parser.add_argument("--capture-only", action="store_true")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    phones = ["iPhone 16e", "iPhone 17 Pro Max"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda phone: capture(phone, args), phones))
    if not args.capture_only:
        subprocess.run(["swift", str(ROOT / "tools/check-snapshots.swift"), str(ROOT / "docs/review"),
                        str(args.out), *[f"{p.lower().replace(' ', '-')}-{m}.png"
                                       for p in phones for m in SHOTS]], check=True)
