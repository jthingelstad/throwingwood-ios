"""Check the actual app's solo screens against both iOS 26.2 simulator baselines."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # no __pycache__ in tools/
from review_turn import is_ipad, turn as turn_device

ROOT = Path(__file__).resolve().parents[1]
MODES = {
    "home": None, "options": None, "settings": None, "menu": "aim", "verdict": "aim", "handoff": "aim", "aim": "aim", "plan": "aim",
    "arc": "aim", "tilt": "aim", "stand": "aim", "flight": "aim", "raise": "raise", "raisemany": "raise-many",
    "raiseauto": "raise-many", "raiserest": "raise-many", "raisedrag": "raise",
    "raiserefused": "raise-refused", "punish": "punish", "computer": "computer",
    "winner": "over", "sheet": "over",
    # Settings opened from a match's menu, in the match's scene (--scene)
    "matchsettings": "aim",
    # engine 0.15: a Kid match the app starts against the Kid computer (no fixture), its
    # hand-off, aim, side view (the Kid line and its cones) and STAND (worded for the
    # line); Techno's ring part way grown (--scene neon); a kubb drilled at SPIN's most
    "kidhandoff": None, "kidaim": None, "kidplan": None, "kidstand": None,
    "ring": "aim", "spin": None,
    # engine 0.15.1: the Tournament's live neighbours (--scene tournament), run on until a
    # neighbour's throw is half way and in view, in the thrower's view and the wide view
    "neighbours": "aim", "neighbourswide": "aim", "neighboursflight": "aim",
    # a watched automatic raise frozen RAISE_AT s in (SIMCTL_CHILD_RAISE_AT; 0.3 by default)
    "raisetip": "raise-many",
}
# Shots taken only when asked for (--only): they need a scene or show one thing.
ON_REQUEST = {"kidhandoff", "kidaim", "kidplan", "kidstand", "ring", "spin", "neighbours", "neighbourswide", "neighboursflight",
              "raisetip"}
# The engine's catalogue (core/scenes): each scene's ground and set, so a fixture shown
# in a scene is the match a scene would have started (engine 0.14: the scene decides).
SCENES = {
    "day": ("grass", "classic"), "beach": ("sand", "classic"), "night": ("grass", "classic"),
    "neon": ("grid", "classic"), "minnesota": ("snow", "minnesota"), "tournament": ("grass", "usa"),
    "bw": ("grass", "classic"),
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
    "linear-right-stand": ("stand", "aim", "linear", "right"),
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
# A phone on its side (Jamie, 2026-11-19: "Given we have a widescreen view for
# web, can we extend that to support iPhone rotated display?"): with --landscape
# these shots are taken turned, named <phone>-landscape-<shot>.png. The linear
# shots show the linear meter at its edge, the whole safe height.
LANDSCAPE = [
    "home", "options", "settings", "handoff", "aim", "plan", "arc", "tilt", "stand", "flight", "verdict",
    "raise", "raisemany", "raiseauto", "raiserest", "raisedrag", "raiserefused", "punish", "computer", "menu", "winner", "sheet",
    "linear-left-aim", "linear-right-aim", "linear-left-tilt", "clock-nudge", "linear-left-nudge",
    "coach", "coach-slow", "linear-left-coach",
]
# Shots taken only on a phone on its side: STAND held with the clock at the left
# (the plan block at the right edge), and the punishment bar with a refused
# spot's reason.
LANDSCAPE_ONLY = {
    "clock-left-stand": ("stand", "aim", "clock", "left"),
    "punishwhy": ("punishwhy", "punish", "clock", "right"),
}
LANDSCAPE += list(LANDSCAPE_ONLY)
# every other shot is a device that has learned the throw (no coach line)
LEARNING = {"coach", "coachslow"}
SHOTS = {**{m: (m, f, "clock", "right") for m, f in MODES.items()}, **METER_SHOTS, **LANDSCAPE_ONLY}
APP = "com.throwingwood.app"
# The review devices under the iOS 26.2 runtime and their picture names: both
# phones, and a small and a large iPad (the same game on a bigger screen).
DEVICES = {
    "iPhone 16e": "iphone-16e", "iPhone 17 Pro Max": "iphone-17-pro-max",
    "iPad mini (A17 Pro)": "ipad-mini", "iPad Pro 13-inch (M5)": "ipad-pro-13",
}
PHONES = ["iPhone 16e", "iPhone 17 Pro Max"]
IPADS = ["iPad mini (A17 Pro)", "iPad Pro 13-inch (M5)"]


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
        if is_ipad(phone):
            turn_device(udid, args.landscape)  # an iPad turns as a device, not from the app
        prefix = DEVICES[phone] + (f"-{args.scene}" if args.scene else "") + ("-landscape" if args.landscape else "")
        turn = {"SIMCTL_CHILD_REVIEW_ORIENTATION": args.landscape} if args.landscape else {}
        for shot, (mode, fixture, meter, side) in SHOTS.items():
            if args.only and shot not in args.only:
                continue
            if args.landscape and not args.only and shot not in LANDSCAPE:
                continue
            if not args.only and shot in ON_REQUEST:
                continue
            if not args.landscape and shot in LANDSCAPE_ONLY:
                continue
            ready = tmp / "review-ready"
            ready.unlink(missing_ok=True)
            (tmp / "review-layout.json").unlink(missing_ok=True)
            if fixture:
                src = ROOT / "ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/solo" / (fixture + ".json")
                if args.scene:
                    # the same match in a scene: its options name it, as a match started in it does
                    snap = json.loads(src.read_text())
                    snap["opts"]["scene"] = args.scene
                    snap["opts"]["surface"], snap["opts"]["set"] = SCENES[args.scene]
                    if "game" in snap.get("save", {}):
                        snap["save"]["game"]["surface"] = SCENES[args.scene][0].capitalize()
                    (tmp / "review-solo.json").write_text(json.dumps(snap))
                else:
                    shutil.copyfile(src, tmp / "review-solo.json")
            scene = {"SIMCTL_CHILD_REVIEW_SCENE": args.scene} if args.scene else {}
            sim("launch", "--terminate-running-process", udid, APP,
                "-pitch.meter", meter, "-pitch.meterSide", side,
                "-pitch.throwsMade", "0" if mode in LEARNING else "9",
                env={**os.environ, **turn, **scene, "SIMCTL_CHILD_MATCH_REVIEW": mode},
                stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 30
            while not ready.exists() or ready.read_text() != mode:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{phone} did not reach {mode}")
                time.sleep(0.1)
            time.sleep(0.7)  # allow the launch transition and SwiftUI transaction to finish
            file = args.out / f"{prefix}-{shot}.png"
            sim("io", udid, "screenshot", str(file), capture_output=True)
            if args.landscape:
                upright(file, args.landscape)
                # the app's frames and the safe area it was given (not compared)
                layout = tmp / "review-layout.json"
                if layout.exists():
                    shutil.copyfile(layout, file.with_suffix(".json"))
            print(f"{phone} {shot}", flush=True)
    finally:
        sim("status_bar", udid, "clear")
        subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
        if is_ipad(phone) and args.landscape:
            turn_device(udid, None)
        if boot:
            sim("shutdown", udid)


def upright(file, way):
    """simctl captures the display as it is mounted, upright: turn the picture
    the way the interface turned, so it reads as the player sees it."""
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(file)],
                         capture_output=True, text=True, check=True).stdout.split()
    w, h = int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])
    if h > w:
        subprocess.run(["sips", "-r", "90" if way == "left" else "270", str(file)],
                       capture_output=True, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "build/solo-snapshots")
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--only", type=lambda v: set(v.split(",")), default=None,
                        help="comma-separated shot names (implies --capture-only)")
    parser.add_argument("--phone", action="append", choices=list(DEVICES),
                        help="one review device (repeatable)")
    parser.add_argument("--ipad", action="store_true", help="the two review iPads, not the phones")
    parser.add_argument("--landscape", choices=["left", "right"],
                        help="turn the interface this way (the landscape shots)")
    parser.add_argument("--scene", choices=list(SCENES),
                        help="the shots in a scene (<phone>-<scene>-<shot>.png; implies --capture-only)")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    phones = args.phone or (IPADS if args.ipad else PHONES)
    if args.only or args.scene:
        args.capture_only = True
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda phone: capture(phone, args), phones))
    if not args.capture_only:
        tag = "-landscape" if args.landscape else ""
        shots = LANDSCAPE if args.landscape else [m for m in SHOTS if m not in LANDSCAPE_ONLY]
        subprocess.run(["swift", str(ROOT / "tools/check-snapshots.swift"), str(ROOT / "docs/review"),
                        str(args.out), *[f"{DEVICES[p]}{tag}-{m}.png"
                                       for p in phones for m in shots]], check=True)
