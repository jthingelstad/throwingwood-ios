#!/bin/bash
# The app's icons, drawn from the game's own king by the pitch renderer
# (KubbRenderer's AppIconArt) and written into ThrowingWood/Assets.xcassets:
# AppIcon (Park, with its dark and tinted looks) and an icon set per other
# scene (AppIcon-Camping, AppIcon-Techno and the rest). Needs Xcode and nothing else.
#
#   scripts/make-app-icons.sh
#
# Run it after changing AppIconArt or the king's drawing, and commit the PNGs.
# A new scene's icon is one line in AppIconArt.icons (docs/RENDER.md
# "The app icon").
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
swift run -c release --package-path "$root/ThrowingWoodKit" make-app-icons \
  "$root/ThrowingWood/Assets.xcassets"
