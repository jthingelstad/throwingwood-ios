-- The engine's version (docs/VERSIONING.md). engine.json carries the same string and
-- `make test` fails when they differ. Not in core/: the core is what the Playdate
-- vendors on its own, and the version names the whole engine (core, session, tune).
import "core/tw"

local VERSION <const> = "1.4.0"

tw.engine = { name = "kubb-engine", version = VERSION }
return VERSION
