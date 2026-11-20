-- The wind (Jamie and Tyler, 2026-11-14: "optional in a game to turn on wind
-- ... some indicator ... wind would affect the baton throws and kubb
-- throws"). Pure: no playdate.*.
--
-- A match's wind level comes from its options (WIND: off, light, strong).
-- Each turn the wind has a direction and a speed (wind.turn); each throw is a
-- gust of it (wind.gust): the speed and direction vary a little, so no two
-- throws meet quite the same air. Directions are in the world frame (radians,
-- the way the wind blows toward, 0 = +x), turned into a thrower's view frame
-- by wind.vector. core/world pushes the thrown piece with it in the air
-- (world.windX/Y, airDrag).
--
--   wind.levels        { off = 0, light = 2.5, strong = 6 } m/s, the turn's mean
--   wind.turn(rng, level)      dir, speed for a turn (speed 0 when off)
--   wind.gust(rng, dir, speed) dir, speed for one throw
--   wind.vector(dir, speed, side)  wx, wy in that side's view frame
--   wind.text(speed)           "WIND 4 M/S" (whole m/s, at least 1), nil when calm
import "core/tw"

local wind = {}

wind.levels = { off = 0, light = 2.5, strong = 6 }

wind.tune = {
	turnLow = 0.6,    -- a turn's speed: the level's mean times between these
	turnHigh = 1.3,
	gust = 0.25,      -- a throw's speed: the turn's times 1 +- this (uniform)
	gustDeg = 12,     -- a throw's direction: the turn's +- this (sd, degrees)
}

local pi, cos, sin, rad = math.pi, math.cos, math.sin, math.rad

function wind.turn(rng, level)
	local mean = wind.levels[level or "off"] or 0
	if mean <= 0 then return 0, 0 end
	local t = wind.tune
	return rng.uniform(-pi, pi), mean * rng.uniform(t.turnLow, t.turnHigh)
end

function wind.gust(rng, dir, speed)
	if speed <= 0 then return dir, 0 end
	local t = wind.tune
	return dir + rad(rng.normal(t.gustDeg)), speed * (1 + rng.uniform(-t.gust, t.gust))
end

-- Team B throws in the pitch turned 180 degrees (core/frame): a vector turns too.
function wind.vector(dir, speed, side)
	local wx, wy = speed * cos(dir), speed * sin(dir)
	if side == "B" then return -wx, -wy end
	return wx, wy
end

function wind.text(speed)
	if not speed or speed <= 0 then return nil end
	local n = math.floor(speed + 0.5)
	if n < 1 then n = 1 end
	return "WIND " .. n .. " M/S"
end

tw.wind = wind
