-- The computer thrower (DESIGN.md section 4: "the computer throws the same
-- way: it plans a target and an arc and makes a swing with mistakes in it").
-- For a match setup (core/match) it does what a player does: picks a target,
-- stands behind it (tw.plan.stance), takes the default arc (tw.plan.arcFor),
-- solves the plan at a throw level (tw.plan.solve), then makes a synthetic
-- swing (the fields core/swing measures at a release) with seeded mistakes
-- in it, and tw.plan.launch turns that swing into the launch. Self-tests,
-- headless physics matches (tools/physmatch.lua) and the Playdate opponent
-- use it. Pure Lua: no playdate.*.
--
--   local r = autothrow.rng(seed)
--   local a = autothrow.choose(setup, r [, scale [, level]])
--   -- a = { x, y, swivel, loftDeg, speed, tumbleRate, tilt, legal,
--   --       plan  = the solve (tx, ty, back, release, powerLo/Hi, releaseLo/Hi, ...),
--   --       swing = the synthetic swing (back, releaseAngle, flickDps, flickFrac,
--   --               smoothness, shake, pull, how),
--   --       launch = tw.plan.launch's table (verdicts powerV, releaseV, steady),
--   --       drill = for a kubb: { markerX, markerY (from lineY), noseDown, rollLand,
--   --               spin, wobble } (world.launchDrill's arguments) }
--   autothrow.launch(w, s, a)  -- puts the throw into world w (core/world)
import "core/tw"
import "core/flight"
import "core/swing"
import "core/throwplan"
import "core/world"

local flight, swing, plan, world = tw.flight, tw.swing, tw.plan, tw.world
local cos = math.cos

local autothrow = {}

autothrow.tune = {
	level = "club",          -- the throw level it solves at (tw.plan.levels) when none is given
	-- the swing's mistakes times this at each level (autothrow.cpuLevel); pro is
	-- the recorded tournament games (Jamie, 2026-11-17), club and beginner below it
	swingScale = { beginner = 1.6, club = 1.3, pro = 1 },
	batonShort = 0,          -- m the baton's target is short of the kubb's center: none, the
	                         -- center, where a player's target snaps (measured 2026-11-15 with
	                         -- the plan's arcs: a clean baton landing up to 0.2 m past the
	                         -- center hits most often at 2 to 8 m; aimed 0.15 short, a 2 m
	                         -- baton at a field kubb hit a quarter of the time)
	minRange = 2.0,          -- m: never stands nearer its target than this, even with the
	                         -- advantage line further up (a slow lofted baton under 2 m
	                         -- hit 2 to 7 in 40; at 2 to 3 m about half)
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
	into = 1,                -- 1: aim a later kubb into the group (intoSpot) before the clear spots; 0: the clear spots only
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
	drillScale = 0.2,        -- a drilled kubb's swing mistakes are this much of a baton's
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

-- Which basket a toss goes to: -1 (left, view frame) or 1 (right), the one
-- with more field kubbs of the far half within basketNear of it.
function autothrow.basket(s, r)
	local t = autothrow.tune
	local left, right = 0, 0
	local ky = s.lineY + t.basketY
	local near2 = t.basketNear * t.basketNear
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side then
			local dy = p.y - ky
			local dl, dr = p.x + t.basketX, p.x - t.basketX
			if dl * dl + dy * dy < near2 then left = left + 1 end
			if dr * dr + dy * dy < near2 then right = right + 1 end
		end
	end
	if left > right then return -1 elseif right > left then return 1 end
	return (r.next() < 0.5) and -1 or 1
end

-- Where a toss to basket `side` should rest (view frame): the basket when
-- nothing is near it, else the clear spot nearest it (tune.spot*): not on a
-- kubb and with none in the lane it comes down and runs on in (a drill lands
-- short of its spot by its run on, so a kubb already down just past the spot
-- is its backstop). Nearest counts a step along the throw as little against
-- one across (a line along the throw) when the turn has fewer than
-- clusterFrom kubbs to throw, else the same (a cluster). The basket itself
-- when every spot is taken. Since 2026-11-16 a later kubb is first aimed
-- into the group (intoSpot below).

-- Is (x, y) a spot a drill can be aimed at: on the allowed part of the
-- half, not on a field kubb and with none in the lane it comes down and runs
-- on in (a lying one within shortLying short of it, a standing one within
-- spotShortStanding)? Piece `except` (or nil) is left out.
local function spotClear(s, t, x, y, shortLying, except)
	local ax = x < 0 and -x or x
	if ax > t.spotMaxX or y < s.lineY + t.spotMinY then return false end
	for _, p in ipairs(s.pieces) do
		if p ~= except and p.role == "field" and p.half ~= s.side then
			local dx, dy = (p.x - x) / t.spotClearX, (p.y - y) / t.spotClearY
			if dx * dx + dy * dy < 1 then return false end
			local lx, short = p.x - x, y - p.y
			if lx < 0 then lx = -lx end
			if lx < t.spotLane and short > 0
				and short < (p.toppled and shortLying or t.spotShortStanding) then
				return false
			end
		end
	end
	return true
end

-- Into the group (2026-11-16, Jamie: "good drillers roll into other kubbs
-- because it is impossible to stop that much energy with just the ground and
-- grass"). Once a kubb of the far half lies near the basket, a drill is aimed
-- so that it would rest intoShort in front of a lying kubb's near face, in
-- that kubb's lane: the half of the run-ons that would carry it on are
-- stopped by the kubb, so the two end together. A line (fewer than
-- clusterFrom kubbs this turn): the front kubb of the group nearest the
-- basket, so the line grows toward the thrower. A cluster: in front of
-- whichever lying kubb leaves the aim nearest the group's middle, so the
-- kubbs pile round it. nil when no lying kubb is near the basket, or no aim
-- in front of one is clear.
local function intoSpot(s, t, bx, by, shortLying)
	local near2 = t.basketNear * t.basketNear
	local cluster = (s.of or 0) >= t.clusterFrom
	local n, cx, cy = 0, 0, 0
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and p.toppled then
			local dx, dy = p.x - bx, p.y - by
			if dx * dx + dy * dy < near2 then n, cx, cy = n + 1, cx + p.x, cy + p.y end
		end
	end
	if n == 0 then return nil end
	cx, cy = cx / n, cy / n
	local best, bestX, bestY
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and p.toppled then
			local dx, dy = p.x - bx, p.y - by
			if dx * dx + dy * dy < near2 then
				-- the kubb's half extent along the throw (it lies along its angle)
				local a = p.pose and p.pose.angle or 0
				local ca, sa = cos(a), math.sin(a)
				if ca < 0 then ca = -ca end
				if sa < 0 then sa = -sa end
				local ext = 0.075 * sa + 0.035 * ca
				local x, y = p.x, p.y - ext - t.intoShort
				-- clear of every other kubb (this one is the backstop: the aim
				-- sits in its own clear ellipse on purpose)
				local ok = spotClear(s, t, x, y, shortLying, p)
				if ok then
					local cost
					if cluster then
						local ex, ey = x - cx, y - cy
						cost = ex * ex + ey * ey
					else
						-- the front of the group: least y, then nearest the basket across
						local ex = x - bx
						cost = y * 100 + ex * ex
					end
					if not best or cost < best - 1e-9 then best, bestX, bestY = cost, x, y end
				end
			end
		end
	end
	if not best then return nil end
	return bestX, bestY
end

function autothrow.spot(s, side)
	local t = autothrow.tune
	local bx, by = side * t.basketX, s.lineY + t.basketY
	local best, bestX, bestY
	local costY = ((s.of or 0) >= t.clusterFrom) and t.spotCostYCluster or t.spotCostY
	local shortLying = tw.drill.slideFor(plan.loftFor(plan.arcFor("drill")), s.surface)
	if shortLying < t.spotShortLying then shortLying = t.spotShortLying end
	if t.into ~= 0 then
		local ix, iy = intoSpot(s, t, bx, by, shortLying)
		if ix then return ix, iy end
	end
	for i = -t.spotCols, t.spotCols do
		for j = -t.spotRows, t.spotRows do
			local x, y = bx + i * t.spotStepX, by + j * t.spotStepY
			if spotClear(s, t, x, y, shortLying) then
				local cx, cy = i, j * costY
				local cost = cx * cx + cy * cy
				if not best or cost < best - 1e-9 then best, bestX, bestY = cost, x, y end
			end
		end
	end
	if not best then return bx, by end
	return bestX, bestY
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
		nervesLen = lv.nervesLen, tumbleSd = lv.tumbleSd }
end
-- The computer's level table for a level name (tune.level when unknown).
function autothrow.cpuLevel(name)
	return cpuLevels[name] or cpuLevels[autothrow.tune.level] or cpuLevels.club
end

-- A throw for match setup `s` (view frame). Batons: target the nearest
-- live target and stand behind it as far forward as allowed (never nearer
-- than minRange), its centre aimed through the target at plan.aimZFor's
-- height; the king from the baseline. Kubbs: drilled to the basket
-- (autothrow.basket) from the baseline. scale (default 1) multiplies every
-- mistake: below 1 a steadier thrower. level: a tw.plan level (default
-- tune.level).
function autothrow.choose(s, r, scale, level)
	scale = scale or 1
	local t = autothrow.tune
	local lname = level or t.level
	if type(lname) ~= "string" then lname = t.level end
	scale = scale * (t.swingScale[lname] or 1)
	local q = { level = autothrow.cpuLevel(lname), surface = s.surface }
	local tx, ty, py, arc
	if s.kind == "toss" then
		local side = autothrow.basket(s, r)
		tx, ty = autothrow.spot(s, side)
		q.projectile, arc = "kubb", plan.arcFor("drill")
		py = s.lineY
	else
		local pos = {}
		for _, p in ipairs(s.pieces) do pos[p.id] = p end
		local target = pos[s.targets[1]]
		-- the nearest target to the line
		for _, id in ipairs(s.targets) do
			local p = pos[id]
			if p and p.y < target.y then target = p end
		end
		tx = target.x
		if target.role == "field" then
			-- the lane with the most standing field kubbs; the nearest front on a tie
			local bestN = 0
			for _, id in ipairs(s.targets) do
				local f = pos[id]
				if f and f.role == "field" then
					local n, lo, hi = 0, f.x, f.x
					for _, id2 in ipairs(s.targets) do
						local p = pos[id2]
						if p and p.role == "field" then
							local dx, dy = p.x - f.x, p.y - f.y
							if dx < t.laneHalf and dx > -t.laneHalf and dy >= 0 and dy <= t.laneDeep then
								n = n + 1
								if p.x < lo then lo = p.x elseif p.x > hi then hi = p.x end
							end
						end
					end
					if n > bestN or (n == bestN and f.y < target.y) then
						bestN, target, tx = n, f, (lo + hi) / 2
					end
				end
			end
		end
		ty = target.y - t.batonShort
		q.projectile = "baton"
		-- through the piece at its aim height (plan.tune.aimHeightShare), as a
		-- player's circle on a piece is
		q.aimZ = plan.aimZFor((s.kingShot or target.role == "king") and "king" or "kubb")
		if s.kingShot or target.role == "king" then arc = plan.arcFor("king")
		elseif target.role == "field" then arc = plan.arcFor("field")
		else arc = plan.arcFor("base") end
		py = s.kingShot and s.lineY or (s.forwardY or s.lineY)
		if py > target.y - t.minRange then py = target.y - t.minRange end
		if py < s.lineY then py = s.lineY end
	end
	local st = plan.stance(tx, ty, s.lineY, py, t.halfWidth, {})
	q.px, q.py, q.tx, q.ty, q.release = st.x, st.y, tx, ty, arc
	local sol = plan.solve(q, {})
	if q.projectile == "kubb" then scale = scale * t.drillScale end
	local sw = autothrow.swing(sol, r, scale, {})
	-- the nerves are the player's (tw.plan.launch), drawn from this stream;
	-- scale 0 is the clean throw, no nerves either
	local L = plan.launch(sol, sw, { projectile = q.projectile, tilt = 0, spin = 0,
		nerves = scale > 0 and r or nil }, {})
	local a = { x = st.x, y = st.y, swivel = L.swivel, loftDeg = L.loft, speed = L.speed,
		tumbleRate = L.tumble, tilt = L.tilt, legal = L.legal, plan = sol, swing = sw, launch = L }
	if q.projectile == "kubb" then
		a.drill = { markerX = tx, markerY = ty - s.lineY, noseDown = L.noseDown, rollLand = L.rollLand,
			spin = L.spin, wobble = L.wobble }
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
			d.spin, d.wobble)
	end
	return world.launchBaton(w, a.x, a.y, a.swivel, a.loftDeg, a.speed, a.tumbleRate, a.tilt, s.batonId)
end

tw.autothrow = autothrow
