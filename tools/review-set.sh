#!/bin/sh
# The review set (docs/review), one group at a time: one command retakes a group from a
# Release simulator build of this checkout and copies its PNGs into docs/review, where
# git shows what changed. docs/RENDER.md "Retaking the review set".
#
#   tools/review-set.sh <group> [<app>]
#
# Groups: phones, phones-side, ipads, ipads-side, scenes, scenes-side, scenes-ipad,
# ax3, meters, share, reel, raises, tournament, drive, extras, all. drive and extras
# (engine 0.16's drive and the computer's raise watched; the verdict over the next aim and
# a watched raise part way) are kept out of the repo, in build/review-private. <app> defaults to the Release
# build under build/dd (made with: xcodebuild -project ThrowingWood.xcodeproj -scheme
# ThrowingWood -configuration Release -destination 'generic/platform=iOS Simulator'
# -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build). reel needs REEL_VIDEOS, a
# directory holding one <name>-tall.mp4 and <name>-wide.mp4 (tools/reel-snapshots.py).
set -eu
cd "$(dirname "$0")/.."
group=${1:?group}
app=${2:-build/dd/Build/Products/Release-iphonesimulator/ThrowingWood.app}
out=build/review-set
mkdir -p "$out"
rm -f "$out"/*.png "$out"/*.json
# the raise and punishment shots, in a group of their own
raises=raise,raisemany,raiseauto,raiserest,raisedrag,raiserefused,punish,punishwhy
# the scenes a match can be in besides the day (the Tournament is its own group)
scenes="beach night neon minnesota bw"
solo() { python3 tools/solo-snapshots.py "$app" --capture-only --out "$out" "$@"; }
both_sides() {  # the 16e turned right and the Pro Max left, as the set has always been
  solo --phone "iPhone 16e" --landscape right "$@"
  solo --phone "iPhone 17 Pro Max" --landscape left "$@"
}
keep() { find "$out" -maxdepth 1 -name '*.png' -exec cp {} docs/review/ \; ; }
private() { mkdir -p build/review-private && find "$out" -maxdepth 1 -name '*.png' -exec cp {} build/review-private/ \; ; }
case $group in
  phones) solo --skip "$raises" ;;
  phones-side) both_sides --skip "$raises" ;;
  ipads) solo --ipad --skip "$raises" ;;
  ipads-side) solo --ipad --landscape left --skip "$raises" ;;
  scenes) for s in $scenes; do solo --scene "$s" --skip "$raises"; done ;;
  scenes-side) for s in $scenes; do both_sides --scene "$s"; done ;;
  scenes-ipad) for s in $scenes; do solo --ipad --scene "$s" --only aim,flight,winner; done ;;
  ax3) solo --phone "iPhone 16e" --text-size accessibility-extra-extra-extra-large ;;
  meters)
    for p in "iPhone 16e" "iPhone 17 Pro Max"; do
      python3 tools/meter-snapshots.py "$app" --device "$p" --review-names --out "$out"
    done
    python3 tools/meter-snapshots.py "$app" --device "iPhone 16e" --landscape right --review-names --out "$out"
    python3 tools/meter-snapshots.py "$app" --device "iPhone 17 Pro Max" --landscape left --review-names --out "$out"
    xcrun simctl shutdown "iPhone 16e" "iPhone 17 Pro Max" 2>/dev/null || true
    ;;
  share)
    # "sealed" and "sealedold" restore the solo fixture through the engine's check from
    # outside, which no longer takes it (2026-11-22): left out until the fixture is renewed
    all=winner,sharedwinner,card,cardlong,checking,shared,toolong,engine,doesnotreplay,busy,unavailable,toomany,failed,notthistime,offline,sealedloading,sealedfailed
    shapes=winner,card,cardlong,checking,failed,shared
    python3 tools/share-snapshots.py "$app" --only "$all" --out "$out/share"
    python3 tools/share-snapshots.py "$app" --landscape left --only "$shapes" --out "$out/share"
    python3 tools/share-snapshots.py "$app" --ipad --only "$shapes" --out "$out/share"
    mkdir -p docs/review/share && cp "$out"/share/*.png docs/review/share/
    exit 0
    ;;
  reel)
    v=${REEL_VIDEOS:?REEL_VIDEOS}
    python3 tools/reel-snapshots.py "$app" --videos "$v" --capture-only --out "$out/reel"
    python3 tools/reel-snapshots.py "$app" --videos "$v" --landscape left --capture-only --out "$out/reel"
    python3 tools/reel-snapshots.py "$app" --videos "$v" --ipad --capture-only --out "$out/reel"
    python3 tools/reel-snapshots.py "$app" --videos "$v" --ipad --landscape left --capture-only --out "$out/reel"
    cp "$out"/reel/*.png docs/review/reel/
    exit 0
    ;;
  raises)
    solo --only "$raises" && both_sides --only "$raises"
    solo --ipad --only "$raises" && solo --ipad --landscape left --only "$raises"
    # the raise and punishment scenes in each scene's skin
    for s in $scenes; do solo --scene "$s" --only raise,punish; done
    ;;
  tournament)
    solo --scene tournament --skip "$raises" && both_sides --scene tournament
    solo --ipad --scene tournament --only aim,flight,winner,neighbours,neighbourswide
    solo --ipad --landscape left --scene tournament --only neighbours,neighbourswide
    ;;
  drive)
    solo --drive && solo --drive --phone "iPhone 16e" --landscape right --only arc-open-1_5m,arc-open-4m,drive-flight-2,drive-verdict
    solo --drive --ipad --only arc-open-1_5m,arc-open-4m,drive-flight-2,drive-verdict
    private; exit 0
    ;;
  extras)
    solo --only verdictaim,raisetip && both_sides --only verdictaim,raisetip
    private; exit 0
    ;;
  all)
    for g in phones phones-side ipads ipads-side scenes scenes-side scenes-ipad ax3 meters share raises tournament drive extras; do
      "$0" "$g" "$app"
    done
    exit 0
    ;;
  *) echo "unknown group $group" >&2; exit 2 ;;
esac
keep
