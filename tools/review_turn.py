"""Turn a review iPad's simulator for the landscape pictures.

iPadOS refuses the app's own request to turn (the windowing mode decides), so
a UI-testing bundle (tools/review-turn) turns the simulated device, after
setting Full Screen Apps in Settings (a window test leaves Windowed Apps on).
The iPhones turn themselves from REVIEW_ORIENTATION, as before.
"""
from pathlib import Path
import os
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "tools/review-turn/ReviewTurn.xcodeproj"
DERIVED = ROOT / "build/review-turn"
_built = threading.Lock()


def is_ipad(name):
    return name.startswith("iPad")


def turn(udid, way):
    """Full Screen Apps (the review pictures' mode), then turned: way is
    "left" or "right" (the interface's), or None for upright."""
    with _built:
        if not (DERIVED / "Build/Products").exists():
            subprocess.run(["xcodebuild", "build-for-testing", "-project", str(PROJECT),
                            "-scheme", "ReviewTurn", "-destination", "generic/platform=iOS Simulator",
                            "-derivedDataPath", str(DERIVED), "CODE_SIGNING_ALLOWED=NO"],
                           check=True, capture_output=True)
    env = {**os.environ, "TEST_RUNNER_TURN": way or "upright"}
    subprocess.run(["xcodebuild", "test-without-building", "-project", str(PROJECT),
                    "-scheme", "ReviewTurn", "-destination", f"id={udid}",
                    "-derivedDataPath", str(DERIVED), "-only-testing:ReviewTurn/Turn/testMode", "-only-testing:ReviewTurn/Turn/testTurn"],
                   check=True, capture_output=True, env=env)
