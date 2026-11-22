-- The scenes (0.14; Jamie, 2026-11-21 and 22: "a Scene should have an allowed set of
-- surfaces and pitch types. This way scenes can have special and unique Kubb sets and
-- pitches... it allows the Playdate 'scene' to become a 1st class object and work in the
-- other games"). The engine's catalogue: for each scene its id, the name a client shows,
-- the surfaces it allows (one the default), the kubb sets it allows (one the default) and
-- a few flags a renderer reads. A scene decides: a match option's surface and set are
-- held to the scene's (scenes.resolve), and a client offers a choice only where the
-- scene leaves one (scenes.choices). Pure: no playdate.*. The Playdate's own look is
-- Black & White (core/matchopts).
--
--   scenes.DEFAULT                  "day" (Park): what a match that names no scene draws
--   scenes.list                     the scenes in the order a card offers them
--   scenes.byId[id]                 an entry, or nil
--   scenes.known(id)                is it one of the catalogue's ids?
--   scenes.get(id)                  its entry; an id the catalogue does not have is Park's
--   scenes.resolve(id, surface, set)  scene id, surface, set: the scene (an unknown id is
--                                   "day"), the surface if the scene allows it (else its
--                                   default), the set likewise
--   scenes.choices(id)              the option keys ("surface", "set") the scene leaves to
--                                   the player: those it allows more than one value of
--   scenes.SURFACES, scenes.SETS    every surface the engine plays and every set it takes
--                                   (sweden and wisconsin are in no scene but still load)
--   scenes.surfaceName[k], setName[k]  the words for them
--
-- An entry: { id, name, surfaces = { ... }, surface, sets = { ... }, set,
--   dark = bool (a dark sky: draw light on dark), ring = bool (a ground impact rings:
--   the session's impacts, docs/SESSION.md), mono = bool (black and white only) }.
-- The stored ids of three scenes are older than their names: day is Park, night is
-- Camping, neon is Techno.
import "core/tw"

local scenes = {}

scenes.DEFAULT = "day"

scenes.SURFACES = { "grass", "sand", "snow", "grid" }
scenes.surfaceName = { grass = "Grass", sand = "Sand", snow = "Snow", grid = "Grid" }
scenes.SETS = { "classic", "usa", "sweden", "minnesota", "wisconsin" }
scenes.setName = { classic = "Classic", usa = "USA", sweden = "Sweden", minnesota = "Minnesota",
	wisconsin = "Wisconsin" }

scenes.list = {
	-- what there has always been: a grassy park in daylight
	{ id = "day", name = "Park", surfaces = { "grass" }, surface = "grass", sets = { "classic" }, set = "classic",
		dark = false, ring = false, mono = false },
	-- the sand pitch's own scene
	{ id = "beach", name = "Beach", surfaces = { "sand" }, surface = "sand", sets = { "classic" }, set = "classic",
		dark = false, ring = false, mono = false },
	-- the night scene: a campsite after dark
	{ id = "night", name = "Camping", surfaces = { "grass" }, surface = "grass", sets = { "classic" },
		set = "classic", dark = true, ring = false, mono = false },
	-- a dark neon grid on an electronic floor, "intentionally flat and electronic, maybe
	-- even magnetic" (the grid surface, core/world), where "when something hits the floor
	-- it should give a visual ring on impact"
	{ id = "neon", name = "Techno", surfaces = { "grid" }, surface = "grid", sets = { "classic" }, set = "classic",
		dark = true, ring = true, mono = false },
	-- "so there is a place for Snow", with the Minnesota set
	{ id = "minnesota", name = "Minnesota", surfaces = { "snow" }, surface = "snow", sets = { "minnesota" },
		set = "minnesota", dark = false, ring = false, mono = false },
	-- a kubb tournament: a grid of pitches all live (the neighbouring pitches are not
	-- built: docs/notes/tournament.md), the one scene with the USA set's colouring. No
	-- championship's name or logo anywhere
	{ id = "tournament", name = "Tournament", surfaces = { "grass" }, surface = "grass", sets = { "usa" },
		set = "usa", dark = false, ring = false, mono = false },
	-- "This IS the Playdate": the plain black and white view of any pitch, for every game
	{ id = "bw", name = "Black & White", surfaces = { "grass", "sand", "snow" }, surface = "grass",
		sets = { "classic" }, set = "classic", dark = false, ring = false, mono = true },
}

scenes.byId = {}
for _, e in ipairs(scenes.list) do scenes.byId[e.id] = e end

local function has(list, v)
	for _, x in ipairs(list) do if x == v then return true end end
	return false
end

function scenes.known(id)
	return type(id) == "string" and scenes.byId[id] ~= nil
end

function scenes.get(id)
	return (type(id) == "string" and scenes.byId[id]) or scenes.byId[scenes.DEFAULT]
end

function scenes.resolve(id, surface, set)
	local e = scenes.get(id)
	return e.id, has(e.surfaces, surface) and surface or e.surface, has(e.sets, set) and set or e.set
end

function scenes.choices(id)
	local e, out = scenes.get(id), {}
	if #e.surfaces > 1 then out[#out + 1] = "surface" end
	if #e.sets > 1 then out[#out + 1] = "set" end
	return out
end

tw.scenes = scenes
