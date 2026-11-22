#!/bin/sh
# The App Store pictures (docs/store): eight portrait screens of the app on the iPhone 17
# Pro Max (1320 x 2868, Apple's large Dynamic Island class) and the iPad Pro 13-inch
# (2064 x 2752, the 13-inch class), from a Release simulator build, the status bar at
# 9:41 with a full battery, the whole framebuffer (no Dynamic Island or corners drawn, as
# a device's own screenshot), invented names, no words added. docs/DISTRIBUTION.md.
#
#   tools/store-snapshots.sh [<app>] [<number>...]
#
# With numbers, only those pictures are retaken (e.g. 6 for the Tournament).
set -eu
cd "$(dirname "$0")/.."
app=${1:-build/dd/Build/Products/Release-iphonesimulator/ThrowingWood.app}
[ $# -gt 0 ] && shift
want=" ${*:-1 2 3 4 5 6 7 8} "
out=build/store-set
mkdir -p "$out" docs/store
# number: name, the solo tool's shot, and its arguments. Picture 8 is the winner card,
# with the score sheet beside it as an alternate (the owner chooses); both are the finished
# match stamped 24 minutes long (--finish), as a played match is.
shots='1 aim aim
2 hit verdict
3 scenes options
4 techno ring --scene neon
5 camping aim --scene night
6 tournament neighbours --scene tournament
7 kid kidstand
8 winner winner --finish 24
8 sheet-alternate sheet --finish 24'
echo "$shots" | while read -r n name shot rest; do
  case $want in *" $n "*) ;; *) continue ;; esac
  rm -f "$out"/*.png
  # shellcheck disable=SC2086
  python3 tools/solo-snapshots.py "$app" --capture-only --unmasked --out "$out" --player "Brave Birch" \
    --phone "iPhone 17 Pro Max" --phone "iPad Pro 13-inch (M5)" --only "$shot" $rest
  for f in "$out"/*.png; do
    device=$(basename "$f" | sed -E 's/^(iphone-17-pro-max|ipad-pro-13)-.*/\1/')
    cp "$f" "docs/store/$device-$n-$name.png"
    # App Store Connect takes no alpha channel; simctl's PNGs have one on an iPad
    swift tools/flatten-png.swift "docs/store/$device-$n-$name.png"
  done
done
