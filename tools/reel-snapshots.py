"""The highlight reel card in each of its states, on the review phones and iPads.

The app shows the card over a finished match (the solo "over" fixture) with no
network: REEL_REVIEW names the state and the card's server is a stand-in
(ReelCard.swift). The done state plays a real reel, paused on one frame: pass
--videos, a directory holding one <name>-tall.mp4 and <name>-wide.mp4 made by
the web's renderer (in a copy of the web checkout, never the checkout itself):

  node tools/reel/render.mjs --replay tests/fixtures/replay-north-south.json --out <dir>

--landscape left|right turns the interface (an iPad turns as a device) and
names the pictures <device>-landscape-<state>.png. --sim-prefix picks simulators of
your own (created as "<prefix>iPhone 16e" and so on) when another session uses the
shared ones.
"""
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
# Every state on the phones held upright; the ones whose shape changes with the
# window (the bar, the video, a problem with its button) also turned and on iPads.
STATES = ("making makingoffline done failed notthistime offline empty busy engine unavailable "
          "toomany noreplay moved").split()
SHAPES = ["making", "done", "failed", "offline"]
APP = "com.throwingwood.app"
DEVICES = {
    "iPhone 16e": "iphone-16e", "iPhone 17 Pro Max": "iphone-17-pro-max",
    "iPad mini (A17 Pro)": "ipad-mini", "iPad Pro 13-inch (M5)": "ipad-pro-13",
}
PHONES = ["iPhone 16e", "iPhone 17 Pro Max"]
IPADS = ["iPad mini (A17 Pro)", "iPad Pro 13-inch (M5)"]


def sim(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kwargs)


def states_for(phone, args):
    if args.only:
        return [s for s in STATES if s in args.only]
    return STATES if not args.landscape and not is_ipad(phone) else SHAPES


def capture(phone, args):
    devices = json.loads(sim("list", "devices", "available", "-j", capture_output=True).stdout)
    device = next(d for d in devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-2"]
                  if d["name"] == args.sim_prefix + phone)
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
        shutil.copyfile(ROOT / "ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/solo/over.json",
                        tmp / "review-solo.json")
        for f in ("tall", "wide"):
            shutil.copyfile(next(args.videos.glob(f"*-{f}.mp4")), tmp / f"review-reel-{f}.mp4")
        if is_ipad(phone):
            turn_device(udid, args.landscape)  # an iPad turns as a device, not from the app
        prefix = DEVICES[phone] + ("-landscape" if args.landscape else "")
        turn = {"SIMCTL_CHILD_REVIEW_ORIENTATION": args.landscape} if args.landscape else {}
        for state in states_for(phone, args):
            ready = tmp / "review-ready"
            ready.unlink(missing_ok=True)
            sim("launch", "--terminate-running-process", udid, APP, "-pitch.throwsMade", "9",
                env={**os.environ, **turn, "SIMCTL_CHILD_REEL_REVIEW": state},
                stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 30
            while not ready.exists() or ready.read_text() != "reel-" + state:
                if time.monotonic() > deadline:
                    raise RuntimeError(f"{phone} did not reach {state}")
                time.sleep(0.1)
            time.sleep(0.7)  # the launch transition and SwiftUI's transaction
            file = args.out / f"{prefix}-{state}.png"
            sim("io", udid, "screenshot", str(file), capture_output=True)
            if args.landscape:
                upright(file, args.landscape)
            print(f"{phone} {state}", flush=True)
    finally:
        sim("status_bar", udid, "clear")
        subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
        if is_ipad(phone) and args.landscape:
            turn_device(udid, None)
        if boot:
            sim("shutdown", udid)


def upright(file, way):
    """simctl captures a phone's display as it is mounted: turn the picture the
    way the interface turned (solo-snapshots.py)."""
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(file)],
                         capture_output=True, text=True, check=True).stdout.split()
    w, h = int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])
    if h > w:
        subprocess.run(["sips", "-r", "90" if way == "left" else "270", str(file)],
                       capture_output=True, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("--videos", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=ROOT / "build/reel-snapshots")
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--only", type=lambda v: set(v.split(",")), default=None,
                        help="comma-separated states (implies --capture-only)")
    parser.add_argument("--phone", action="append", choices=list(DEVICES),
                        help="one review device (repeatable)")
    parser.add_argument("--ipad", action="store_true", help="the two review iPads, not the phones")
    parser.add_argument("--landscape", choices=["left", "right"])
    parser.add_argument("--sim-prefix", default="",
                        help="use the simulators named <prefix><device> (your own, leaving others' alone)")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    phones = args.phone or (IPADS if args.ipad else PHONES)
    if args.only:
        args.capture_only = True
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda phone: capture(phone, args), phones))
    if not args.capture_only:
        tag = "-landscape" if args.landscape else ""
        names = [f"{DEVICES[p]}{tag}-{s}.png" for p in phones for s in states_for(p, args)]
        subprocess.run(["swift", str(ROOT / "tools/check-snapshots.swift"),
                        str(ROOT / "docs/review/reel"), str(args.out), *names], check=True)
