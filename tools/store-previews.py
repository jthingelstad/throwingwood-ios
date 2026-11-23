"""Film and cut the App Store preview: real play in the app as built, three scenes.

    python3 tools/store-previews.py [<simulator app>] [--cut-only]

The app is not launched in any review mode. For each scene a kept match
(tools/store-previews/<name>.json, made by tools/preview-positions.mjs) is put where
the app keeps its own, the app is launched as a player launches it and resumes the
match, the simulator's screen is recorded (xcrun simctl io recordVideo, no sound),
and a UI-testing bundle (tools/review-turn, Play) makes the throws with touches: a
tap on THROW, a drag of the aim, a swing round the clock. Whatever the throw does is
what is filmed. The takes are then cut by the times the touches were made and joined
with plain cuts into one H.264 file to Apple's app preview specification
(docs/DISTRIBUTION.md "App previews"), with a silent stereo track.

The phone is the iPhone 16e's simulator: a recording of a Dynamic Island simulator
has the island drawn into every frame as a black pill, which a phone's own screen
recording never has, and the 16e's screen is the same shape (1170 x 2532).

Output, under build/store-previews (not committed): takes/<name>.mov and .json,
iphone-17-pro-max-preview-1.mp4 (886 x 1920, the size of every Face ID iPhone class)
and its frame at 5 s, the store's default poster.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
POSITIONS = ROOT / "tools/store-previews"
OUT = ROOT / "build/store-previews"
TAKES = OUT / "takes"
PROJECT = ROOT / "tools/review-turn/ReviewTurn.xcodeproj"
DERIVED = ROOT / "build/review-turn"
APP = "com.throwingwood.app"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
PHONE = "iPhone 16e"
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
NAME = "iphone-17-pro-max-preview-1"
SIZE = (886, 1920)

# The 16e upright, in points: the clock (ClockMeter(bounds:bottomInset:) for 390 x 844
# with 34 pt of safe area) and the hand-off card's THROW.
CLOCK = "195 682.2 85.8"
THROW = "195 748"
# How a throw is swung: back at 300 degrees a second, held 0.15 s, flicked at 2400.
SWING = "300 2400 0.15"


def swing(back, stop):
    """A swing to the middle of the power band and of the release band, the dial's
    degrees for the position (tools/preview-positions.mjs prints them)."""
    return f"swing {CLOCK} {back} {stop} {SWING}"


# Each take: its position, the steps played (tools/review-turn Play), and the cut, as
# seconds before one step's mark and after another's ("<step index>" a step's start,
# "<step index>r" a swing's release).
SHOTS = [
    {   # Park: the opening throw. The aim dragged to the next base kubb, wound, flicked;
        # the kubb goes down about 1.2 s after the throw leaves the hand, which is 0.17 s
        # before the finger lifts. The cut starts 3.95 s before the lift so that moment is
        # the film's frame at 5 s, and ends before the next aim (3.2 s after the throw).
        "name": "park",
        "play": ["wait 1.5", f"tap {THROW}", "wait 1.0", "drag 250 440 360 440 1.5", "wait 0.9",
                 swing(131.3, 60), "wait 5"],
        "cut": ("5r", -3.95, "5r", 2.9),
    },
    {   # Techno: two batons into a knot of six field kubbs, rings on the grid.
        "name": "techno",
        "play": ["wait 2.5", swing(127.4, 28.9), "wait 4.4", swing(127.4, 28.9), "wait 5"],
        "cut": ("1", -0.9, "3r", 2.7),
    },
    {   # Camping: at the king. The cut ends with the king down and still, before the
        # verdict (about 1.9 s after the lift) and the winner card (2.8 s or more).
        "name": "camping",
        "play": ["wait 2.5", swing(133.7, 13.6), "wait 5"],
        "cut": ("1", -1.6, "1r", 1.85),
    },
]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def sim(*args, **kwargs):
    return run("xcrun", "simctl", *args, **kwargs)


def film(app):
    devices = json.loads(sim("list", "devices", "available", "-j", capture_output=True).stdout)
    device = next(d for d in devices["devices"][RUNTIME] if d["name"] == PHONE)
    udid = device["udid"]
    boot = device["state"] == "Shutdown"
    if boot:
        sim("boot", udid)
    run("xcodebuild", "build-for-testing", "-project", str(PROJECT), "-scheme", "ReviewTurn",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(DERIVED),
        "CODE_SIGNING_ALLOWED=NO", capture_output=True)
    try:
        sim("bootstatus", udid, "-b", stdout=subprocess.DEVNULL)
        sim("install", udid, str(app))
        sim("status_bar", udid, "override", "--time", "9:41", "--batteryState", "discharging",
            "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
        data = Path(sim("get_app_container", udid, APP, "data", capture_output=True, text=True).stdout.strip())
        kept = data / "Library/Application Support"
        for shot in SHOTS:
            subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
            kept.mkdir(parents=True, exist_ok=True)
            for old in kept.iterdir():
                old.unlink()
            # the app's own kept match (MatchSave): it resumes it at launch
            (kept / "solo-match.json").write_text((POSITIONS / f"{shot['name']}.json").read_text())
            # as a player launches it: no review mode, the clock at the right as it ships,
            # a device that has made its first throws (no coach line)
            sim("launch", udid, APP, "-pitch.meter", "clock", "-pitch.meterSide", "right",
                "-pitch.throwsMade", "9", stdout=subprocess.DEVNULL)
            time.sleep(2)
            movie = TAKES / f"{shot['name']}.mov"
            log = TAKES / f"{shot['name']}.log"
            with open(log, "w") as out:
                rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264",
                                        "--mask", "ignored", "--force", str(movie)], stdout=out, stderr=out)
            deadline = time.monotonic() + 20
            while "Recording started" not in log.read_text():
                if time.monotonic() > deadline:
                    raise RuntimeError("the recording did not start")
                time.sleep(0.01)
            began = time.time()
            try:
                played = run("xcodebuild", "test-without-building", "-project", str(PROJECT), "-scheme", "ReviewTurn",
                             "-destination", f"id={udid}", "-derivedDataPath", str(DERIVED),
                             "-only-testing:ReviewTurn/Play/testPlay", capture_output=True, text=True,
                             env={**os.environ, "TEST_RUNNER_PLAY": ";".join(shot["play"])}).stdout
            finally:
                rec.send_signal(signal.SIGINT)
                rec.wait()
            # each step's mark, in seconds into the recording
            marks = {}
            for line in played.splitlines():
                word = line.split()
                if len(word) == 4 and word[0] == "PLAY":
                    marks[word[1] + ("r" if word[2] == "release" else "")] = float(word[3]) - began
            (TAKES / f"{shot['name']}.json").write_text(json.dumps(marks, indent=1, sort_keys=True))
            print(f"{shot['name']}: filmed", flush=True)
    finally:
        sim("status_bar", udid, "clear")
        subprocess.run(["xcrun", "simctl", "terminate", udid, APP], capture_output=True)
        if boot:
            sim("shutdown", udid)


def cut():
    w, h = SIZE
    parts, graph = [], []
    for i, shot in enumerate(SHOTS):
        marks = json.loads((TAKES / f"{shot['name']}.json").read_text())
        a, before, b, after = shot["cut"]
        start, end = marks[a] + before, marks[b] + after
        parts += ["-i", str(TAKES / f"{shot['name']}.mov")]
        # simctl records a frame only when the screen changes: fps makes it a steady 30.
        # The 16e is 1170 x 2532, a hair wider than 886 x 1920: scaled to the height
        # (888 wide) and a pixel trimmed from each side.
        graph.append(f"[{i}:v]fps=30,trim=start={start:.3f}:end={end:.3f},setpts=PTS-STARTPTS,"
                     f"scale=-2:{h}:flags=lanczos,crop={w}:{h},setsar=1[v{i}]")
        print(f"{shot['name']}: {start:.2f} to {end:.2f} s of its take, {end - start:.2f} s", flush=True)
    n = len(SHOTS)
    graph.append("".join(f"[v{i}]" for i in range(n)) + f"concat=n={n}:v=1:a=0,format=yuv420p[v]")
    movie = OUT / f"{NAME}.mp4"
    # Apple's specification: H.264, progressive, High Profile level 4.0, 30 frames a
    # second, 10 to 12 Mbps (the flat drawing needs far less, so the rate is held at 11
    # with filler); stereo AAC at 256 kbps, 48 kHz (silence: the simulator's recording
    # has no sound, and none is added).
    run(FFMPEG, "-loglevel", "error", "-y", *parts, "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-filter_complex", ";".join(graph), "-map", "[v]", "-map", f"{n}:a",
        "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0", "-preset", "slow", "-r", "30",
        "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "11M",
        "-x264-params", "nal-hrd=cbr:keyint=30:force-cfr=1",
        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-shortest", "-movflags", "+faststart", str(movie))
    run(FFMPEG, "-loglevel", "error", "-y", "-ss", "5", "-i", str(movie), "-frames:v", "1",
        str(OUT / f"{NAME}-poster.png"))
    print(movie)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path, nargs="?",
                        default=ROOT / "build/dd/Build/Products/Release-iphonesimulator/ThrowingWood.app")
    parser.add_argument("--cut-only", action="store_true", help="cut the takes already filmed again")
    args = parser.parse_args()
    TAKES.mkdir(parents=True, exist_ok=True)
    if not args.cut_only:
        film(args.app)
    cut()
