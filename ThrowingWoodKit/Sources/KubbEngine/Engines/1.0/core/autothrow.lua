-- The computer thrower (DESIGN.md section 4: "the computer throws the same
-- way: it plans a target and an arc and makes a swing with mistakes in it").
-- For a match setup (core/match) it does what a player does: Choose (core/cpu, on
-- what core/read sees; docs/notes/computer-player.md) picks a target, a stance line
-- and an arc (tw.plan.arcFor), and this file is the hand: it stands behind the target
-- (tw.plan.stance), solves the plan at a throw level (tw.plan.solve), then makes a
-- synthetic swing (the fields core/swing measures at a release) with seeded mistakes
-- in it, and tw.plan.launch turns that swing into the launch. Its tune holds Read's
-- and Choose's numbers too. Self-tests, headless physics matches
-- (tools/physmatch.lua) and the Playdate opponent use it. Pure Lua: no playdate.*.
--
--   local r = autothrow.rng(seed)
--   local a = autothrow.choose(setup, r [, scale [, level]])
--   -- a = { x, y, swivel, loftDeg, speed, tumbleRate, tilt, legal,
--   --       plan  = the solve (tx, ty, back, release, powerLo/Hi, releaseLo/Hi, ...),
--   --       swing = the synthetic swing (back, releaseAngle, flickDps, flickFrac,
--   --               smoothness, shake, pull, how),
--   --       launch = tw.plan.launch's table (verdicts powerV, releaseV, steady),
--   --       drill = for a kubb: { markerX, markerY (from lineY), noseDown, rollLand,
--   --               spin, wobble, scatter } (world.launchDrill's arguments) }
--   autothrow.launch(w, s, a)  -- puts the throw into world w (core/world)
import "core/tw"
import "core/flight"
import "core/swing"
import "core/throwplan"
import "core/world"

local flight, swing, plan, world = tw.flight, tw.swing, tw.plan, tw.world

local autothrow = {}

autothrow.tune = {
	level = "club",          -- the throw level it solves at (tw.plan.levels) when none is given
	-- the swing's mistakes times this at each level (autothrow.cpuLevel); pro is
	-- the recorded tournament games (Jamie, 2026-11-17), club and beginner below it.
	-- Beginner 1.6 until 0.13: then it cleared 88% of its fields against beginner's
	-- reference 35 to 55 and a newcomer on the person's meter won 3 games in 100; at
	-- 2.2 it clears about half and the newcomer wins about 52 (docs/notes/gym.md
	-- "The person's meter")
	drillSpin = 1,           -- taps of axial spin on every drill, to steady the flight: what a
	                         -- thrower's hand does, not a thing a level's name decides (until
	                         -- 0.10: beginner 0, club 1, pro 2). One tap is the least that holds
	                         -- the nose to the touch; the levels differ by their swings' mistakes
	swingScale = { kid = 1.5, beginner = 2.2, club = 1.3, pro = 1 },
	-- the king shot (0.18.0): one throw from the baseline that ends the game, or loses it
	-- when it fells a kubb with it (II.B), under the most pressure of any. Its swing's
	-- mistakes and its nerves are the level's times kingScale, set in the Gym so each
	-- level's king shots sit in its row (docs/reference/play-levels.json g.kingHit;
	-- docs/notes/gym.md "The king shot"). The computer throws it on the line before
	-- (plan.sharedArcFor), whatever field.drive says
	kingScale = { kid = 1, beginner = 1.4, club = 1.6, pro = 1.3 },
	batonShort = 0,          -- m the baton's target is short of the kubb's center: none, the
	                         -- center, where a player's target snaps (measured 2026-11-15 with
	                         -- the plan's arcs: a clean baton landing up to 0.2 m past the
	                         -- center hits most often at 2 to 8 m; aimed 0.15 short, a 2 m
	                         -- baton at a field kubb hit a quarter of the time)
	minRange = 0.25,         -- m: never stands nearer its target than this, even with the
	                         -- advantage line further up. 2.0 until 0.9 (a slow lofted
	                         -- baton under 2 m hit 2 to 7 in 40); since 0.8.0 a short throw
	                         -- is the person's low hard point-blank one (flight.handAt), so
	                         -- it stands on the line: a kubb a step away toppled 90% /
	                         -- 97% / 98% at 0.5 m (beginner / club / pro), 52% / 67% / 77%
	                         -- from the old 2 m (tools/pointblank.lua --cpu 300). 0.25 is the
	                         -- nearest the point-blank throw is measured at
	halfWidth = 2.4,         -- m: the stance stays inside the throwing line's ends (the stakes)
	-- The basket (Jamie, 2026-11-14; "basket" is the right term): real
	-- throwers put their kubbs in one of the two corners of the far half
	-- nearest the centre line, by a sideline,
	-- so a kubb that runs goes out (a rethrow) rather than somewhere bad. A
	-- turn's kubbs go to the corner that already has more field kubbs in it
	-- (either when it is a tie), so they group. The kubb is drilled to rest there.
	basketX = 1.9,           -- m from the middle: just inside the sideline's middle stake
	basketY = 4.75,          -- m from the baseline (view y): just past the centre line
	basketNear = 1.5,        -- m: field kubbs within this of a basket count for it
	-- The spot (2026-11-16): a kubb drilled onto one already lying in the
	-- basket lands on it and skips a metre away, so each kubb goes beside
	-- the group instead: the clear spot nearest the basket on a small grid.
	spotStepX = 0.12,        -- m between spots across (a kubb's width and a gap)
	spotStepY = 0.16,        -- m between spots along the throw (a kubb's length and a finger)
	spotCols = 3,            -- spots tried this many steps either side of the basket ...
	spotRows = 4,            -- ... and this many short of it and past it
	spotClearX = 0.11,       -- m: a spot is taken when a kubb's centre is within this across ...
	spotClearY = 0.15,       -- ... and this along (an ellipse: kubbs lie along the throw)
	spotLane = 0.10,         -- m: half the width of the lane the kubb comes down in
	spotShortLying = 0.12,   -- m: a lying kubb this far short of the spot in its lane is in the way
	                         -- (at least: a drill lands short of its spot by its run on,
	                         -- drill.slideFor, and a lying kubb that far short is in the way too) ...
	spotShortStanding = 0.6, -- ... a standing one this far
	spotCostY = 0.1,         -- how much a step along counts against a step across: low, so the
	                         -- kubbs go in one line along the throw, where a baton takes two ...
	-- Jamie, 2026-11-16: "trying to build lines is exactly what drillers do. You
	-- either, if you have 2 or 3, you would build a line. If you have more than that,
	-- you build a big cluster."
	clusterFrom = 4,         -- ... with this many kubbs or more to throw in the turn ...
	spotCostYCluster = 1,    -- ... a step along counts as much as one across: the spots pack round
	                         -- the first kubbs in a cluster
	spotMinY = 4.05,         -- m from the baseline: no spot nearer the centre line than this
	spotMaxX = 2.2,          -- m from the middle: no spot nearer the sideline than this
	into = 1,                -- 1: aim a later kubb into the group (core/cpu intoSpot) before the clear spots; 0: the clear spots only
	intoShort = 0.03,        -- m from a lying kubb's near face to where the drill is aimed to rest
	-- How far off a throw goes, and how much more off a long one goes, is
	-- the shared nerves model (tw.plan.tune "Nerves"), the same for the
	-- player; this file only adds the computer's swing below. The computer
	-- drills its kubbs closer than it throws batons (drillScale).
	-- The lane (2026-11-16): a baton takes two kubbs when one stands behind
	-- the other along its flight, so it aims down the lane with the most
	-- field kubbs in it, at the front one.
	laneHalf = 0.07,         -- m: kubbs within this across of the front one are in its lane ...
	laneDeep = 0.6,          -- ... and within this behind it
	-- field.line's lane along the true line (read.lineLane, 0.12.0)
	lineLevel = 0.04,        -- m: a kubb in the lane less than this nearer the stance than the
	                         -- front kubb is level with it, not in front of it
	lineKing = 0.2,          -- m across the line: a king this near the baton's path ...
	lineKingPast = 1.0,      -- ... from the stance to this far beyond the front kubb rules a stance out
	lineOwn = 0.3,           -- m: a field kubb of the thrower's own half this near the path (or
	                         -- the stance) rules it out: a baton that touches one is forfeit
	-- The inkast by level (0.11; Jamie, 2026-11-21: the inkast is where the levels
	-- differ most. A beginner tosses the kubbs out with no group; a club player knows
	-- the technique but controls it less; a pro's kubbs lie touching). spin: taps,
	-- toward the sideline (the spin steadies the flight and, on a dead landing, rolls
	-- the kubb in: world.tune deadLanding); hand: the swing's mistakes against a
	-- baton's (the level's swingScale is not applied to a drill); group: 0 throws every
	-- kubb at the basket itself, 1 rests each beside the kubbs already lying
	-- (cpu.spot); row: with group, 1 lays them flank to flank in a row
	-- (rowStep apart), 0 picks a clear spot from the grid as 0.10 did. How steady
	-- the release is comes from the level too (plan.levels' drillScatter).
	inkast = {
		kid = { spin = 0, hand = 0.6, group = 0, row = 0 },   -- 0.15.0: tossed out, as a beginner, rougher
		beginner = { spin = 0, hand = 0.5, group = 0, row = 0 },
		club = { spin = 1, hand = 0.26, group = 1, row = 1 },
		pro = { spin = 1, hand = 0.06, group = 1, row = 1 },
	},
	rowStep = 0.075,         -- m across between kubbs lying flank to flank in a row
	drillScale = 0.2,        -- a drilled kubb's swing mistakes are this much of a baton's, for a
	                         -- level inkast does not name
	-- The synthetic swing: the mistakes, each multiplied by choose's scale.
	-- Halved 2026-11-16 when the nerves took over most of the miss (they
	-- were 5, 9 and 0.44 when the swing was the only error).
	backSd = 2.5,            -- degrees sd of the backswing about the power target's center
	releaseSd = 4.5,         -- degrees sd of where the crank stops about the release target's center
	flickDps = { 1050, 1400 }, -- deg/s: a strong flick (swing.tune.fullFlickDps and over: all the power)
	softChance = 0.05,       -- chance the flick is not quite full ...
	softDps = { 850, 1000 }, -- ... and then this fast (flickFrac 0.85 to 1: short)
	shakeMax = 0.22,         -- a steady swing's shake is even between 0 and this (tw.plan.launch
	                         -- pulls the swivel and tilts the baton by it, and it widens the nerves)
	shakyChance = 0.015,     -- chance of a shaky swing ...
	shaky = { 0.25, 0.6 },   -- ... with this much shake (over about 0.44 a baton is a helicopter at club)
}

-- Park-Miller with a scrambled seed (as tools/thrower.lua): tw.plan.rng.
autothrow.rng = plan.rng

-- The launch speed that lands a baton's center at distance d (along the
-- throw) at this loft, through still air with its drag (flight.predict's
-- arc), up to the fastest throw the plan makes (the backswing's cap). Tools,
-- tests and core/bench aim with it.
function autothrow.speedFor(d, loftDeg)
	local hi = plan.speedFor(swing.tune.backswingMaxDeg)
	if d <= 0 then return 0.5 end
	local ft = flight.tune
	local v = flight.speedForCarry(d, math.rad(loftDeg), ft.handHeight, ft.dragK.baton)
	if v > hi then return hi end
	if v < 0.5 then return 0.5 end
	return v
end

-- The basket and the spot are Choose's (core/cpu, 0.11.1); these names stay for the
-- tools and tests that call them. autothrow.basket(s, r) -> -1 or 1 (draws from r on a
-- tie); autothrow.spot(s, side, ik) -> x, y.
function autothrow.basket(s, r)
	local side = tw.cpu.basket(s, r)
	return side
end

function autothrow.spot(s, side, ik)
	local x, y = tw.cpu.spot(s, side, ik)
	return x, y
end

-- The swing a thrower makes at solution sol, with seeded mistakes scaled by
-- scale (0: the clean swing, every field on its target). Always draws the
-- same number of values from r. Fills and returns out: core/swing's result
-- fields (back, releaseAngle, flickDps, flickFrac, smoothness, shake, pull,
-- how = "stopped").
function autothrow.swing(sol, r, scale, out)
	local t, st = autothrow.tune, swing.tune
	out = out or {}
	local back = sol.back + r.normal(t.backSd) * scale
	if back > st.backswingMaxDeg then back = st.backswingMaxDeg end
	out.back = back
	local rel = sol.release + r.normal(t.releaseSd) * scale
	if rel < 1 then rel = 1 elseif rel > st.skyDeg - 1 then rel = st.skyDeg - 1 end
	out.releaseAngle = rel
	-- the flick: strong, now and then not quite
	local soft = r.next() < t.softChance * scale
	local u = r.next()
	local dps
	if soft then dps = t.softDps[1] + (t.softDps[2] - t.softDps[1]) * u
	else dps = t.flickDps[1] + (t.flickDps[2] - t.flickDps[1]) * u end
	if scale <= 0 then dps = st.fullFlickDps end
	local f = (dps - st.swingStartDps) / (st.fullFlickDps - st.swingStartDps)
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	out.flickDps = dps
	out.flickFrac = st.minFlickFrac + (1 - st.minFlickFrac) * f
	-- the steadiness: mostly steady, now and then shaky
	local shaky = r.next() < t.shakyChance * scale
	local u2 = r.next()
	local shake = t.shakeMax * r.next() * scale
	if shaky then shake = t.shaky[1] + (t.shaky[2] - t.shaky[1]) * u2 end
	if shake > 1 then shake = 1 end
	out.shake, out.smoothness = shake, 1 - shake
	out.pull = (r.next() < 0.5) and -1 or 1
	out.how = "stopped"
	return out
end

-- The computer's level tables (2026-11-17). A level's gauge forgiveness
-- (powerHalf, releaseHalf, inGain, shakeGain, overGain) is there to help a
-- player's crank; the computer's swing has the same mistakes at every
-- level, so forgiving it more made club throw better than pro. So the
-- computer always throws on pro's gauge, with the named level's nerves and
-- tumble, and its swing's mistakes times tune.swingScale for the level.
-- Pro is the recorded tournament games (Jamie, 2026-11-17). Made once.
local cpuLevels = {}
for name, lv in pairs(plan.levels) do
	local pro = plan.levels.pro
	cpuLevels[name] = { powerHalf = pro.powerHalf, releaseHalf = pro.releaseHalf, inGain = pro.inGain,
		shakeGain = pro.shakeGain, overGain = pro.overGain, nervesDeg = lv.nervesDeg,
		nervesLen = lv.nervesLen, tumbleTurns = lv.tumbleTurns, tumbleSd = lv.tumbleSd,
		drillScatter = lv.drillScatter }
end
-- A level table with its nerves times k (the king shot). One table per level and k is
-- reused, and filled from the level on every call: the Gym serves each team's own nerves
-- through the same level table (tools/gym/versus.lua), so a copy made once would keep
-- whichever team threw at the king first.
local kingLevels = {}
local function kingLevel(lv, k)
	local byK = kingLevels[lv]
	if not byK then byK = {}; kingLevels[lv] = byK end
	local o = byK[k]
	if not o then o = {}; byK[k] = o end
	for key, v in pairs(lv) do o[key] = v end
	o.nervesDeg, o.nervesLen = lv.nervesDeg * k, lv.nervesLen * k
	return o
end

-- The computer's level table for a level name (tune.level when unknown).
function autothrow.cpuLevel(name)
	return cpuLevels[name] or cpuLevels[autothrow.tune.level] or cpuLevels.club
end

-- A throw for match setup `s` (view frame): Choose (cpu.decide: the target, the spot,
-- the stance and the arc, and why) then the hand. scale (default 1) multiplies every
-- mistake: below 1 a steadier thrower. level: a tw.plan level (default the thrower's,
-- then tune.level). A baton's throw names the piece it is aimed at (`on`, its id: the
-- front kubb of the lane it aims across), a drill none. The decision's reason is not in
-- the result, which reaches the session's actions and recordings: it is tw.cpu.last.
function autothrow.choose(s, r, scale, level)
	scale = scale or 1
	local scale0 = scale
	local t = autothrow.tune
	local cpu = tw.cpu
	local lname = cpu.levelName(s, level)
	scale = scale * (t.swingScale[lname] or 1)
	local q = { level = autothrow.cpuLevel(lname), surface = s.surface }
	local d = cpu.decide(s, r, lname)
	local it = d.intent
	local tx, ty = it.tx, it.ty
	if d.kind == "toss" then
		q.spin = it.spin
		q.projectile = "kubb"
	else
		q.projectile = "baton"
		q.aimZ = it.aimZ
	end
	-- straight behind the target on the line it stands on (Choose works a baton's out,
	-- since its arc goes by the distance from there)
	local st = it.stance or plan.stance(tx, ty, s.lineY, it.standY, t.halfWidth, {})
	q.px, q.py, q.tx, q.ty, q.release = st.x, st.y, tx, ty, it.arc
	local sol = plan.solve(q, {})
	if q.projectile == "kubb" then
		-- the inkast's hand by level (tune.inkast), not the level's swingScale
		local ik = t.inkast[lname]
		if ik then scale = scale0 * ik.hand else scale = scale * t.drillScale end
	end
	-- the king shot: the level's mistakes and nerves times kingScale
	local launchLevel = nil
	local ks = (q.projectile == "baton" and it.on == "king") and (t.kingScale[lname] or 1) or 1
	if ks ~= 1 then
		scale = scale * ks
		launchLevel = kingLevel(sol.level, ks)
	end
	local sw = autothrow.swing(sol, r, scale, {})
	-- the nerves are the player's (tw.plan.launch), drawn from this stream;
	-- scale 0 is the clean throw, no nerves either
	local L = plan.launch(sol, sw, { projectile = q.projectile, tilt = 0, spin = q.spin, level = launchLevel,
		nerves = scale > 0 and r or nil }, {})
	local a = { x = st.x, y = st.y, swivel = L.swivel, loftDeg = L.loft, speed = L.speed,
		tumbleRate = L.tumble, tilt = L.tilt, legal = L.legal, plan = sol, swing = sw, launch = L, on = it.on }
	if q.projectile == "kubb" then
		a.drill = { markerX = tx, markerY = ty - s.lineY, noseDown = L.noseDown, rollLand = L.rollLand,
			spin = L.spin, wobble = L.wobble, scatter = L.scatter }
	end
	return a
end

-- Put throw a (autothrow.choose) for setup s into world w: a drilled kubb
-- (world.launchDrill, kubb s.kubb) or a baton (world.launchBaton, the turn's
-- baton id s.batonId). Returns the body.
function autothrow.launch(w, s, a)
	local d = a.drill
	if d then
		return world.launchDrill(w, s.kubb, a.x, a.y, a.swivel, a.loftDeg, a.speed, d.noseDown, d.rollLand,
			d.spin, d.wobble, d.scatter)
	end
	-- from the hand the plan was solved for, as the session throws (flight.handAt:
	-- low and ahead of the feet under flight.tune.nearM, upright over them beyond)
	local p = a.plan
	return world.launchBaton(w, a.x, a.y, a.swivel, a.loftDeg, a.speed, a.tumbleRate, a.tilt, s.batonId,
		p and p.handZ, p and p.handFwd, p and p.handTip)
end

tw.autothrow = autothrow

-- Choose (core/cpu) and Read (core/read) read this file's tune, so they are imported
-- once tw.autothrow is set; choose finds tw.cpu when it is called.
import "core/cpu"
