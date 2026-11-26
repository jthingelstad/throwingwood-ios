-- The throw to go (1.4.0; docs/notes/rules-engine.md "The throw to go"): before turn 1,
-- each team throws one baton from its own baseline at the king. The baton that comes to
-- rest closest to the king without toppling it wins, and its team throws first.
-- Touching the king is fine. A team that topples the king loses it: the other team
-- throws first. Both topple it, or a tie: both throw again. Pure Lua: no playdate.*.
--
-- The two batons are blind and simultaneous: each is thrown on its own world, the pitch
-- as the match sets it up (nothing else on it), so which arrives first does not matter
-- and one baton never moves the other or the king the other is measured to.
--
--   togo.gap(res, batonId)      -> m from the baton at rest to the king (0: touching), toppled
--   togo.decide({ A = { gap, toppled }, B = { gap, toppled } })
--                               -> { first = "A" | "B" | nil, how = "closer" | "king" | "again",
--                                    why = "tie" | "both king" | nil }
--   togo.target(level)          -> the view-frame point a thrower of that level aims at
--   togo.cpuThrow(setup, r, level, scale) -> the computer's baton (autothrow.choose's shape)
--
-- The distance (togo.gap): the nearest part of the baton at rest to the king. The baton
-- is its axis (a segment of the body's length, its two caps' centres) with its radius;
-- the king is taken as the circle of its half side round the king's centre where it
-- stands at rest. The gap is the horizontal distance from the segment to the king's
-- centre, less the two radii, never below 0 (a baton that touches the king, or lies
-- under its edge, is 0). It is rounded to whole millimetres before the two are
-- compared: equal millimetres are a tie. A baton is measured wherever it rests (off the
-- pitch too), and a helicopter counts as thrown: neither is in the rules of the throw
-- to go, only in a turn's.
import "core/tw"
import "core/pitch"
import "core/body"
import "core/throwplan"
import "core/autothrow"

local pitch, plan = tw.pitch, tw.plan
local sqrt, max, min, floor = math.sqrt, math.max, math.min, math.floor

local togo = {}

togo.tune = {
	-- where a thrower aims (view frame: its baseline at y = 0, the king at y = 4): this
	-- far short of the king's centre, down the middle, on the ground. A baton aimed at the
	-- ground lands there and runs on toward the king; aimed at the king it fells it. A
	-- person's circle starts here (they may move it); the computer aims here by level.
	-- Chosen in the Gym's way (tests/lua/session/test_togo.lua "the computer topples the
	-- king no more often than a person"): the computer's topple rate at each level stays
	-- under a person's at the same spot on the meter of the same standing.
	markerShort = 1.4,                        -- m: a person's starting circle
	arc = true,                               -- a person's baton starts on togo.arc()
	short = { kid = 1.4, beginner = 1.25, club = 1.25, pro = 1.4 }, -- m: the computer's aim by level
}

-- The release a baton to go is thrown at (degrees): the baton's arc at the far knot
-- (plan.arcFor with no distance), the arc the computer throws it on and a person's
-- starts on, a lob that lands and stops rather than the low line that skids.
function togo.arc()
	return plan.arcFor("baton")
end

-- The point a thrower of `level` aims at, view frame: x, y.
function togo.target(level)
	local t = togo.tune
	local s = t.short[level] or t.markerShort
	return pitch.king.x, pitch.king.y - s
end

