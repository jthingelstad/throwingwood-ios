"""Compare the iPhone online screens with loopback rooms and invented players.

--landscape left|right turns the interface on its side and names the pictures
<phone>-landscape-<mode>.png.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True  # no __pycache__ in tools/
from review_turn import is_ipad, turn as turn_device

ROOT = Path(__file__).resolve().parents[1]
MODES = (
    "entry share join host guest flight shout handoff winner menu report feedback newer older "
    "connecting reconnecting notFound full unreachable replaced"
).split()
# an observer and the open games list (pictures in docs/review/observer, by --modes)
OBSERVER = "observe observemoved watchcard noGame opengames".split()
PHONES = ["iPhone 16e", "iPhone 17 Pro Max"]
# a small and a large iPad, the same game on a bigger screen
IPADS = ["iPad mini (A17 Pro)", "iPad Pro 13-inch (M5)"]
NAMES = {"iPad mini (A17 Pro)": "ipad-mini", "iPad Pro 13-inch (M5)": "ipad-pro-13"}


def sim(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kwargs)


def filename(phone, mode, landscape=None, scene=None):
    return (NAMES.get(phone, phone.lower().replace(" ", "-")) + (f"-{scene}" if scene else "")
            + ("-landscape" if landscape else "") + "-" + mode + ".png")


def capture(phone, args):
    inventory = sim("list", "devices", "available", "-j", capture_output=True)
    devices = json.loads(inventory.stdout)["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-2"]
    device = next(d for d in devices if d["name"] == phone)
    udid = device["udid"]
    boot = device["state"] == "Shutdown"
    if boot:
        sim("boot", udid)
    try:
        sim("bootstatus", udid, "-b", stdout=subprocess.DEVNULL)
        sim("install", udid, str(args.app))
        sim("status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
        if is_ipad(phone):
            turn_device(udid, args.landscape)  # an iPad turns as a device, not from the app
        for mode in args.modes:
            file = args.out / filename(phone, mode, args.landscape, args.scene)
            env = dict(os.environ)
            if args.scene:
                env["SIMCTL_CHILD_REVIEW_SCENE"] = args.scene
            if args.landscape:
                env["SIMCTL_CHILD_REVIEW_ORIENTATION"] = args.landscape
            subprocess.run(
                ["node", str(ROOT / "tools/online-review.mjs"), str(args.web), udid, mode, str(file)],
                check=True, env=env,
            )
            print(phone, mode, flush=True)
    finally:
        sim("status_bar", udid, "clear")
        if is_ipad(phone) and args.landscape:
            turn_device(udid, None)
        if boot:
            sim("shutdown", udid)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--web", type=Path, default=ROOT.parent / "kubb.thingelstad.xyz")
    parser.add_argument("--out", type=Path, default=ROOT / "build/online-snapshots")
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--modes", nargs="+", default=MODES, choices=MODES + OBSERVER)
    parser.add_argument("--phones", nargs="+", default=PHONES, choices=PHONES + IPADS)
    parser.add_argument("--ipad", action="store_true", help="the two review iPads, not the phones")
    parser.add_argument("--landscape", choices=["left", "right"])
    parser.add_argument("--scene", choices=["night", "neon"],
                        help="host: the host picks this Scene in the lobby; observe: the match's"
                        " Scene (implies --capture-only)")
    args = parser.parse_args()
    if args.scene:
        args.capture_only = True
    if args.ipad:
        args.phones = IPADS
    args.out.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda phone: capture(phone, args), args.phones))
    if not args.capture_only:
        names = [filename(phone, mode, args.landscape) for phone in args.phones for mode in args.modes]
        subprocess.run(
            ["swift", str(ROOT / "tools/check-snapshots.swift"),
             str(ROOT / ("docs/review/observer" if set(args.modes) <= set(OBSERVER) else "docs/review/online")),
             str(args.out), *names],
            check=True,
        )
