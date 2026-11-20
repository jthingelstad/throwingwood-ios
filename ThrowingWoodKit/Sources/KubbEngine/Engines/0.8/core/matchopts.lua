-- The match options (Jamie, 2026-11-14: "essentially it is the game options
-- for the match you are starting"): chosen on scenes/options before each
-- match, after the names. Pure: no playdate.*.
--
--   matchopts.list           the rows, in order: key, label, values, shown
--   matchopts.defaults()     a choice table { surface = 1, opening = 1, raising = 1, set = 1, wind = 1 }
--   matchopts.valid(c)       a choice table read back from the datastore, or the defaults
--   matchopts.step(c, key, d)  the value of row `key` moved by d (-1 or 1), wrapping
--   matchopts.value(c, key)  the chosen value; matchopts.shown(c, key) its words
--   matchopts.apply(opts, c) the scenes/match options the choice makes
import "core/tw"

local matchopts = {}

matchopts.list = {
	{ key = "surface", label = "SURFACE", values = { "Grass", "Sand", "Snow" }, shown = { "GRASS", "SAND", "SNOW" } },
	{ key = "opening", label = "OPENING", values = { "2-4-6", "six" },
		shown = { "2-4-6", "SIX FROM THE START" } },
	{ key = "raising", label = "RAISING", values = { "hand", "auto" }, shown = { "BY HAND", "AUTOMATIC" } },
	-- the kubb set (Jamie, 2026-11-14; render/world's sets: painted heads and crown)
	{ key = "set", label = "SET", values = { "classic", "usa", "sweden", "minnesota", "wisconsin" },
		shown = { "CLASSIC", "USA", "SWEDEN", "MINNESOTA", "WISCONSIN" } },
	-- the wind (Jamie and Tyler, 2026-11-14; core/wind)
	{ key = "wind", label = "WIND", values = { "off", "light", "strong" }, shown = { "OFF", "LIGHT", "STRONG" } },
}

local byKey = {}
for _, row in ipairs(matchopts.list) do byKey[row.key] = row end

function matchopts.defaults()
	local c = {}
	for _, row in ipairs(matchopts.list) do c[row.key] = 1 end
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
	local n = #byKey[key].values
	c[key] = (c[key] - 1 + d) % n + 1
	return c[key]
end

function matchopts.value(c, key) return byKey[key].values[c[key]] end
function matchopts.shown(c, key) return byKey[key].shown[c[key]] end

-- opts (scenes/match options: names, vs, ...) with the surface, the opening,
-- whether the engine raises the kubbs (autoSettle), the kubb set and the wind
-- from the choice.
function matchopts.apply(opts, c)
	opts.surface = matchopts.value(c, "surface")
	opts.opening = matchopts.value(c, "opening")
	opts.autoSettle = matchopts.value(c, "raising") == "auto" or nil
	opts.set = matchopts.value(c, "set")
	opts.wind = matchopts.value(c, "wind")
	return opts
end

tw.matchopts = matchopts
