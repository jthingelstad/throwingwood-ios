-- Raising geometry (Rules V4.0 II.D) and punishment placement (II.D.11).
-- Pure Lua: no playdate.*. Not a per-frame path.
--
-- A pose is { x, y, standing, angle, onTop }:
--   x, y      center of the kubb on the ground, meters
--   standing  true when it stands on an end (upright), false when lying
--   angle     lying: direction of the long axis (radians from +x);
--             standing: yaw of the 7 x 7 square
--   onTop     id of a kubb it rests on (II.D.6), else nil
--
-- Raising a lying kubb tips it onto one end, keeping that end's two bottom
-- corners on the ground (II.D.1). Pivoting about that bottom edge leaves the
-- end face flat on the ground just beyond the old end, so the two footprints
-- are 7 x 7 squares centered 7.5 + 3.5 = 11 cm out along the axis each way.
-- End 1 is the +axis end, end 2 the -axis end.
--
-- A context says what is around the kubb being raised:
--   ctx.half    the defender's half ("A" or "B"): where it must be raised
--   ctx.king    the king's pose (standing)
--   ctx.others  array of { id, pose, kind } for every other kubb on the pitch
--               (kind "base" or "field"; core/rules sets it, a caller may not)
import "core/tw"
import "core/pitch"
import "core/rect"
import "core/quat"

local pitch, rect = tw.pitch, tw.rect
local cos, sin, pi, sqrt, huge, floor = math.cos, math.sin, math.pi, math.sqrt, math.huge, math.floor

local raising = {}