-- The gap from the baton at rest to the king (see the head), and whether the king
-- toppled: res is core/world's result (phys.result: bodies by id, toppled ids).
function togo.gap(res, batonId)
	local b, k = res.bodies[batonId], res.bodies.king
	local toppled = false
	for _, id in ipairs(res.toppled or {}) do if id == "king" then toppled = true end end
	if k and k.toppled then toppled = true end
	if not (b and k) then return math.huge, toppled end
	local kb = tw.body.kinds.baton
	local qw, qx, qy, qz = b.qw, b.qx, b.qy, b.qz
	-- the body's long axis: column 3 of its rotation
	local ax, ay = 2 * (qx * qz + qw * qy), 2 * (qy * qz - qw * qx)
	local x0, y0 = b.x - ax * kb.hl, b.y - ay * kb.hl
	local x1, y1 = b.x + ax * kb.hl, b.y + ay * kb.hl
	local dx, dy = x1 - x0, y1 - y0
	local L2 = dx * dx + dy * dy
	local u = 0
	if L2 > 1e-12 then u = max(0, min(1, ((k.x - x0) * dx + (k.y - y0) * dy) / L2)) end
	local px, py = x0 + dx * u, y0 + dy * u
	local d = sqrt((k.x - px) ^ 2 + (k.y - py) ^ 2) - kb.r - pitch.kingSide / 2
	if d < 0 then d = 0 end
	return d, toppled
end

-- A gap in whole millimetres (the unit two batons are compared in).
function togo.mm(gap)
	if gap == math.huge then return gap end
	return floor(gap * 1000 + 0.5)
end

-- The verdict for both batons: e = { A = { gap, toppled }, B = { gap, toppled } }.
function togo.decide(e)
	local a, b = e.A, e.B
	if a.toppled and b.toppled then return { how = "again", why = "both king" } end
	if a.toppled then return { first = "B", how = "king" } end
	if b.toppled then return { first = "A", how = "king" } end
	local ga, gb = togo.mm(a.gap), togo.mm(b.gap)
	if ga == gb then return { how = "again", why = "tie" } end
	return { first = ga < gb and "A" or "B", how = "closer" }
end

-- The computer's baton (autothrow.choose's shape: x, y, swivel, loftDeg, speed,
-- tumbleRate, tilt, legal, plan, swing, launch) for the throw to go from setup `s` (a
-- match setup for its side: core/match togoSetup), seeded by r, at `level` (the thrower's
-- level, autothrow's when nil): from the middle of its baseline at togo.target(level),
-- on the ground, the level's arc, with its swing's mistakes and nerves as any baton of
-- that level (autothrow.tune.swingScale, its nerves). scale multiplies the mistakes as
-- choose's does. Always draws the same number of values from r.
function togo.cpuThrow(s, r, level, scale)
	local at = tw.autothrow
	local lname = level or (s.thrower and s.thrower.level) or at.tune.level
	if not plan.levels[lname] then lname = at.tune.level end
	scale = (scale or 1) * (at.tune.swingScale[lname] or 1)
	local tx, ty = togo.target(lname)
	local q = { level = at.cpuLevel(lname), surface = s.surface, projectile = "baton", aimZ = 0,
		px = 0, py = s.lineY or 0, tx = tx, ty = ty, release = togo.arc() }
	local sol = plan.solve(q, {})
	local sw = at.swing(sol, r, scale, {})
	local L = plan.launch(sol, sw, { projectile = "baton", tilt = 0, nerves = scale > 0 and r or nil }, {})
	return { x = q.px, y = q.py, swivel = L.swivel, loftDeg = L.loft, speed = L.speed, tumbleRate = L.tumble,
		tilt = L.tilt, legal = L.legal, plan = sol, swing = sw, launch = L, on = nil, tx = tx, ty = ty }
end

-- The words for a verdict (the game file's [Engine:first], the session's text): e as
-- decide's, v its verdict, rounds how many rounds it took.
function togo.text(e, v, rounds)
	local function one(side)
		local x = e[side]
		if x.toppled then return "Team " .. side .. " king down" end
		return string.format("Team %s %.2f m", side, togo.mm(x.gap) / 1000)
	end
	local s = "throw to go: " .. one("A") .. ", " .. one("B")
	if rounds and rounds > 1 then s = s .. "; " .. rounds .. " rounds" end
	return s
end

tw.togo = togo
