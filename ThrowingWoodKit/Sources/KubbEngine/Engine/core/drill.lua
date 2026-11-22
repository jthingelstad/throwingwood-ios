-- Drilling a kubb (DESIGN.md "Kubbs (drilling)"). Pure Lua: no playdate.*.
--
-- The aim is a landing marker on the ground in the far half. The thrower
-- stands on the baseline straight behind it (no walk step). The game solves
-- a launch that lands a clean drill on the marker: a low loft chosen by the
-- distance (drill.solve), or the plan's arc (drill.solveAt, which
-- core/throwplan solves with), and the speed that carries the kubb there.
--
-- Play launches a drill with tw.plan.launch (core/throwplan), which judges
-- the swing against the plan and gives drill.body's numbers. drill.launch
-- is the older launch against a power band, kept for core/bench, the tools
-- and tests that throw a clean drill, and the throw scene until it
-- launches drills through the plan:
--   power      against a target band (the power the distance needs): in the
--              band the speed barely moves, outside it the kubb goes short or long
--   smoothness a clean flick keeps the nose down and the kubb dies near the
--              marker; a jerky one wobbles it and it runs on
--   tilt       pushes the line a little sideways, the way pull says (+1 right)
--   cut        spins the kubb about its long axis (+ clockwise from behind): it
--              holds the kubb's attitude to the touch; on the ground it moves
--              it a little either way (which corner strikes first decides)
--
-- All in one frame: x across, y away from the thrower (the throw scene's view
-- frame). world.launchDrill (core/world) makes the body from drill.body's
-- numbers.
import "core/tw"
import "core/flight"

local sqrt, sin, cos, atan, rad, abs, min, max =
	math.sqrt, math.sin, math.cos, math.atan, math.rad, math.abs, math.min, math.max

local drill = {}
local flight = tw.flight