raising.tune = {
	searchDirections = 32,   -- directions tried when a footprint must slide clear of an obstruction
	searchStep = 0.004,      -- m, coarse step of that search before bisection
	searchMax = 0.6,         -- m, give up beyond this
	punishGrid = 0.1,        -- m, spacing of candidate punishment spots
	-- raising.policies.par (raise.par, raise.across): the end that leaves the attacker's
	-- batons the fewest kubbs one behind another. The pro computer's and a person's
	-- (core/cpu.raising); the game's own policy, for a match that names no sides, is apart.
	-- Two kubbs are a pair on a baton's path by how far apart they are across that path
	-- and along it; see parPair below.
	parAcrossFull = 0.04,    -- m across: closer than this, one is squarely behind the other
	parAcrossReach = 0.13,   -- m across: past this, a baton or a kubb falling back misses the second
	parDepthRamp = 0.05,     -- m along: level kubbs are side by side; full exposure from here ...
	parDepthFlat = 0.30,     -- ... to here (a struck kubb falls back about its 15 cm height) ...
	parDepthReach = 0.60,    -- ... and none from here on (the computer's laneDeep)
	parSide = 0.5,           -- weight of each end of the throwing line's view, straight on being 1
	parTie = 0.02,           -- exposures closer than this are a tie, which goes to apart
	parSweeps = 3,           -- passes of the plan over the kubbs still lying (0: no plan)
}

local HALF_LONG, HALF_SIDE = pitch.kubbLong / 2, pitch.kubbSide / 2
local FOOT_OFFSET = HALF_LONG + HALF_SIDE

function raising.pose(x, y, standing, angle, onTop)
	return { x = x, y = y, standing = standing and true or false, angle = angle or 0, onTop = onTop }
end

local function copyPose(p)
	return { x = p.x, y = p.y, standing = p.standing, angle = p.angle or 0, onTop = p.onTop }
end
raising.copyPose = copyPose

-- The ground rectangle a kubb occupies in this pose.
function raising.kubbRect(p)
	if p.standing then return rect.new(p.x, p.y, p.angle or 0, HALF_SIDE, HALF_SIDE) end
	return rect.new(p.x, p.y, p.angle or 0, HALF_LONG, HALF_SIDE)
end

function raising.kingRect(p)
	local h = pitch.kingSide / 2
	return rect.new(p.x, p.y, p.angle or 0, h, h)
end

-- Both standing poses of a lying kubb: { [1] = +axis end, [2] = -axis end }.
function raising.footprints(p)
	local a = p.angle or 0
	local c, s = cos(a), sin(a)
	return {
		{ x = p.x + c * FOOT_OFFSET, y = p.y + s * FOOT_OFFSET, standing = true, angle = a },
		{ x = p.x - c * FOOT_OFFSET, y = p.y - s * FOOT_OFFSET, standing = true, angle = a },
	}
end

-- A lying kubb part way up onto end `which` (1 = +axis, 2 = -axis): it
-- pivots on that end's bottom edge (II.D.1), t = 0 lying, t = 1 standing on
-- that end's footprint. Returns its centre and orientation, x, y, z, qw, qx,
-- qy, qz (the long axis is the body's local z, as core/body has it), for
-- drawing the crank raise. Pure numbers, no tables.
function raising.tipPose(p, which, t)
	local a = p.angle or 0
	local ux, uy = cos(a), sin(a)
	if which == 2 then ux, uy = -ux, -uy end
	local L, S = pitch.kubbLong, pitch.kubbSide
	local th = t * pi / 2
	local c, sn = cos(th), sin(th)
	-- the pivot (the end's bottom edge) and the centre around it, in the plane
	-- of the axis and up
	local px, py = p.x + ux * L / 2, p.y + uy * L / 2
	local along, up = -L / 2 * c + S / 2 * sn, L / 2 * sn + S / 2 * c
	-- the orientation: first turned about the vertical to the kubb's angle (so
	-- the square cross-section is square to its axis and a face lies flat),
	-- then the long axis turned from up to along the ground (a quarter turn
	-- about the horizontal normal) and on by th toward down
	local quat = tw.quat
	local zw, zx, zy, zz = quat.fromAxisAngle(0, 0, 1, a)
	local tw_, tx, ty, tz = quat.fromAxisAngle(-uy, ux, 0, pi / 2 + th)
	local qw, qx, qy, qz = quat.mul(tw_, tx, ty, tz, zw, zx, zy, zz)
	return px + ux * along, py + uy * along, up, qw, qx, qy, qz
end

-- A standing pose is in bounds when its center is in the half (50% in is in).
function raising.inBounds(p, half)
	return pitch.inHalf(half, p.x, p.y)
end

-- Can this kubb end up standing in bounds? Standing on an end: already raised
-- if 50% in (II.D.2). Lying: if either footprint is in bounds (II.D.3).
function raising.canRaise(p, half)
	if p.standing then return raising.inBounds(p, half) end
	local f = raising.footprints(p)
	return raising.inBounds(f[1], half) or raising.inBounds(f[2], half)
end

-- What obstructs a standing footprint: "king", "stake" or a kubb id; nil if clear.
function raising.obstruction(fp, ctx)
	local r = raising.kubbRect(fp)
	if ctx.king and rect.overlap(r, raising.kingRect(ctx.king)) then return "king" end
	for _, s in ipairs(pitch.stakes) do
		if rect.pointDistance(r, s.x, s.y) < pitch.stakeRadius - rect.eps then return "stake" end
	end
	for _, o in ipairs(ctx.others or {}) do
		if rect.overlap(r, raising.kubbRect(o.pose)) then return o.id end
	end
	return nil
end

-- Slide `p` the shortest distance that makes ok(pose) true, trying evenly
-- spread directions. Returns the moved pose and the distance, or nil.
function raising.nearestClear(p, ok, dirs)
	local t = raising.tune
	local best, bestD = nil, huge
	local n = t.searchDirections
	local list = dirs
	if not list then
		list = {}
		for k = 0, n - 1 do
			local a = 2 * pi * k / n
			list[#list + 1] = { cos(a), sin(a) }
		end
	end
	for _, d in ipairs(list) do
		local prev = 0
		local step = t.searchStep
		local dist = step
		while dist <= t.searchMax and dist < bestD do
			local q = copyPose(p)
			q.x, q.y = p.x + d[1] * dist, p.y + d[2] * dist
			if ok(q) then
				local lo, hi = prev, dist
				for _ = 1, 20 do
					local mid = (lo + hi) / 2
					local m = copyPose(p)
					m.x, m.y = p.x + d[1] * mid, p.y + d[2] * mid
					if ok(m) then hi = mid else lo = mid end
				end
				local r = copyPose(p)
				r.x, r.y = p.x + d[1] * hi, p.y + d[2] * hi
				if hi < bestD then best, bestD = r, hi end
				break
			end
			prev = dist
			dist = dist + step
		end
	end
	return best, best and bestD or nil
end

-- The raising decision for one kubb (II.D.1 to II.D.5). Returns
--   { mode, choices, ends }
-- where ends[i] = { pose, inBounds, obstructedBy } for both footprints and
-- choices is the list the defender may pick from, each { which = 1|2, pose,
-- displaced }. Modes:
--   "standing"  it already stands on an end in bounds: not moved (II.D.2)
--   "choice"    both footprints clear and in bounds: the defender chooses
--   "forced"    exactly one footprint clear and in bounds: raised there
--   "displaced" no clear footprint: raised on an in-bounds end touching the
--               obstruction as close as possible to its footprint (II.D.5);
--               when both ends qualify the defender chooses
--   "out"       it cannot be raised in bounds (the engine never asks then)
function raising.options(p, ctx)
	if p.standing then
		local mode = raising.inBounds(p, ctx.half) and "standing" or "out"
		return { mode = mode, choices = mode == "standing" and { { which = 0, pose = copyPose(p) } } or {}, ends = {} }
	end
	local fps = raising.footprints(p)
	local ends = {}
	for i = 1, 2 do
		ends[i] = { pose = fps[i], inBounds = raising.inBounds(fps[i], ctx.half), obstructedBy = raising.obstruction(fps[i], ctx) }
	end
	local clear = {}
	for i = 1, 2 do
		if ends[i].inBounds and not ends[i].obstructedBy then clear[#clear + 1] = i end
	end
	if #clear == 2 then
		return { mode = "choice", ends = ends, choices = {
			{ which = 1, pose = fps[1] }, { which = 2, pose = fps[2] } } }
	elseif #clear == 1 then
		return { mode = "forced", ends = ends, choices = { { which = clear[1], pose = fps[clear[1]] } } }
	end
	local choices = {}
	local ok = function(q)
		return raising.inBounds(q, ctx.half) and not raising.obstruction(q, ctx)
	end
	for i = 1, 2 do
		if ends[i].inBounds then
			local q = raising.nearestClear(fps[i], ok)
			if q then choices[#choices + 1] = { which = i, pose = q, displaced = true } end
		end
	end
	if #choices == 0 then
		-- Nowhere clear within reach (a crowded corner): an in-bounds
		-- footprint is used as it is rather than leaving the kubb down.
		for i = 1, 2 do
			if ends[i].inBounds then choices[#choices + 1] = { which = i, pose = fps[i], displaced = false, crowded = true } end
		end
		if #choices == 0 then return { mode = "out", ends = ends, choices = {} } end
	end
	return { mode = "displaced", ends = ends, choices = choices }
end

-- II.D.6: a kubb resting on another is lowered straight down to the pitch,
-- touching the lower kubb. It keeps its axis, lies flat, and slides out
-- along the line from the lower kubb's center to its own (or across the
-- lower kubb's axis when the centers coincide) until it just touches.
function raising.lower(upper, lowerPose)
	local p = copyPose(upper)
	p.standing, p.onTop = false, nil
	local lr = raising.kubbRect(lowerPose)
	local dx, dy = p.x - lowerPose.x, p.y - lowerPose.y
	local len = sqrt(dx * dx + dy * dy)
	if len < 1e-6 then
		local a = (lowerPose.angle or 0) + pi / 2
		dx, dy, len = cos(a), sin(a), 1
	end
	local dir = { { dx / len, dy / len } }
	local ok = function(q) return not rect.overlap(raising.kubbRect(q), lr) end
	if ok(p) then return p end
	local q = raising.nearestClear(p, ok, dir)
	return q or p
end

-- Automatic choosers for the "auto raise" setting and the computer. Each takes
-- (decision, ctx) and returns an index into decision.choices (par also returns what it
-- weighed, for the computer's reason). Which side uses which: core/cpu.raising and
-- core/match.raisePolicy.
local function spread(pose, ctx)
	local m = huge
	for _, o in ipairs(ctx.others or {}) do
		local dx, dy = o.pose.x - pose.x, o.pose.y - pose.y
		local d = sqrt(dx * dx + dy * dy)
		if d < m then m = d end
	end
	return m
end

-- Keep kubbs apart: the end farthest from the nearest other kubb (the defender's
-- usual aim: no doubles). Ties go to the deeper end.
local function apart(dec, ctx)
	local best, bestScore = 1, -huge
	for i, c in ipairs(dec.choices) do
		local s = spread(c.pose, ctx) + 1e-3 * pitch.fromBaseline(pitch.other(ctx.half), c.pose.y)
		if s > bestScore + 1e-12 then best, bestScore = i, s end
	end
	return best
end

-- raise.par (docs/reference/plays/raise.md): stand the kubb where the attacker's batons
-- find the fewest kubbs one behind another. Two kubbs are exposed to one baton when, on
-- its path, one stands behind the other: close across the path (parAcrossFull to
-- parAcrossReach) and apart along it, but not level (side by side, nothing behind) and not
-- far (parDepthFlat to parDepthReach). Space across counts far more than space along it
-- (raise.across): a pair 10 cm apart across and level is no double; 10 cm across and 20
-- along is. The path is seen straight down the pitch (where the computer stands, behind
-- its target) and, at parSide each, from the two ends of the attacker's baseline.
--
-- The rules ask for one kubb at a time (core/rules raises them in id order). So that an
-- early kubb is not stood where a later one has to stand badly (raise.order, "decide them
-- all before standing one"), par plans every lying kubb of the half: each starts on its
-- better end against the standing kubbs, then parSweeps passes move each to its better end
-- against the standing kubbs and the others' planned ends. The kubb asked for takes its
-- planned end. A kubb still lying counts at its footprints that are in bounds and clear of
-- the king and the standing kubbs (its displacement, if any, is not guessed). Ties (within
-- parTie) go to apart. Work: at most 10 kubbs a half, so a few hundred pair tests a call.
local function parPair(ax, ay, bx, by, dx, dy, t)
	local rx, ry = bx - ax, by - ay
	local along = rx * dx + ry * dy
	if along < 0 then along = -along end
	local across = rx * dy - ry * dx
	if across < 0 then across = -across end
	local reach, deep = t.parAcrossReach, t.parDepthReach
	if across >= reach or along >= deep then return 0 end
	local full = t.parAcrossFull
	local wa = across > full and (reach - across) / (reach - full) or 1
	local wd
	if along < t.parDepthRamp and across >= pitch.kubbSide then
		-- nearly level and clear of each other across: side by side. (Closer across, they
		-- touch one behind the other, or in a plan overlap: as bad as a pair can be.)
		wd = along / t.parDepthRamp
	elseif along <= t.parDepthFlat then
		wd = 1
	else
		wd = (deep - along) / (deep - t.parDepthFlat)
	end
	return wa * wd
end

-- The exposure of kubbs at (ax, ay) and (bx, by) to an attacker throwing from lineY
-- toward dirY (+1 or -1 in y).
local function parExposure(ax, ay, bx, by, dirY, lineY, t)
	local rx, ry = bx - ax, by - ay
	local far = t.parAcrossReach * t.parAcrossReach + t.parDepthReach * t.parDepthReach
	if rx * rx + ry * ry >= far then return 0 end
	local e = parPair(ax, ay, bx, by, 0, dirY, t)
	local side = t.parSide
	if side > 0 then
		local mx, my = (ax + bx) / 2, (ay + by) / 2 - lineY
		for s = -1, 1, 2 do
			local vx = mx - s * pitch.halfWidth
			local l = sqrt(vx * vx + my * my)
			if l > 1e-9 then e = e + side * parPair(ax, ay, bx, by, vx / l, my / l, t) end
		end
	end
	return e
end

local function footClear(fp, ctx, sx, sy, ns)
	if not raising.inBounds(fp, ctx.half) then return false end
	local r = raising.kubbRect(fp)
	if ctx.king and rect.overlap(r, raising.kingRect(ctx.king)) then return false end
	for i = 1, ns do
		if rect.overlap(r, rect.new(sx[i], sy[i], 0, HALF_SIDE, HALF_SIDE)) then return false end
	end
	return true
end

-- The plan's numbers for a decision: the standing field kubbs of the half (sx, sy) and
-- the lying ones with their candidate ends (cx, cy: item j's ends at 2j-1 and 2j, nc[j]
-- of them). Item 0 is the kubb being raised, its ends the decision's choices.
local function parScene(dec, ctx)
	local sx, sy, ns = {}, {}, 0
	local lying = {}
	for _, o in ipairs(ctx.others or {}) do
		if o.kind ~= "base" then
			local p = o.pose
			if p.standing then
				if raising.inBounds(p, ctx.half) then ns = ns + 1; sx[ns], sy[ns] = p.x, p.y end
			else
				lying[#lying + 1] = p
			end
		end
	end
	local cx, cy, nc = {}, {}, {}
	local items = 0
	for _, p in ipairs(lying) do
		local fps = raising.footprints(p)
		local n = 0
		for k = 1, 2 do
			if footClear(fps[k], ctx, sx, sy, ns) then
				n = n + 1
				cx[2 * items + n], cy[2 * items + n] = fps[k].x, fps[k].y
			end
		end
		if n > 0 then
			items = items + 1
			nc[items] = n
		end
	end
	return sx, sy, ns, cx, cy, nc, items
end

-- The exposure of a kubb at (x, y): to every standing kubb, and to every lying item but
-- `skip` at its planned end (pick[j]), or with sweeps 0 at each of its ends weighed by
-- 1 / its number of ends.
local function parAt(x, y, sc, pick, skip, dirY, lineY, t)
	local sx, sy, ns, cx, cy, nc, items = sc[1], sc[2], sc[3], sc[4], sc[5], sc[6], sc[7]
	local e = 0
	for i = 1, ns do e = e + parExposure(x, y, sx[i], sy[i], dirY, lineY, t) end
	for j = 1, items do
		if j ~= skip then
			if pick then
				local k = 2 * (j - 1) + pick[j]
				e = e + parExposure(x, y, cx[k], cy[k], dirY, lineY, t)
			else
				local w = 1 / nc[j]
				for m = 1, nc[j] do
					local k = 2 * (j - 1) + m
					e = e + w * parExposure(x, y, cx[k], cy[k], dirY, lineY, t)
				end
			end
		end
	end
	return e
end

local function par(dec, ctx)
	local t = raising.tune
	local half = ctx.half
	local lineY = pitch.baseline[pitch.other(half)]
	local dirY = pitch.baseline[half] > lineY and 1 or -1
	local sx, sy, ns, cx, cy, nc, items = parScene(dec, ctx)
	local sc = { sx, sy, ns, cx, cy, nc, items }
	local choices = dec.choices
	-- the kubb being raised also counts against the lying items: as item 0, at its
	-- planned choice (cur)
	local pick
	local sweeps = floor(t.parSweeps + 0.5)
	local cur = 1
	local function better(x, y, j)
		local e = parAt(x, y, sc, pick, j, dirY, lineY, t)
		if pick then
			local c = choices[cur].pose
			e = e + parExposure(x, y, c.x, c.y, dirY, lineY, t)
		end
		return e
	end
	if sweeps > 0 and items > 0 then
		pick = {}
		-- start: each lying item on its better end against the standing kubbs alone
		for j = 1, items do
			local best, bestE = 1, huge
			for m = 1, nc[j] do
				local k = 2 * (j - 1) + m
				local e = 0
				for i = 1, ns do e = e + parExposure(cx[k], cy[k], sx[i], sy[i], dirY, lineY, t) end
				if e < bestE - 1e-12 then best, bestE = m, e end
			end
			pick[j] = best
		end
		for _ = 1, sweeps do
			local moved = false
			-- the kubb being raised
			local best, bestE = cur, huge
			for i, c in ipairs(choices) do
				local e = parAt(c.pose.x, c.pose.y, sc, pick, 0, dirY, lineY, t)
				if e < bestE - 1e-12 then best, bestE = i, e end
			end
			if best ~= cur then cur, moved = best, true end
			for j = 1, items do
				if nc[j] > 1 then
					local b, bE = pick[j], huge
					for m = 1, nc[j] do
						local k = 2 * (j - 1) + m
						local e = better(cx[k], cy[k], j)
						if e < bE - 1e-12 then b, bE = m, e end
					end
					if b ~= pick[j] then pick[j], moved = b, true end
				end
			end
			if not moved then break end
		end
	end
	-- the decision: each choice's exposure against the plan; a tie goes to apart
	local lo, hi, loI = huge, -huge, 1
	for i, c in ipairs(choices) do
		local e = parAt(c.pose.x, c.pose.y, sc, pick, 0, dirY, lineY, t)
		if e < lo - 1e-12 then lo, loI = e, i end
		if e > hi then hi = e end
	end
	-- the second value is for a reason (core/cpu.raise), never for play
	if hi - lo <= t.parTie then return apart(dec, ctx), { exposure = lo, over = hi, tie = true } end
	return loI, { exposure = lo, over = hi, tie = false }
end
raising.parExposure = parExposure
-- one view's pair weight (core/read.lineLane weighs a lane by it: field.line)
raising.parPair = parPair

raising.policies = {
	apart = apart,
	-- Count the attacker's batons (raise.par): the pro computer's, and a person's when
	-- the engine raises for them (core/cpu.raising, core/match.raisePolicy; 0.12.0).
	par = par,
	-- Group them (for drills and tests).
	together = function(dec, ctx)
		local best, bestScore = 1, huge
		for i, c in ipairs(dec.choices) do
			local s = spread(c.pose, ctx)
			if s < bestScore - 1e-12 then best, bestScore = i, s end
		end
		return best
	end,
	first = function() return 1 end,
}

function raising.choose(dec, ctx, policy)
	if #dec.choices <= 1 then return 1 end
	local fn = type(policy) == "function" and policy or raising.policies[policy or "apart"]
	return fn(dec, ctx)
end

-- II.D.11: a punishment kubb stands anywhere in the defender's half, at
-- least one baton length (30 cm, edge to edge) from the king and from every
-- stake, not overlapping another kubb. Returns true, or false and a reason.
function raising.punishmentCheck(p, ctx)
	if not raising.inBounds(p, ctx.half) then return false, "not in the half" end
	local r = raising.kubbRect(p)
	if ctx.king and rect.distance(r, raising.kingRect(ctx.king)) < pitch.batonLength - 1e-9 then
		return false, "closer than a baton length to the king"
	end
	for _, s in ipairs(pitch.stakes) do
		if rect.pointDistance(r, s.x, s.y) < pitch.batonLength - 1e-9 then
			return false, "closer than a baton length to a stake"
		end
	end
	for _, o in ipairs(ctx.others or {}) do
		if rect.overlap(r, raising.kubbRect(o.pose)) then return false, "overlaps kubb " .. o.id end
	end
	return true
end

-- Every valid punishment spot on a grid (standing, yaw 0).
function raising.punishmentCandidates(ctx)
	local g = raising.tune.punishGrid
	local out = {}
	local y0 = pitch.baseline[ctx.half]
	local dirY = ctx.half == "A" and 1 or -1
	local nx = floor(2 * pitch.halfWidth / g + 0.5)
	local ny = floor(pitch.center / g + 0.5)
	for j = 0, ny do
		for i = 0, nx do
			local p = { x = -pitch.halfWidth + i * g, y = y0 + dirY * j * g, standing = true, angle = 0 }
			if raising.punishmentCheck(p, ctx) then out[#out + 1] = p end
		end
	end
	return out
end

-- A spot this far (center to center) from everything is valid without the
-- rectangle tests: farther than a baton length plus both half-diagonals from
-- the king and the stakes, and than both half-diagonals from every kubb.
local KUBB_DIAG = HALF_SIDE * sqrt(2)
local LYING_DIAG = sqrt(HALF_LONG * HALF_LONG + HALF_SIDE * HALF_SIDE)
local scratch = { x = 0, y = 0, standing = true, angle = 0 }

-- The spot (x, y) with nothing near it: true, or nil when something is close
-- enough that raising.punishmentCheck has to decide. Makes no tables.
local function clearSpot(x, y, ctx)
	local king = ctx.king
	if king then
		local dx, dy = king.x - x, king.y - y
		local r = pitch.batonLength + KUBB_DIAG + pitch.kingSide / 2 * sqrt(2) + 1e-6
		if dx * dx + dy * dy < r * r then return nil end
	end
	local r = pitch.batonLength + KUBB_DIAG + 1e-6
	local r2 = r * r
	local stakes = pitch.stakes
	for i = 1, #stakes do
		local dx, dy = stakes[i].x - x, stakes[i].y - y
		if dx * dx + dy * dy < r2 then return nil end
	end
	r = KUBB_DIAG + LYING_DIAG + 1e-6
	r2 = r * r
	local others = ctx.others
	if others then
		for i = 1, #others do
			local o = others[i].pose
			local dx, dy = o.x - x, o.y - y
			if dx * dx + dy * dy < r2 then return nil end
		end
	end
	return true
end

-- The automatic placement: deep in the half (far from the attacker) and away
-- from other kubbs. `policy` may be a function(candidates, ctx) -> pose.
-- The default search makes no table per spot: on the device the plain
-- candidate list (2091 spots, a dozen rectangles each) ran past the 10 s
-- watchdog. It picks the same spot as scoring raising.punishmentCandidates.
function raising.autoPunishment(ctx, policy)
	if type(policy) == "function" then
		local cands = raising.punishmentCandidates(ctx)
		if #cands == 0 then return nil end
		return policy(cands, ctx)
	end
	local g = raising.tune.punishGrid
	local y0 = pitch.baseline[ctx.half]
	local dirY = ctx.half == "A" and 1 or -1
	local nx = floor(2 * pitch.halfWidth / g + 0.5)
	local ny = floor(pitch.center / g + 0.5)
	local far = pitch.other(ctx.half)
	local p = scratch
	local bx, by, bestScore = nil, nil, -huge
	for j = 0, ny do
		-- rows run from the deepest; a row whose best possible score cannot
		-- beat the spot in hand ends the search (the usual case: row one)
		local rowBest = pitch.fromBaseline(far, y0 + dirY * j * g) + 0.5
		if rowBest <= bestScore + 1e-12 then break end
		for i = 0, nx do
			p.x, p.y = -pitch.halfWidth + i * g, y0 + dirY * j * g
			if rowBest - 0.01 * math.abs(p.x) > bestScore + 1e-12 and raising.inBounds(p, ctx.half)
				and (clearSpot(p.x, p.y, ctx) or raising.punishmentCheck(p, ctx)) then
				local sp = spread(p, ctx)
				if sp > 1 then sp = 1 end
				local s = pitch.fromBaseline(far, p.y) + 0.5 * sp - 0.01 * math.abs(p.x)
				if s > bestScore + 1e-12 then bx, by, bestScore = p.x, p.y, s end
			end
		end
	end
	if not bx then return nil end
	return { x = bx, y = by, standing = true, angle = 0 }
end

tw.raising = raising
