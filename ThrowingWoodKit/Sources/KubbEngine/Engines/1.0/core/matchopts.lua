-- The match options (Jamie, 2026-11-14: "essentially it is the game options
-- for the match you are starting"): chosen on scenes/options before each
-- match, after the names. Pure: no playdate.*.
--
--   matchopts.list           the rows, in order: key, label, values, shown
--   matchopts.defaults()     a choice table { surface = 1, opening = 1, raising = 1, wind = 1,
--                            computer = 2 } (a row's `default`, else its first value)
--   matchopts.valid(c)       a choice table read back from the datastore, or the defaults
--   matchopts.step(c, key, d)  the value of row `key` moved by d (-1 or 1), wrapping
--   matchopts.value(c, key)  the chosen value; matchopts.shown(c, key) its words
--   matchopts.apply(opts, c) the scenes/match options the choice makes
--   matchopts.scene          "bw": the Playdate's scene (core/scenes, since 0.14)
import "core/tw"
import "core/scenes"

local matchopts = {}

-- The Playdate draws one scene, Black & White ("This IS the Playdate", Jamie
-- 2026-11-21): its Surface row is the surfaces that scene allows (core/scenes), and
-- apply names it in the options. It has no Scene row and no Kubbs row.
matchopts.scene = "bw"
local bw = tw.scenes.get(matchopts.scene)
local surfaceValues, surfaceShown = {}, {}
for i, k in ipairs(bw.surfaces) do
	surfaceValues[i] = tw.scenes.surfaceName[k]
	surfaceShown[i] = string.upper(tw.scenes.surfaceName[k])
end

matchopts.list = {
	{ key = "surface", label = "SURFACE", values = surfaceValues, shown = surfaceShown },
	{ key = "opening", label = "OPENING", values = { "2-4-6", "six" },
		shown = { "2-4-6", "SIX FROM THE START" } },
	{ key = "raising", label = "RAISING", values = { "hand", "auto" }, shown = { "BY HAND", "AUTOMATIC" } },
	-- the wind (Jamie and Tyler, 2026-11-14; core/wind)
	{ key = "wind", label = "WIND", values = { "off", "light", "strong" }, shown = { "OFF", "LIGHT", "STRONG" } },
	-- the computer's throw level, a game setting (Jamie, 2026-11-20: "yes this should be
	-- a real per game setting"); club by default. A person's own level stays theirs.
	-- Kid (0.15.0, docs/notes/kid-mode.md) is the fourth value so a choice kept before 0.15
	-- (an index) keeps its level; `order` is the order a press steps through, Kid first
	{ key = "computer", label = "COMPUTER", values = { "beginner", "club", "pro", "kid" },
		shown = { "BEGINNER", "CLUB", "PRO", "KID" }, default = 2, order = { 4, 1, 2, 3 } },
}

-- Not here: a Kubbs row and a Scene row. The Playdate's scene is Black & White, which
-- offers one set, classic (core/scenes); the web and the iPhone choose a scene through
-- the pitch's options (pitch/lobby optionRows). A choice table or save kept before 0.9
-- that carries `set` still loads: valid() reads only these rows' keys, and core/save
-- hands back whatever options it wrote.

local byKey = {}
for _, row in ipairs(matchopts.list) do byKey[row.key] = row end

function matchopts.defaults()
	local c = {}
	for _, row in ipairs(matchopts.list) do c[row.key] = row.default or 1 end
	return c
end

function matchopts.valid(c)
	local d = matchopts.defaults()
	if type(c) ~= "table" then return d end
	for _, row in ipairs(matchopts.list) do
		local v = c[row.key]
		if type(v) == "number" and v >= 1 and v <= #row.values and v == math.floor(v) then d[row.key] = v end
	end
	return d
end

function matchopts.step(c, key, d)
	local row = byKey[key]
	local n = #row.values
	if row.order then
		local at = 1
		for i, v in ipairs(row.order) do if v == c[key] then at = i end end
		c[key] = row.order[(at - 1 + d) % n + 1]
		return c[key]
	end
	c[key] = (c[key] - 1 + d) % n + 1
	return c[key]
end

function matchopts.value(c, key) return byKey[key].values[c[key]] end
function matchopts.shown(c, key) return byKey[key].shown[c[key]] end

-- opts (scenes/match options: names, vs, ...) with the surface, the opening,
-- whether the engine raises the kubbs (autoSettle), the wind and the computer's
-- level (opts.computer: the level each computer player throws at) from the choice. The
-- Kid computer makes the match a Kid match (0.15.0): opts.rules = "kid", which a client
-- passes to match.new as `rules` (and plans a person's throw on plan.meter("kid")).
-- It sets no kubb set (since 0.9): opts.set is left as the caller had it. Since 0.14 it
-- names the scene, opts.scene = "bw" (nothing in the core reads it; the save keeps none).
function matchopts.apply(opts, c)
	opts.surface = matchopts.value(c, "surface")
	opts.opening = matchopts.value(c, "opening")
	opts.autoSettle = matchopts.value(c, "raising") == "auto" or nil
	opts.wind = matchopts.value(c, "wind")
	opts.computer = matchopts.value(c, "computer")
	opts.rules = opts.computer == "kid" and "kid" or nil
	opts.scene = matchopts.scene
	return opts
end

tw.matchopts = matchopts
