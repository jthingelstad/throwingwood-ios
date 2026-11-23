#!/bin/sh
# The App Store pictures (docs/store): eight portrait screens of the app on the iPhone 17
# Pro Max (1320 x 2868, Apple's large Dynamic Island class) and the iPad Pro 13-inch
# (2064 x 2752, the 13-inch class), from a Release simulator build, the status bar at
# 9:41 with a full battery, the whole framebuffer (no Dynamic Island or corners drawn, as
# a device's own screenshot), invented names, no words added. Every one is play on a
# pitch (the owner, 2026-11-22: "highlight some of the different scenes in the
# screenshots. no scoresheet -- show gameplay"): each of the seven scenes at least once,
# no menu, card or score sheet. docs/DISTRIBUTION.md "Screenshots".
#
#   tools/store-snapshots.sh [<app>] [<number>...]
#
# With numbers, only those pictures are retaken (e.g. 5 for the Tournament). Pictures the
# set no longer has are removed from docs/store.
set -eu
cd "$(dirname "$0")/.."
app=${1:-build/dd/Build/Products/Release-iphonesimulator/ThrowingWood.app}
[ $# -gt 0 ] && shift
want=" ${*:-1 2 3 4 5 6 7 8} "
out=build/store-set
mkdir -p "$out" docs/store
# number: name, the solo tool's shot, and its arguments. The first three are the ones a
# search result shows: the throw itself in Park, Techno's black grid, Camping's night.
shots='1 aim wound
2 techno ring --scene neon
3 camping flight --scene night
4 kid kidstand --scene beach
5 tournament neighboursflight --scene tournament
6 raise raisemanydrag --scene minnesota
7 drive drive-flight-5 --scene bw
8 hit drive-verdict'
echo "$shots" | while read -r n name shot rest; do
  case $want in *" $n "*) ;; *) continue ;; esac
  rm -f "$out"/*.png
  # shellcheck disable=SC2086
  python3 tools/solo-snapshots.py "$app" --capture-only --unmasked --out "$out" --player "Brave Birch" \
    --phone "iPhone 17 Pro Max" --phone "iPad Pro 13-inch (M5)" --only "$shot" $rest
  for f in "$out"/*.png; do
    device=$(basename "$f" | sed -E 's/^(iphone-17-pro-max|ipad-pro-13)-.*/\1/')
    # one picture a number: an earlier set's picture under another name goes
    find docs/store -name "$device-$n-*.png" ! -name "$device-$n-$name.png" -exec rm {} +
    cp "$f" "docs/store/$device-$n-$name.png"
    # App Store Connect takes no alpha channel; simctl's PNGs have one on an iPad
    swift tools/flatten-png.swift "docs/store/$device-$n-$name.png"
  done
done
