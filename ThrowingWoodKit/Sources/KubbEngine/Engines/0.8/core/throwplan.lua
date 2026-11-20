-- The throw plan (DESIGN.md section 4, "The throw: the crank as a clock").
-- Pure Lua: no playdate.*.
--
-- The player picks a target (a point in the far half), a stance (where they
-- stand on or behind the throwing line) and a plan (the arc as a release
-- angle on the clock, a tilt for a baton, spin for a kubb). tw.plan turns
-- those into the gauge's two targets, the power target (the backswing this
-- throw needs) and the release target (where to stop the crank), and turns a
-- measured swing (core/swing's result) into a launch for core/world.
--
-- The clock, in degrees from 6 o'clock: the backswing goes up the left side
-- (30 = 7 o'clock, 90 = 9, 120 = 10, 180 = 12), the forward swing up the
-- right (30 = 5 o'clock, 90 = 3, 150 = 1, 180 = 12).
--
-- Two scales:
--   power  the backswing sets a launch speed (plan.speedFor). Its scale is
--          the reach (plan.reach): how far a clean baton at the reference
--          arc (3 o'clock, refLoftDeg) carries on flat ground from the hand.
--          0 m at 7 o'clock, 4 m at 9, 8 m at 10, and on up a quadratic:
--          corner to corner (9.4 m) at about 10:17, 13.3 m at 11, 20 m at 12.
--   loft   the release angle sets the launch angle (plan.loftFor), a line
--          through 5 o'clock = 12 degrees and 3 o'clock = 32 (half past 1 =
--          47, 12 o'clock = 62).
--
-- One frame throughout: the thrower's view frame (core/frame), throwing
-- from lineY toward +y, x to the right. Swivel is radians from straight
-- downfield, + = toward +x (right), as core/flight and core/world use it.
--
-- The functions the throw scene calls every aim frame (stance, snap, solve,
-- the scales) make no tables or closures: they fill an `out` table.
import "core/tw"
import "core/flight"
import "core/drill"
import "core/body"

local sqrt, sin, cos, tan, atan, rad, deg = math.sqrt, math.sin, math.cos, math.tan, math.atan, math.rad, math.deg
local floor, log, pi = math.floor, math.log, math.pi

local plan = {}
local flight, drill, body = tw.flight, tw.drill, tw.body

plan.tune = {
	-- the power scale (plan.reach): reach = a u + c u^2 with u = back - reachZeroDeg,
	-- a and c fitted through the two anchors below. A quadratic through
	-- (30, 0), (90, 4), (120, 8) has a = 1/45 and c = 1/1350, both positive, so
	-- it rises from zero, is smooth and monotonic, and gets steeper past 10
	-- o'clock: 9.4 m (corner to corner) at 128.6 degrees (about 10:17), 13.3 m
	-- at 11 o'clock, 20 m at 12 (overpowered: more than any throw needs).
	reachZeroDeg = 30,     -- backswing degrees where the reach is 0 (7 o'clock; the dead zone ends)
	reachAnchor1Deg = 90,  -- 9 o'clock ...
	reachAnchor1 = 4.0,    -- ... carries about 4 m
	reachAnchor2Deg = 120, -- 10 o'clock ...
	reachAnchor2 = 8.0,    -- ... carries 8 m: a baseline baton
	refLoftDeg = 32,       -- the reference arc the reach is measured at: 3 o'clock (loftFor(90))
	-- the loft scale (plan.loftFor): a line through two points
	loftRel1 = 30,  loftAt1 = 12,  -- 5 o'clock: low and flat
	loftRel2 = 90,  loftAt2 = 32,  -- 3 o'clock: the normal throw
	loftMinDeg = 2,        -- the launch angle never goes under this ...
	loftMaxDeg = 75,       -- ... or over this (a sky ball reaches it)
	-- the plan (B + d-pad)
	arc = { base = 90, king = 75, field = 60, drill = 135 }, -- default release by target: 3
	                       -- o'clock at base kubbs, half past 3 at the king, 4 at field
	                       -- kubbs, half past 1 for a drilled kubb
	arcStepDeg = 15,       -- B + up/down moves the release target half an hour
	releaseMinDeg = 15,    -- the planned release stays between half past 5 ...
	releaseMaxDeg = 165,   -- ... and half past 12
	tiltStepDeg = 5,       -- B + left/right on a baton: one tap tilts the spin plane this much. Measured
	                       -- (tools/tiltgroups.lua, 2026-11-15): tilt deflects the baton after its first
	                       -- hit by only about 0.15 degrees per degree, so finer steps make no visible
	                       -- difference
	tiltMaxDeg = 20,       -- ... up to this either way (Jamie, 2026-11-15: tap up to 20 in steps of 5).
	                       -- With the shake it adds up toward legalTiltDeg, the helicopter
	spinSteps = 3,         -- B + left/right on a kubb: up to this many taps either way
	spinPerStep = 22,      -- rad/s about the long axis per tap (+ clockwise from behind), on top of the
	                       -- wrist's spiral (drill.tune.spiral). A spun drill holds its release attitude to
	                       -- the touch, a gyroscope; once down, spin moves it a little either way: which
	                       -- corner strikes first decides more than the spin (2026-11-16, the plain body
	                       -- with the turf's bite; tools/spinwall.lua)
	defaultLevel = "club", -- the level when none is given
	-- the swing against the plan (plan.launch)
	skyExtraDeg = 45,      -- a sky ball (the crank on past 12): its release counts as this
	                       -- many degrees past where it stopped (at least 12 o'clock), so it
	                       -- leaves near loftMaxDeg, high and short: the large error
	legalTiltDeg = 30,     -- a tilt over this is a helicopter (II.B.1); the old swing's
	                       -- 90 * (1 - smoothness) was legal at 30 or under
	shakeTiltDeg = 90,     -- tilt of a throw with shake 1 at full cost (the old mapping)
	lateralDeg = 3,        -- swivel pull of a throw with shake 1 at full cost (first guess:
	                       -- a baton at 8 m only hits within about 0.4 degrees)
	overPerDeg = 30,       -- the overpower multiplier grows by overGain per this many
	                       -- degrees of backswing past the power target
	steadyBelow = 0.25,    -- shake under this is STEADY
	-- Where a baton is aimed (Tyler's report, 2026-11-16: "all of them went clean
	-- over the field kubb"). A thrower aims at the kubb, not at the turf under it:
	-- the clean throw sends the baton's centre through the target piece at this
	-- share of the piece's height (a kubb 0.15 m tall: 7.5 cm up; the king 0.30
	-- m: 15 cm), so it meets the piece's face instead of coming down at its foot.
	-- A target not on a piece (an empty spot) is aimed at the ground, as before.
	-- Drilled kubbs are not aimed this way (drill.solveAt has its own landing).
	aimHeightShare = 0.5,
	-- The wrist checks the arm's rotation to aim for the level's tumbleTurns.
	-- On longer throws the arm speed limits how much of that rotation can be
	-- checked. A rough release adds seeded variation in turns (tumbleSd).
	armR = 0.9,            -- m, shoulder to the centre of the baton
	wristShare = 0.75,     -- maximum share the wrist can check or add
	tumbleMin = 0,         -- rad/s: the drawn rate never goes under this (no backspin)
	-- Nerves (2026-11-16): before this nothing but the shake put a throw
	-- left or right, so a long throw was as true as a short one. Every
	-- throw, the player's and the computer's, gets two seeded draws in plan.launch (opts.nerves): an angle off the planned
	-- line (degrees, so the miss in metres grows with the range) and a share
	-- of the throw's length. Their sd is the level's nervesDeg and nervesLen
	-- (plan.levels) times three things:
	--   effort     1 + effortGain x (reach / effortRefM - 1), never under
	--              effortMin: the power of the throw (the backswing as it
	--              counts) against a baseline baton
	--   roughness  1 + roughGain x the swing's shake (core/swing): the
	--              swing's own roughness
	--   overpower  the same multiplier as the shake's costs (overGain)
	-- and for a drilled kubb drillNerves of that.
	effortRefM = 8,        -- m: the reach of a baseline baton: effort 1
	effortGain = 2.5,      -- how much a longer reach adds (6 m: 0.375, 10 m: 1.625)
	effortMin = 0.15,      -- effort never goes under this (a 5.2 m reach and under)
	roughGain = 1,         -- shake 1 doubles the spread
	drillNerves = 1,       -- a drilled kubb's nerves against a baton's
	lenMin = -0.5,         -- the length share never takes more than half the throw
	fanSd = 1,             -- the aim fan (plan.spread) is this many sd either side
	-- the verdict's sideways cell (plan.launch's sideV): within straightM of
	-- the planned line at the target is STRAIGHT, else PULLED LEFT or RIGHT;
	-- the length (lenV) within longM of it is ON
	straightM = 0.06,      -- m: about a baton's hit either side of a kubb's centre
	longM = 0.3,           -- m
}

-- Throw levels (DESIGN 4 "Throw levels"): how wide the gauge's targets are and
-- how much a miss costs. First guesses, to be fitted from play.
--   powerHalf    degrees either side of the power target's center
--   releaseHalf  degrees either side of the release target's center
--   inGain       share of an error inside a target that still counts
--   shakeGain    share of the shake's tilt and pull that counts
--   overGain     how fast overpowering multiplies the shake's costs
--   nervesDeg    sd of the angle off the planned line (degrees) at effort 1,
--                a clean swing and no overpower (plan.tune "Nerves")
--   nervesLen    sd of the length error, a share of the throw, the same way
--   tumbleSd     sd of the tumble, in turns over the planned flight, times the
--                swing's roughness and the overpower (plan.tune "the baton's tumble")
plan.levels = {
	beginner = { powerHalf = 15, releaseHalf = 30, inGain = 0.1, shakeGain = 0.5,  overGain = 0.5,
		nervesDeg = 1.6, nervesLen = 0.06, tumbleTurns = 0.62, tumbleSd = 0.10 },
	club     = { powerHalf = 8,  releaseHalf = 18, inGain = 0.3, shakeGain = 0.75, overGain = 0.75,
		nervesDeg = 0.8, nervesLen = 0.03, tumbleTurns = 0.50, tumbleSd = 0.06 },
	pro      = { powerHalf = 4,  releaseHalf = 10, inGain = 0.6, shakeGain = 1,    overGain = 1,
		nervesDeg = 0.5, nervesLen = 0.02, tumbleTurns = 0.50, tumbleSd = 0.035 },
}
plan.LEVELS = { "beginner", "club", "pro" }

-- The level table for a name or a level table (nil: tune.defaultLevel).
function plan.level(l)
	if type(l) == "table" then return l end
	return plan.levels[l or plan.tune.defaultLevel] or plan.levels[plan.tune.defaultLevel]
end
local levelOf = plan.level

-- ---------------------------------------------------------------------------
-- The scales

-- The quadratic's coefficients from the anchors (worked out per call from the
-- tune, so a change to it takes at once; a few multiplications).
local function reachCoeffs()
	local t = plan.tune
	local u1, u2 = t.reachAnchor1Deg - t.reachZeroDeg, t.reachAnchor2Deg - t.reachZeroDeg
	local c = (t.reachAnchor2 / u2 - t.reachAnchor1 / u1) / (u2 - u1)
	return t.reachAnchor1 / u1 - c * u1, c
end

-- Meters a clean baton thrown with this backswing (degrees) carries at the
-- reference arc on flat ground from the hand height: the power scale.
function plan.reach(backDeg)
	local u = backDeg - plan.tune.reachZeroDeg
	if u <= 0 then return 0 end
	local a, c = reachCoeffs()
	return a * u + c * u * u
end

-- The backswing (degrees) whose reach is reachM: plan.reach's inverse.
function plan.backFor(reachM)
	local z = plan.tune.reachZeroDeg
	if reachM <= 0 then return z end
	local a, c = reachCoeffs()
	if c < 1e-12 then return z + reachM / a end
	return z + (-a + sqrt(a * a + 4 * c * reachM)) / (2 * c)
end

-- The speed that carries a baton R (m) from hand height h to the ground at
-- loft e (radians) through still air, with its drag: flight.predict's arc
-- (flight.speedForCarry), and that flight's time (s).
local function carrySpeed(R, e, h)
	return flight.speedForCarry(R, e, h, flight.tune.dragK.baton)
end
-- (h is the hand's height over the point the carry ends at: the ground, or
-- in plan.solve the aim height, plan.aimZFor)

-- The launch speed (m/s) a backswing gives with a full flick: the speed whose
-- clean flight at refLoftDeg carries plan.reach(backDeg).
function plan.speedFor(backDeg)
	local R = plan.reach(backDeg)
	if R <= 0 then return 0 end
	local ft = flight.tune
	local v = carrySpeed(R, rad(plan.tune.refLoftDeg), ft.handHeight)
	return v
end

-- How far a launch speed carries at the reference arc (m): the reach it is.
function plan.reachForSpeed(speed)
	local _, ly = flight.predict(0, 0, 0, plan.tune.refLoftDeg, speed)
	return ly
end

-- The backswing (degrees) that gives this launch speed with a full flick.
function plan.backForSpeed(speed)
	if speed <= 0 then return plan.tune.reachZeroDeg end
	return plan.backFor(plan.reachForSpeed(speed))
end

-- The launch angle (degrees) for a release angle (degrees past 6 o'clock on
-- the forward side), clamped to loftMinDeg..loftMaxDeg.
function plan.loftFor(releaseDeg)
	local t = plan.tune
	local l = t.loftAt1 + (releaseDeg - t.loftRel1) * (t.loftAt2 - t.loftAt1) / (t.loftRel2 - t.loftRel1)
	if l < t.loftMinDeg then return t.loftMinDeg end
	if l > t.loftMaxDeg then return t.loftMaxDeg end
	return l
end

-- The release angle (degrees) for a launch angle: plan.loftFor's inverse.
function plan.releaseFor(loftDeg)
	local t = plan.tune
	if loftDeg < t.loftMinDeg then loftDeg = t.loftMinDeg elseif loftDeg > t.loftMaxDeg then loftDeg = t.loftMaxDeg end
	return t.loftRel1 + (loftDeg - t.loftAt1) * (t.loftRel2 - t.loftRel1) / (t.loftAt2 - t.loftAt1)
end

-- The baton's planned tumble rate (rad/s) for a clean launch at speed (m/s)
-- and loftDeg (plan.tune, "the baton's tumble"): tumbleTurns over the flight,
-- inside the wrist's range about the arm's rate. The rate only; the clean
-- flight's time is plan.flightTime, or T when the caller has it already
-- (plan.solve: the speed's own solve gives it).
function plan.flightTime(speed, loftDeg, z)
	local _, _, T = flight.predict(0, 0, 0, loftDeg or plan.tune.refLoftDeg, speed, z)
	return T
end
function plan.tumbleFor(speed, loftDeg, T, level)
	local t = plan.tune
	T = T or plan.flightTime(speed, loftDeg)
	local arm = speed / t.armR
	local lo, hi = arm * (1 - t.wristShare), arm * (1 + t.wristShare)
	local r = T > 0 and 2 * pi * (plan.level(level).tumbleTurns or plan.levels.club.tumbleTurns) / T or 0
	if r < lo then r = lo elseif r > hi then r = hi end
	return r
end

-- Clamp a planned release to releaseMinDeg..releaseMaxDeg.
function plan.clampRelease(releaseDeg)
	local t = plan.tune
	if releaseDeg < t.releaseMinDeg then return t.releaseMinDeg end
	if releaseDeg > t.releaseMaxDeg then return t.releaseMaxDeg end
	return releaseDeg
end

-- The default release for a target kind: "base", "king", "field" or "drill".
function plan.arcFor(kind)
	return plan.tune.arc[kind] or plan.tune.arc.base
end

-- The height (m) a baton's centre is aimed through a piece of this kind:
-- "king" the king, anything else a kubb ("base", "field", "kubb"); nil (no
-- piece: an empty spot) the ground, 0. aimHeightShare of the piece's height.
function plan.aimZFor(kind)
	if not kind then return 0 end
	local k = kind == "king" and body.kinds.king or body.kinds.kubb
	-- At a half turn the lower end leads into the target. Give that end
	-- clearance over the grass as the centre crosses the near face.
	return plan.tune.aimHeightShare * 2 * k.hz + body.kinds.baton.hl
end

-- ---------------------------------------------------------------------------
-- Stance, snap and solve (every aim frame)

-- The default stance: straight behind the target (x clamped inside
-- +/- halfWidth, the line's ends), as far forward as allowed (forwardY, the
-- advantage line or the baseline; nil = lineY). Fills out.x, out.y.
function plan.stance(tx, ty, lineY, forwardY, halfWidth, out)
	local x = tx
	if x < -halfWidth then x = -halfWidth elseif x > halfWidth then x = halfWidth end
	out.x, out.y = x, forwardY or lineY
	return out
end

-- The nearest of targets[1..n] (each {x, y}: standing kubbs and the king)
-- within radius of (tx, ty), and its index; nil when none is that close.
function plan.snap(tx, ty, targets, n, radius)
	local best, bi, bd = nil, nil, radius * radius
	for i = 1, n do
		local p = targets[i]
		local dx, dy = p.x - tx, p.y - ty
		local d = dx * dx + dy * dy
		if d <= bd then best, bi, bd = p, i, d end
	end
	return best, bi
end

-- Solve the plan. q = { projectile = "baton" | "kubb", px, py (the stance),
-- tx, ty (the target), release (planned degrees, clamped to the plan's
-- range), level (name or table), surface and spin (a kubb's ground and
-- planned spin in taps: how far it runs on, drill.slideFor; nil: grass, none),
-- aimZ (a baton: the height its centre is aimed through at the target,
-- plan.aimZFor; nil: 0, the ground) }. Fills and returns `out`:
--   swivel     radians, + = right
--   dist       m from the stance to the target
--   loft       degrees, loftFor(release)
--   speed      m/s of the clean launch: a baton's center passes through the
--              target at aimZ (flight.carry to that height); a kubb's drill
--              rests on it (drill.solveAt at that loft)
--   aimZ       the height the baton's centre is aimed at (0 for a kubb)
--   back       the backswing that gives that speed with a full flick
--   powerLo, powerHi      the power target: back -/+ level.powerHalf
--   release, releaseLo, releaseHi   the release target: release -/+ level.releaseHalf
--   projectile, px, py, tx, ty, level (the level table)
--   tumble, flightT   a baton's planned tumble (rad/s) and clean flight time to the
--              target at aimZ (plan.tumbleFor)
--   handZ, handFwd    a baton's hand: height and how far ahead of the stance it lets
--              go (flight.handAt of dist; handHeight and 0 from flight.tune.nearM out)
-- For a kubb also drill.solveAt's x, band and T.
function plan.solve(q, out)
	local lv = levelOf(q.level)
	local rel = plan.clampRelease(q.release or plan.tune.arc.base)
	local loft = plan.loftFor(rel)
	local px, py, tx, ty = q.px, q.py, q.tx, q.ty
	if q.projectile == "kubb" then
		drill.solveAt(tx, ty, py, loft, out, px, q.surface, (q.spin or 0) * plan.tune.spinPerStep)
		out.tumble, out.flightT, out.aimZ, out.handZ, out.handFwd, out.loftShare, out.handTip = nil, nil, 0, nil, nil, nil, nil
		out.nearShare = nil
	else
		local dx, dy = tx - px, ty - py
		local d = sqrt(dx * dx + dy * dy)
		local ft = flight.tune
		local z = q.aimZ or 0
		-- a short throw (flight.tune "The hand at a short throw"): the hand lower
		-- and ahead of the feet, the loft flatter, and the centre aimed through a
		-- piece's face rather than over its top
		local h, fwd, flat, near, tip = flight.handAt(d)
		out.handZ, out.handFwd, out.loftShare, out.handTip, out.nearShare = h, fwd, flat, tip, near
		if near > 0 and z > 0 then z = z + (ft.nearAimZ - z) * near end
		if flat ~= 1 then loft = loft * flat end
		local R = d - fwd
		if R < 0.1 then R = 0.1 end
		local speed, T = carrySpeed(R, rad(loft), h - z)
		if near > 0 and z > 0 and speed < ft.nearSpeed and h - z > 0.005 then
			-- the hand is as low as it goes (flight.handAt) and the bowl would still
			-- be soft: aim higher through the face until it is firm again (the
			-- carry shortens as the drop does), never within 5 mm of the hand
			-- (the speed and time at b are kept: the answer is b, and solving it
			-- again would give the same bits. Once a and b are neighbouring floats
			-- the midpoint is one of them and nothing more can move: a 32-bit float
			-- gets there, a double does not.)
			local a, b = z, h - 0.005
			local sb, Tb = carrySpeed(R, rad(loft), h - b)
			if sb <= ft.nearSpeed then
				z = b
			else
				for _ = 1, 20 do
					local m = 0.5 * (a + b)
					if m == a or m == b then break end
					local sm, Tm = carrySpeed(R, rad(loft), h - m)
					if sm < ft.nearSpeed then a = m else b, sb, Tb = m, sm, Tm end
				end
				z = b
			end
			speed, T = sb, Tb
		end
		out.swivel, out.dist, out.loft, out.aimZ = atan(dx, dy), d, loft, z
		out.speed = speed
		out.tumble, out.flightT = plan.tumbleFor(speed, loft, T, lv), T
		if near > 0 and T > 0 then
			-- the turn it arrives with (flight.nearTurn): a share of the way from
			-- the level's own rate to the one that makes it; flat into the face is
			-- kept inside the wrist's range (plan.tumbleFor's)
			local turnDeg, share = flight.nearTurn(d)
			local r = out.tumble + ((rad(turnDeg) - tip) / T - out.tumble) * share
			if d < ft.nearTurnM then
				local arm = speed / plan.tune.armR
				local lo, hi = arm * (1 - plan.tune.wristShare), arm * (1 + plan.tune.wristShare)
				if r < lo then r = lo elseif r > hi then r = hi end
			end
			out.tumble = r > plan.tune.tumbleMin and r or plan.tune.tumbleMin
		end
	end
	local back = plan.backForSpeed(out.speed)
	out.back, out.powerLo, out.powerHi = back, back - lv.powerHalf, back + lv.powerHalf
	out.release, out.releaseLo, out.releaseHi = rel, rel - lv.releaseHalf, rel + lv.releaseHalf
	out.projectile, out.px, out.py, out.tx, out.ty, out.level = q.projectile or "baton", px, py, tx, ty, lv
	return out
end

-- ---------------------------------------------------------------------------
-- Nerves (plan.tune "Nerves")

-- A seeded stream (Park-Miller with a scrambled seed): r.next() in [0, 1),
-- r.uniform(a, b), r.normal(sd). core/autothrow's rng is this one.
function plan.rng(seed)
	local h = floor(seed) & 0xffffffff
	h = ((h ~ (h >> 16)) * 0x45d9f3b) & 0xffffffff
	h = ((h ~ (h >> 16)) * 0x45d9f3b) & 0xffffffff
	h = h ~ (h >> 16)
	local s = h % 2147483647
	if s <= 0 then s = s + 2147483646 end
	local r = {}
	function r.next()
		s = (s * 48271) % 2147483647
		return (s - 1) / 2147483646
	end
	for _ = 1, 8 do r.next() end
	function r.uniform(a, b) return a + (b - a) * r.next() end
	function r.normal(sd)
		local u1 = r.next()
		if u1 < 1e-12 then u1 = 1e-12 end
		return sd * sqrt(-2 * log(u1)) * cos(2 * pi * r.next())
	end
	return r
end

-- The seed of a player's throw: from the swing as measured and the plan, the
-- way world.seedFrom seeds the ground from the launch, so the same swing at
-- the same plan draws the same nerves (replays, tests) and every other throw
-- its own.
local function mix(h, v)
	return (h ~ floor((v or 0) * 4096)) * 0x9E3779B1 & 0x7fffffff
end
local function swingSeed(sol, r)
	local h = mix(0x2545F491, r.back)
	h = mix(h, r.releaseAngle)
	h = mix(h, r.flickDps or r.flickFrac)
	h = mix(h, r.shake)
	h = mix(h, sol.tx)
	h = mix(h, sol.ty)
	h = mix(h, sol.px)
	return mix(h, sol.py)
end
plan.swingSeed = swingSeed

-- The effort of a throw with backswing back: its reach (plan.reach) against
-- effortRefM.
local function effortFor(back)
	local t = plan.tune
	local e = 1 + t.effortGain * (plan.reach(back) / t.effortRefM - 1)
	if e < t.effortMin then return t.effortMin end
	return e
end

-- The nerves' two sds for a throw at level lv (name or table) with backswing
-- back (degrees, as it counts), shake (0..1), overpower multiplier over (1:
-- none) and kubb (a drilled kubb): the angle off the line (degrees) and the
-- length share. No tables.
function plan.nervesSd(lv, back, shake, over, kubb)
	local t = plan.tune
	lv = levelOf(lv)
	local k = effortFor(back) * (1 + t.roughGain * (shake or 0)) * (over or 1)
	if kubb then k = k * t.drillNerves end
	return (lv.nervesDeg or 0) * k, (lv.nervesLen or 0) * k
end

-- The aim fan for solution sol (plan.solve) at its own power with a clean
-- swing: how far either side of the planned line (m) the throw spreads at
-- range m from the thrower (fanSd sds), and the sd of the angle (degrees).
-- (An aim fan drawn from it was tried in the throw scene on 2026-11-16 and
-- dropped: at club level 1 sd at 8 m is about 0.1 m, inside the target
-- circle, so the fan read as a narrow lane, not a spread.)
function plan.spread(sol, range, level)
	local sd = plan.nervesSd(level or sol.level, sol.back, 0, 1, sol.projectile == "kubb")
	return tan(rad(sd * plan.tune.fanSd)) * range, sd
end

-- The aim fan's two edges: from the thrower at px, py to the target tx, ty
-- (any frame with y down the pitch), the points plan.spread's half width
-- either side of the target, across the line. Fills and returns out (lx,
-- ly and rx, ry the two edges, half the half width in m).
function plan.fan(sol, px, py, tx, ty, level, out)
	out = out or {}
	local dx, dy = tx - px, ty - py
	local range = sqrt(dx * dx + dy * dy)
	local half = plan.spread(sol, range, level)
	local nx, ny = 0, 0
	if range > 0 then nx, ny = -dy / range, dx / range end
	out.half = half
	out.lx, out.ly = tx - nx * half, ty - ny * half
	out.rx, out.ry = tx + nx * half, ty + ny * half
	return out
end

-- ---------------------------------------------------------------------------
-- The launch (once per throw)

-- An error e against a target half width h: inside the target it counts
-- inGain of itself; outside, the part beyond the edge counts in full. The two
-- meet at the edge (continuous).
function plan.shrink(e, h, inGain)
	if e >= -h and e <= h then return e * inGain end
	if e > 0 then return h * inGain + (e - h) end
	return -h * inGain + (e + h)
end
local shrink = plan.shrink

local NO_OPTS = {}

-- Which side of the range [lo, hi] v is on: -1, 0, 1.
local function side(v, lo, hi)
	if v < lo then return -1 end
	if v > hi then return 1 end
	return 0
end

-- The launch for swing result `r` against the solution `sol`. r: back,
-- releaseAngle, flickFrac, smoothness, shake, pull (+1 / -1), how ("stopped"
-- or "sky"). opts = { projectile, tilt (planned degrees, a baton), spin
-- (planned taps, a kubb: + rolls right), level, nerves } (projectile and
-- level default to the solution's; nerves: nil or false none, true draws
-- them from a stream seeded by the swing and the plan (plan.swingSeed: a
-- player's throw), or a stream (plan.rng: the computer's own) to draw them
-- from; two normals either way). Fills and returns `out`:
--   speed, loft, swivel, tilt, tumble   the launch (world.launchBaton's arguments)
--   legal      false for a helicopter: |tilt| over legalTiltDeg (a baton; a kubb is always legal)
--   powerV     -1 short, 0 on, 1 long: the power the throw got (backswing times flick)
--              against the power target; -2 slow: the backswing was enough, the flick was not
--   releaseV   -1 low, 0 on, 1 high: where the crank stopped against the release target
--   steady     shake under steadyBelow
--   over       how much overpowering multiplied the shake's costs (0 = none)
--   back, release   the effective backswing and release after the target's forgiveness
--   sideDeg    degrees off the planned line, + = right: the shake's pull and the nerves
--   lenShare   the nerves' length error, a share of the throw (the speed is scaled by
--              sqrt(1 + lenShare), so the carry by about 1 + lenShare)
--   sideM, lenM   the same in metres at the plan's distance (sol.dist)
--   sdSide, sdLen  the nerves' sds this throw had (plan.nervesSd)
--   sideV      -1 pulled left, 0 straight, 1 pulled right (sideM against straightM)
--   lenV       -1 short, 0 on, 1 long by the nerves alone (lenM against longM)
--   tumble     a baton's turn rate (rad/s): the plan's, times the flick, plus a third
--              nerves draw of sdTurns turns over the planned flight (plan.tune "the baton's tumble")
-- For a kubb also noseDown, rollLand, spin (rad/s), wobble, jerk
-- (drill.body: world.launchDrill's arguments after the loft and speed);
-- tumble is 0 and tilt is only the shake's.
function plan.launch(sol, r, opts, out)
	local t = plan.tune
	opts = opts or NO_OPTS
	local lv = levelOf(opts.level or sol.level)
	local kubb = (opts.projectile or sol.projectile) == "kubb"
	local shake = r.shake or (1 - (r.smoothness or 1))
	local pull = (r.pull or 1) < 0 and -1 or 1
	local flick = r.flickFrac or 1
	local back = r.back or 0
	-- power: the backswing, forgiven inside the target, sets the speed; the
	-- flick delivers its share of it
	local effBack = sol.back + shrink(back - sol.back, lv.powerHalf, lv.inGain)
	out.speed = plan.speedFor(effBack) * flick
	-- release: where the crank stopped, forgiven inside the target, sets the
	-- loft; a sky ball counts skyExtraDeg past 12 o'clock or where it stopped
	local rel = r.releaseAngle or sol.release
	if r.how == "sky" then
		if rel < 180 then rel = 180 end
		rel = rel + t.skyExtraDeg
	end
	if rel < 0 then rel = 0 end
	local effRel = sol.release + shrink(rel - sol.release, lv.releaseHalf, lv.inGain)
	out.loft = plan.loftFor(effRel)
	-- a short baton's flatter release (flight.handAt, plan.solve's loftShare)
	if not kubb and sol.loftShare and sol.loftShare ~= 1 then out.loft = out.loft * sol.loftShare end
	-- overpower: every 30 degrees past the power target multiplies the shake's costs
	local past = back - sol.powerHi
	local m = 1 + lv.overGain * (past > 0 and past or 0) / t.overPerDeg
	local se = shake * lv.shakeGain * m -- the shake as it counts
	-- overpowering a short bowl heaves it up (flight.tune.nearOverLoft): the
	-- red zone's cost where the shake and the nerves are too small to miss by
	if not kubb and past > 0 and sol.nearShare and sol.nearShare > 0 then
		out.loft = out.loft + flight.tune.nearOverLoft * past * sol.nearShare
	end
	local shakeTilt = t.shakeTiltDeg * se
	-- sideways and along: the shake's pull (the swing's roughness, one way)
	-- and the nerves (two seeded draws, either way: opts.nerves)
	local zs, zl, zt = 0, 0, 0
	local nv = opts.nerves
	if nv then
		local rng = type(nv) == "table" and nv or plan.rng(swingSeed(sol, r))
		zs, zl = rng.normal(1), rng.normal(1)
		if not kubb then zt = rng.normal(1) end
	end
	local sdSide, sdLen = plan.nervesSd(lv, effBack, shake, m, kubb)
	local sideDeg = pull * t.lateralDeg * se + zs * sdSide
	local len = zl * sdLen
	if len < t.lenMin then len = t.lenMin end
	out.speed = out.speed * sqrt(1 + len)
	out.swivel = sol.swivel + rad(sideDeg)
	local dist = sol.dist or 0
	local sideM, lenM = tan(rad(sideDeg)) * dist, len * dist
	out.sideDeg, out.lenShare, out.sideM, out.lenM = sideDeg, len, sideM, lenM
	out.sdSide, out.sdLen = sdSide, sdLen
	out.sideV = side(sideM, -t.straightM, t.straightM)
	out.lenV = side(lenM, -t.longM, t.longM)
	-- the power verdict goes by what the throw got: the backswing times the
	-- flick (Jamie's first play-test throw, 2026-11-15: back on the target, a
	-- 534 deg/s flick, 2.6 m of an 8 m throw, and the verdict said ON). Short
	-- of the target with the backswing on it or past it is a slow flick: -2.
	local got = plan.backForSpeed(plan.speedFor(back) * flick)
	local pv = side(got, sol.powerLo, sol.powerHi)
	if pv < 0 and back >= sol.powerLo then pv = -2 end
	out.powerV = pv
	out.releaseV = r.how == "sky" and 1 or side(r.releaseAngle or sol.release, sol.releaseLo, sol.releaseHi)
	out.steady = shake < t.steadyBelow
	out.over = m - 1
	out.back, out.release = effBack, effRel
	if kubb then
		out.tilt = pull * shakeTilt
		out.legal = true
		out.tumble = 0
		drill.body(1 - se, pull, (opts.spin or 0) * t.spinPerStep, out, out.loft - (sol.loft or out.loft))
	else
		local tilt = (opts.tilt or 0) + pull * shakeTilt
		out.tilt = tilt
		out.legal = (tilt < 0 and -tilt or tilt) <= t.legalTiltDeg
		-- the release's tumble: the plan's rate (a solve without one: worked
		-- out here), the flick's share of it, and the nerves' turns
		local rate, T = sol.tumble, sol.flightT
		if not rate then
			local v, l = sol.speed or out.speed, sol.loft or out.loft
			T = plan.flightTime(v, l, sol.aimZ)
			rate = plan.tumbleFor(v, l, T, lv)
		end
		local rangeFactor = math.min(1.5, math.max(0.5, (sol.dist or 8) / 8))
		local sdT = (lv.tumbleSd or 0) * rangeFactor * (1 + t.roughGain * shake) * m
		rate = rate * flick + (T and T > 0 and zt * sdT * 2 * pi / T or 0)
		if rate < t.tumbleMin then rate = t.tumbleMin end
		out.tumble, out.sdTurns = rate, sdT
	end
	return out
end

local POWER = { [-2] = "SLOW", [-1] = "SHORT", [0] = "ON", [1] = "LONG" }
local RELEASE = { [-1] = "LOW", [0] = "ON", [1] = "HIGH" }

local SIDE = { [-1] = "PULLED LEFT", [0] = "STRAIGHT", [1] = "PULLED RIGHT" }

-- The HUD's verdicts after a throw, a word each: power (SLOW, SHORT, ON, LONG),
-- release (LOW, ON, HIGH), steadiness (STEADY, SHAKY) and which way it went
-- (plan.sideText).
function plan.verdictText(out)
	return POWER[out.powerV or 0], RELEASE[out.releaseV or 0], out.steady and "STEADY" or "SHAKY",
		SIDE[out.sideV or 0]
end

-- Which way a throw went (sideV: -1, 0, 1): PULLED LEFT, STRAIGHT, PULLED RIGHT.
function plan.sideText(sideV)
	return SIDE[sideV or 0] or SIDE[0]
end

tw.plan = plan
