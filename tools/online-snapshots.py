"""Compare the iPhone online screens with loopback rooms and invented players."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODES = (
    "entry share join host guest flight shout handoff winner menu report newer older "
    "connecting reconnecting notFound full unreachable replaced"
).split()
PHONES = ["iPhone 16e", "iPhone 17 Pro Max"]


def sim(*args, **kwargs):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kwargs)


def filename(phone, mode):
    return phone.lower().replace(" ", "-") + "-" + mode + ".png"


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
        for mode in args.modes:
            file = args.out / filename(phone, mode)
            subprocess.run(
                ["node", str(ROOT / "tools/online-review.mjs"), str(args.web), udid, mode, str(file)],
                check=True,
            )
            print(phone, mode, flush=True)
    finally:
        sim("status_bar", udid, "clear")
        if boot:
            sim("shutdown", udid)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--web", type=Path, default=ROOT.parent / "kubb.thingelstad.xyz")
    parser.add_argument("--out", type=Path, default=ROOT / "build/online-snapshots")
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--modes", nargs="+", default=MODES, choices=MODES)
    parser.add_argument("--phones", nargs="+", default=PHONES, choices=PHONES)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda phone: capture(phone, args), args.phones))
    if not args.capture_only:
        names = [filename(phone, mode) for phone in args.phones for mode in args.modes]
        subprocess.run(
            ["swift", str(ROOT / "tools/check-snapshots.swift"), str(ROOT / "docs/review/online"),
             str(args.out), *names],
            check=True,
        )
