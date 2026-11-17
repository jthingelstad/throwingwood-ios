-- The game's version: the same pair as source/pdxinfo (`version` and
-- `buildNumber`), which is the source of truth. It sits in core so the web
-- game gets it through its vendor sync; tests/lua/test_version.lua fails when
-- the two disagree, and `make release` runs that test first. Raise both
-- together for every release.
import "core/tw"

local VERSION <const> = "0.9.6"
local BUILD <const> = 7

-- text: as a player sees it, "0.9.6 (7)"
tw.version = { version = VERSION, build = BUILD, text = VERSION .. " (" .. BUILD .. ")" }