drill.tune = {
	-- the marker (relative to the thrower's baseline)
	markerXMax = 3.0,       -- m either side of the middle: a little past the 2.5 m sidelines
	markerNear = 3.5,       -- m out: a little short of the middle line (4 m)
	markerFar = 8.6,        -- m out: a little past the far baseline (8 m)
	markerStartY = 5.5,     -- m out where the marker starts
	markerSpeed = 0.6,      -- m/s the d-pad moves the marker at first ...
	markerSpeedMax = 3.0,   -- ... rising to this while held
	markerAccel = 3.0,      -- m/s^2 between the two
	throwerXMax = 2.4,      -- m: the thrower stands on the baseline inside the stakes
	-- the solved launch
	loftNearDeg = 26,       -- loft for the nearest marker (guess; a low drill)
	loftFarDeg = 30,        -- loft for the farthest (higher, so a full swing reaches it)
	landZ = 0.07,           -- m: the kubb's center height when its lowest edge reaches the grass
	-- The run on (2026-11-16): a clean drill does not stop where it lands; it bounces,
	-- tumbles and rolls on (Jamie: "it is impossible to stop that much energy with just
	-- the ground and grass"). It is aimed short by the mean distance along the throw that
	-- a clean drill rests past where it lands, by the loft (slideLofts, a row each) and
	-- how far out it lands (slideR, a column each), in a line between them and the
	-- nearest outside them. A faster landing runs on farther until it digs in harder (on
	-- sand soonest). Measured again once an impact's friction was solved in the bounce
	-- (2026-11-16, and again 2026-11-20 for 0.10's nose and spins: tools/drillscatter.lua
	-- --only 5 --grounds 60: 3 lines x 60 grounds a cell, aimed with none, the mean rest
	-- along the throw past the aimed landing; the release attitude and spiral below).
	-- From 0.10 the spin counts too (slideSpins, rad/s about the long axis either way,
	-- a table each: none, and one, two and three taps): a spun kubb holds its nose to
	-- the touch and stops shorter, and the aim that ignored it sent every spun drill
	-- short of its mark by the difference. Measured again 2026-11-21 for 0.11's dead
	-- landing (world.tune deadLanding): a caught kubb stops where it touches, so a
	-- spun drill at the default arc is aimed 2 to 9 cm short on grass, not 24.
	slideSpins = { 0, 22, 44, 66 },
	slideLofts = { 26, 37, 47, 57 },
	slideR = { 1.5, 3, 4.5, 6, 7.5 },
	slide = {
		grass = {
			{ { 0.54, 1.15, 1.86, 2.65, 2.11 }, { 0.36, 0.76, 1.04, 1.35, 0.80 }, { 0.16, 0.49, 0.71, 0.73, 0.29 }, { 0.07, 0.26, 0.48, 0.40, 0.22 } }, -- spin 0
			{ { 0.62, 1.46, 2.26, 2.54, 2.65 }, { 0.14, 0.38, 0.85, 0.93, 0.85 }, { 0.00, 0.00, 0.00, 0.00, 0.00 }, { 0.00, 0.00, 0.00, 0.00, 0.00 } }, -- spin 22
			{ { 0.67, 1.53, 2.29, 3.04, 3.20 }, { 0.16, 0.34, 0.71, 1.08, 1.58 }, { 0.00, 0.00, 0.00, 0.00, 0.00 }, { 0.00, 0.00, 0.00, 0.00, 0.00 } }, -- spin 44
			{ { 0.64, 1.59, 2.37, 3.06, 3.48 }, { 0.11, 0.28, 0.58, 1.00, 1.28 }, { 0.00, 0.00, 0.01, 0.00, 0.04 }, { 0.01, 0.00, 0.00, 0.00, 0.01 } }, -- spin 66
		},
		sand = {
			{ { 0.33, 0.84, 1.16, 0.98, 0.49 }, { 0.19, 0.49, 0.64, 0.45, 0.21 }, { 0.07, 0.28, 0.39, 0.23, 0.12 }, { 0.03, 0.15, 0.24, 0.15, 0.10 } }, -- spin 0
			{ { 0.37, 0.95, 1.79, 2.40, 2.36 }, { 0.09, 0.31, 0.73, 0.89, 0.90 }, { 0.00, 0.00, 0.00, 0.00, 0.08 }, { 0.00, 0.00, 0.00, 0.00, 0.00 } }, -- spin 22
			{ { 0.35, 0.81, 1.43, 2.09, 2.73 }, { 0.09, 0.26, 0.49, 0.64, 1.18 }, { 0.00, 0.00, 0.00, 0.00, 0.00 }, { 0.00, 0.00, 0.00, 0.00, 0.00 } }, -- spin 44
			{ { 0.35, 0.79, 1.34, 1.95, 2.41 }, { 0.10, 0.24, 0.36, 0.63, 0.83 }, { 0.00, 0.04, 0.04, 0.00, 0.09 }, { 0.00, 0.00, 0.00, 0.00, 0.01 } }, -- spin 66
		},
		snow = {
			{ { 0.47, 1.23, 1.91, 2.23, 2.07 }, { 0.28, 0.78, 1.20, 1.46, 1.35 }, { 0.13, 0.44, 0.79, 1.05, 0.96 }, { 0.09, 0.30, 0.59, 0.73, 0.60 } }, -- spin 0
			{ { 0.47, 1.23, 2.05, 2.86, 2.96 }, { 0.11, 0.36, 0.94, 1.24, 1.34 }, { 0.00, 0.00, 0.01, 0.00, 0.43 }, { 0.00, 0.00, 0.08, 0.24, 0.16 } }, -- spin 22
			{ { 0.46, 1.12, 1.80, 2.42, 3.17 }, { 0.11, 0.20, 0.62, 0.92, 1.60 }, { 0.00, 0.00, 0.00, 0.00, 0.01 }, { 0.00, 0.00, 0.00, 0.10, 0.09 } }, -- spin 44
			{ { 0.50, 1.13, 1.83, 2.31, 2.95 }, { 0.08, 0.18, 0.43, 0.49, 0.89 }, { 0.00, 0.00, 0.00, 0.00, 0.01 }, { 0.00, 0.00, 0.01, 0.07, 0.02 } }, -- spin 66
		},
		-- the grid (0.14, measured 2026-11-22 the same way, --surface grid)
		grid = {
			{ { 0.58, 1.27, 1.92, 3.03, 2.98 }, { 0.38, 0.76, 1.20, 1.80, 1.40 }, { 0.18, 0.48, 0.81, 1.17, 0.60 }, { 0.09, 0.27, 0.58, 0.65, 0.36 } }, -- spin 0
			{ { 0.63, 1.62, 2.31, 2.81, 2.85 }, { 0.16, 0.37, 0.94, 1.04, 1.15 }, { 0.00, 0.00, 0.01, 0.00, 0.15 }, { 0.00, 0.00, 0.01, 0.02, 0.02 } }, -- spin 22
			{ { 0.71, 1.57, 2.40, 3.30, 3.45 }, { 0.18, 0.27, 0.82, 0.97, 1.77 }, { 0.00, 0.00, 0.00, 0.00, 0.01 }, { 0.00, 0.00, 0.00, 0.03, 0.01 } }, -- spin 44
			{ { 0.67, 1.69, 2.48, 3.24, 3.74 }, { 0.13, 0.25, 0.60, 0.63, 1.17 }, { 0.00, 0.01, 0.04, 0.00, 0.04 }, { 0.00, 0.00, 0.00, 0.00, 0.02 } }, -- spin 66
		},
	},
	-- How far a clean drill rests to the right of its line (m), read as `slide` is
	-- (0.11; drill.rollFor, with the spin's sign): the roll a dead landing's spin gives
	-- it. The same run measures both (tools/drillscatter.lua --only 5 --grounds 60,
	-- 2026-11-21). The lofts a clean drill is always caught at (47 and 57, with taps) are
	-- measured with a clean hand (--hand 0); the rest of `slide` with the ordinary
	-- hand's scatter (--hand 1), as it always was. No taps and the two low lofts roll 0:
	-- those kubbs are not caught every time, and
	-- the mean of where their bounces took them is not a roll to aim by.
	roll = {
		grass = {
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 } }, -- spin 0
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.06, 0.05, 0.05, 0.03, 0.15 }, { 0.05, 0.04, -0.02, -0.03, 0.06 } }, -- spin 22
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.15, 0.16, 0.19, 0.15, 0.16 }, { 0.17, 0.18, 0.14, 0.13, 0.16 } }, -- spin 44
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.33, 0.32, 0.32, 0.33, 0.33 }, { 0.28, 0.33, 0.32, 0.37, 0.24 } }, -- spin 66
		},
		sand = {
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 } }, -- spin 0
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.03, 0.04, 0.05, 0.04, 0.20 }, { 0.03, 0.05, 0.01, 0.00, 0.02 } }, -- spin 22
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.09, 0.10, 0.11, 0.08, 0.10 }, { 0.10, 0.11, 0.10, 0.10, 0.10 } }, -- spin 44
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.26, 0.30, 0.24, 0.24, 0.26 }, { 0.25, 0.25, 0.27, 0.25, 0.27 } }, -- spin 66
		},
		snow = {
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 } }, -- spin 0
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.07, 0.07, 0.08, 0.07, 0.20 }, { 0.02, 0.05, -0.01, -0.01, 0.03 } }, -- spin 22
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.23, 0.22, 0.23, 0.22, 0.23 }, { 0.22, 0.20, 0.21, 0.02, -0.02 } }, -- spin 44
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.47, 0.45, 0.45, 0.46, 0.47 }, { 0.39, 0.41, 0.18, 0.33, 0.01 } }, -- spin 66
		},
		-- the grid: its magnet stops a slow roll, so two and three taps roll less than on grass
		grid = {
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 } }, -- spin 0
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.01, 0.01, 0.04, 0.02, 0.04 }, { -0.01, 0.00, 0.00, 0.00, 0.00 } }, -- spin 22
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.10, 0.08, 0.07, 0.17, 0.08 }, { 0.12, 0.09, 0.10, -0.06, -0.06 } }, -- spin 44
			{ { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, { 0.25, 0.26, 0.26, 0.23, 0.34 }, { 0.30, 0.24, 0.31, 0.23, -0.02 } }, -- spin 66
		},
	},
	slideRefM = 6,          -- m: the landing distance slideFor reads when given none
	-- the body at release (world.drillLaunchState, 2026-11-16: the drill is a plain
	-- rigid body, like a baton). Jamie: "we didn't treat Kubb throws with the same
	-- physics as baton throws" and "Good drillers would never let a Kubb flip in the
	-- air". Held by its back end at the bottom of an underhand swing, the kubb hangs
	-- nose forward and down; the wrist's snap spirals it about its long axis, a
	-- gyroscope, so it lands about as it left the hand: nose first.
	noseSumDeg = 90,        -- the kubb hangs along the arm, and it leaves square to the arm: the
	                        -- long axis is noseSumDeg less the loft below the horizontal at
	                        -- release (drill.noseFor), whatever arc was planned. At the default
	                        -- arc (loft 47) that is 43 (Jamie's technique: it lands nose first
	                        -- at about 45); a low drill leaves nose well down, a high one nearly
	                        -- level. Until 0.10 it was 45 at the planned arc, any arc.
	                        -- A spun drill (a tap or more) holds it to the touch; with only the
	                        -- small natural spiral the air turns the kubb toward broadside to its
	                        -- fall, so it lands steeper and less the same each time.
	noseDownDeg = 43,       -- drill.body's when it is given no loft: the default arc's
	spiral = 3,             -- rad/s: the small spiral the wrist always gives a drill (+ = clockwise
	                        -- from behind; Jamie: "even if the thrower indicates no spin, there
	                        -- would always be some small, subtle amount of rotation"); B +
	                        -- left/right taps add to it (plan.tune.spinPerStep)
	pitchSdDps = 30,        -- deg/s sd of the swing's nose up or down turn at release ...
	yawSdDps = 15,          -- ... of a turn across the line (about the kubb's own up) ...
	spinSd = 3,             -- ... rad/s of the spiral ...
	noseSdDeg = 4,          -- ... degrees of the release attitude ...
	scatterJerk = 1.5,      -- ... each this much more again for a jerky swing (smoothness 0)
	-- the swing against the band
	bandNear = 0.35,        -- swing power the nearest marker needs (gauge band center)
	bandFar = 0.85,         -- ... and the farthest; leaves room above to throw long
	bandHalf = 0.06,        -- the band is this wide either side of its center
	inBandGain = 0.25,      -- inside the band a power error counts this much
	speedPerPower = 1.0,    -- outside: launch speed changes by this fraction per unit of power
	speedMinFrac = 0.4,     -- never slower than this fraction of the solved speed
	cleanAbove = 0.75,      -- smoothness at or above this is a clean flick: no wobble
	wobbleRate = 10,        -- rad/s of nose-over wobble at smoothness 0 (scales with how far
	                        -- under cleanAbove the swing was)
	tiltPushDeg = 0.05,     -- degrees of line per degree of swing tilt
	cutSpin = 25,           -- rad/s about the long axis with A or B held at release (drill.launch;
	                        -- the plan's spin is plan.tune.spinPerStep a tap)
}

drill.CUT_NONE, drill.CUT_A, drill.CUT_B = 0, 1, -1

local function lerp(a, b, f)
	return a + (b - a) * f
end

-- Keep the marker in its area: mx across, my as distance from lineY.
function drill.clampMarker(mx, my)
	local t = drill.tune
	return max(-t.markerXMax, min(t.markerXMax, mx)), max(t.markerNear, min(t.markerFar, my))
end


-- Solve the clean drill onto the marker (mx, my in the view frame, the
-- thrower's baseline at lineY) at the loft the distance picks (loftNearDeg to
-- loftFarDeg). Fills and returns `out`:
--   x          where the thrower stands on the baseline
--   swivel     radians, + = right
--   loft       degrees
--   dist       m from the thrower to the marker
--   speed      m/s of the clean launch
--   band       swing power that gives exactly that speed (band center)
--   T          s from release until the kubb's edge reaches the grass
--   land       m from the thrower to where it lands (short of the marker by
--              its mean run on, drill.slideFor)
function drill.solve(mx, my, lineY, out)
	local t = drill.tune
	local x = max(-t.throwerXMax, min(t.throwerXMax, mx))
	local dx, dy = mx - x, my - lineY
	local d = sqrt(dx * dx + dy * dy)
	local f = max(0, min(1, (d - t.markerNear) / (t.markerFar - t.markerNear)))
	return drill.solveAt(mx, my, lineY, lerp(t.loftNearDeg, t.loftFarDeg, f), out, x)
end

-- Where a table's sorted keys put x: the index below and the share of the
-- way to the next (clamped at both ends).
local function between(keys, x)
	local n = #keys
	if x <= keys[1] then return 1, 0 end
	if x >= keys[n] then return n - 1, 1 end
	for i = 2, n do
		if x <= keys[i] then return i - 1, (x - keys[i - 1]) / (keys[i] - keys[i - 1]) end
	end
	return n - 1, 1
end

-- How far a clean drill at this loft (degrees) runs on along the throw after
-- it lands R m out (nil: slideRefM), on this ground (nil: grass):
-- tune.slide, between its spins (rad/s either way, nil: none), rows and
-- columns.
local function slideIn(rows, i, fi, j, fj)
	local a, b = rows[i], rows[i + 1]
	return lerp(lerp(a[j], a[j + 1], fj), lerp(b[j], b[j + 1], fj), fi)
end
function drill.slideFor(loftDeg, surface, spin, R)
	local t = drill.tune
	local tabs = t.slide[surface or "grass"] or t.slide.grass
	local k, fk = between(t.slideSpins, abs(spin or 0))
	local i, fi = between(t.slideLofts, loftDeg)
	local j, fj = between(t.slideR, R or t.slideRefM)
	return max(0, lerp(slideIn(tabs[k], i, fi, j, fj), slideIn(tabs[k + 1], i, fi, j, fj), fk))
end

-- How far a clean drill rests to the right of its line (m, + = right of the throw):
-- tune.roll, read as slideFor reads tune.slide, with the spin's sign. A kubb that
-- lands dead (world.tune deadLanding) rolls a face or two the way it was spun.
function drill.rollFor(loftDeg, surface, spin, R)
	local t = drill.tune
	local tabs = t.roll[surface or "grass"] or t.roll.grass
	local k, fk = between(t.slideSpins, abs(spin or 0))
	local i, fi = between(t.slideLofts, loftDeg)
	local j, fj = between(t.slideR, R or t.slideRefM)
	local m = lerp(slideIn(tabs[k], i, fi, j, fj), slideIn(tabs[k + 1], i, fi, j, fj), fk)
	return (spin or 0) < 0 and -m or m
end

-- The landing distance that runs on to d (m) at this loft: the R with
-- R + slideFor(R) = d (a few steps; the run on changes slower than R).
function drill.landFor(d, loftDeg, surface, spin)
	local R = d
	for _ = 1, 6 do
		R = d - drill.slideFor(loftDeg, surface, spin, R)
		if R < 0.5 then R = 0.5 end
	end
	return R
end

-- The clean drill onto the marker at a given loft (degrees): the plan's arc
-- (core/throwplan). px is where the thrower stands on the baseline (nil:
-- straight behind the marker, inside throwerXMax); surface the ground (nil:
-- grass) and spin the planned spin (rad/s, nil: none), for how far it runs
-- on (drill.slideFor). Fills and returns `out` with the fields of
-- drill.solve. No table is made when `out` is given.
function drill.solveAt(mx, my, lineY, loftDeg, out, px, surface, spin)
	local t = drill.tune
	out = out or {}
	local x = px or max(-t.throwerXMax, min(t.throwerXMax, mx))
	local dx, dy = mx - x, my - lineY
	local d = sqrt(dx * dx + dy * dy)
	-- aimed to the side of the marker by the roll its spin gives it (drill.rollFor),
	-- so it rests on the marker
	if d > 1e-6 then
		local side = drill.rollFor(loftDeg, surface, spin, d)
		dx, dy = dx - side * dy / d, dy + side * dx / d
	end
	local f = max(0, min(1, (d - t.markerNear) / (t.markerFar - t.markerNear)))
	local ft = flight.tune
	local h0 = ft.handHeight - t.landZ
	local e = rad(loftDeg)
	local R = drill.landFor(d, loftDeg, surface, spin)
	-- the speed that lands it R out through still air, with a kubb's drag
	local k = ft.dragK.kubb
	local v = flight.speedForCarry(R, e, h0, k)
	local _, T = flight.carry(v, e, h0, k)
	out.x, out.swivel, out.loft, out.dist, out.speed = x, atan(dx, dy), loftDeg, d, v
	out.band = lerp(t.bandNear, t.bandFar, f)
	out.T, out.land = T, R
	return out
end

-- The power error as it reaches the speed: shrunk inside the band.
function drill.powerError(power, band)
	local t = drill.tune
	local err = power - band
	local a = abs(err)
	if a <= t.bandHalf then return err * t.inBandGain end
	local e = t.bandHalf * t.inBandGain + (a - t.bandHalf)
	return err < 0 and -e or e
end

-- "short", "on" or "long": where the swing's power sat against the band.
function drill.judge(power, band)
	local d = power - band
	if d < -drill.tune.bandHalf then return "short" end
	if d > drill.tune.bandHalf then return "long" end
	return "on"
end

-- The band launch for `r` = { power, smoothness, tilt, pull } against the
-- solution `sol` (drill.solve), with cut drill.CUT_NONE / CUT_A / CUT_B: the
-- solved loft, the speed from the power against the band, the line pushed by
-- the tilt the way pull says (+1 right, the default; -1 left, also the
-- wobble's sign). Fills and returns `out`: swivel, loft, speed, noseDown,
-- rollLand, spin, wobble (the arguments of world.launchDrill after
-- x and lineY), plus jerk (0..1). Not the plan's launch (tw.plan.launch):
-- the release angle is not read.
function drill.launch(sol, r, cut, out)
	local t = drill.tune
	out = out or {}
	local e = drill.powerError(r.power or 0, sol.band)
	out.speed = sol.speed * max(t.speedMinFrac, 1 + t.speedPerPower * e)
	local pull = (r.pull or 1) < 0 and -1 or 1
	out.swivel = sol.swivel + pull * rad(t.tiltPushDeg * (r.tilt or 0))
	out.loft = sol.loft
	-- A (+1) spins it positive about the forward long axis (clockwise from
	-- behind), B the other way, on top of the wrist's spiral
	return drill.body(r.smoothness or 1, pull, (cut or 0) * t.cutSpin, out, out.loft)
end

-- The long axis below the horizontal (degrees) as a drill leaves the hand at this
-- loft (tune.noseSumDeg).
function drill.noseFor(loftDeg)
	return drill.tune.noseSumDeg - loftDeg
end

-- The drilled kubb's body at release (world.launchDrill's arguments after
-- the line of flight): fills `out` with noseDown, rollLand, spin (rad/s about
-- the long axis: as given plus the wrist's spiral), wobble and jerk (0..1). smoothness is the
-- swing's (or the plan's effective smoothness: core/throwplan); under
-- cleanAbove the kubb wobbles nose over tail, up to wobbleRate at 0 and
-- never more. pull (+1 or -1) is the wobble's sign. loftDeg is the loft it
-- leaves at (drill.noseFor; nil: tune.noseDownDeg, the default arc's).
function drill.body(smoothness, pull, spin, out, loftDeg)
	local t = drill.tune
	local jerk = (t.cleanAbove - smoothness) / t.cleanAbove
	if jerk < 0 then jerk = 0 elseif jerk > 1 then jerk = 1 end
	spin = spin or 0
	-- the wrist's spiral goes the way of the taps (0.11: against them, a kubb spun the
	-- other way flew unsteady)
	spin = spin + (spin < 0 and -t.spiral or t.spiral)
	out.noseDown, out.rollLand, out.spin = loftDeg and drill.noseFor(loftDeg) or t.noseDownDeg, 0, spin
	out.jerk = jerk
	out.wobble = pull * t.wobbleRate * jerk
	return out
end

-- The planned spin (rad/s) in a drilled kubb's launch spin: the spin less the
-- wrist's spiral, which goes the spin's way (drill.body).
function drill.plannedSpin(spin)
	local sp = drill.tune.spiral
	return spin - (spin < 0 and -sp or sp)
end


tw.drill = drill
