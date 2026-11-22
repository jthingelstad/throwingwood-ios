-- The Tournament's neighbouring pitches (docs/notes/tournament.md, docs/SESSION.md
-- "Neighbours"): computer-against-computer matches on the pitches around the player's,
-- as live scenery, behind kubbCall("neighbours.<name>"). Pure Lua like the core.
--
--   neighbours.open    { seed, count, scene, surface, set, level | levels, layout, spacing, thin, now }
--                      -> { pitches = [{ id, offset, teams, phase, items }], stakes, ... }
--   neighbours.advance { now, budgetMs | steps } -> { events = [...], used, late }
--   neighbours.view    { id? }                  -> a pitch as it stands now (or { pitches })
--   neighbours.close   {}                       -> {}
--
-- Each pitch plays the physmatch path (tools/physmatch.lua): core/match set up by the
-- engine, core/autothrow's computer on both sides, core/world to rest through
-- core/playback. Its work runs in a coroutine of its own and is cut into slices at every
-- physics step and between the computer's decisions, so `advance` stops when its budget
-- is spent (the host's clock, `__kubbClock`, for budgetMs; a count for steps). Throws are
-- paced on the host's clock (`now`, passed in): what a pitch shows, and when, comes from
-- the seed and that clock alone, never from how the work was sliced.
--
-- Meant for a Lua state of its own (a worker running a second engine on the web, a second
-- lua_State on the iPhone), so it can never reach the player's session. It touches
-- nothing the session keeps: its matches, worlds and draws are its own.
import "core/tw"
import "core/pitch"
import "core/frame"
import "core/match"
import "core/world"
import "core/playback"
import "core/autothrow"
import "core/throwplan"
import "core/raising"
import "core/namegen"
import "core/scenes"
import "session/json"

local match, world, playback, autothrow, plan = tw.match, tw.world, tw.playback, tw.autothrow, tw.plan
local frame, pitch, namegen, scenes, json = tw.frame, tw.pitch, tw.namegen, tw.scenes, tw.web.json
local floor, max, min = math.floor, math.max, math.min
local yield, resume, create, status = coroutine.yield, coroutine.resume, coroutine.create, coroutine.status

local neighbours = {}

neighbours.tune = {
	count = 8,            -- pitches by default: the ring round the player's in a 3 x 3 grid
	maxCount = 24,        -- the two rings of a 5 x 5 grid
	spacing = { x = 8, y = 12 },   -- m between pitch origins: 5 m wide and 3 m apart; 8 m long and 4 m apart
	thin = 2,             -- a pose every thin / 50 s (2: 25 a second, enough for a far pitch)
	poseScale = 1000,     -- poses and items to the millimetre (and 0.001 of a quaternion)
	-- the levels a pitch's two teams are drawn from, by weight: most club, some beginner,
	-- a few pro, as at an open tournament (Kid is not among them)
	levels = { beginner = 3, club = 5, pro = 2 },
	players = { 3, 6 },   -- a team's size, drawn
	maxTurns = 40,        -- a match still going at this turn is resigned
	-- the pace, in seconds of the host's clock (docs/notes/tournament.md "Pacing")
	pace = {
		baton = { 8, 15 },    -- start to start of a turn's batons
		kubb = { 6, 10 },     -- start to start of the kubbs thrown in
		walk = { 20, 30 },    -- the turn's last throw at rest to the next turn's first throw
		raise = { 12, 20 },   -- the last kubb thrown in at rest to the first baton
		over = { 40, 60 },    -- the king down to the next match setting out
		setup = { 15, 25 },   -- setting out to its first throw
		stagger = { 1, 20 },  -- open to each pitch's first throw
		gap = 3,              -- at least this from a throw at rest to the next throw
		tidy = 2,             -- a throw at rest to the walk, the raise or the next thrower
		ended = 1,            -- the king down at rest to "over"
		jump = 30,            -- a jump of the host's clock longer than this moves every schedule on
	},
	-- steps mode: what each kind of work counts as, in physics steps (measured: a step is
	-- about 0.01 ms in desktop Lua, a choice 0.05, a set-up 0.04, a raise by par 0.06)
	cost = { step = 1, probe = 0.05, setup = 5, raise = 6, choose = 6, body = 3, encode = 3, resolve = 3 },
	-- time mode: the first guess at each kind's cost (ms) before it has been measured
	guess = { wrap = 0.1, step = 0.05, probe = 0.02, setup = 0.3, raise = 0.5, choose = 0.6, body = 0.3, encode = 0.3, resolve = 0.3 },
	-- time mode: each kind's cost is the worst it has been lately, forgetting `decay` of it
	-- a unit; a physics step's is the last step's (a step costs about what the one before
	-- did: a baton alone in the air, or a pile of contacts). One reading more than `spike`
	-- times the estimate (a pause of the host's, a garbage collection) moves it only that far
	decay = 0.995,
	spike = 3,
	margin = 1.5,         -- a unit starts only if this many times its estimate is left
	wrapShare = 0.25,     -- at most this share of a budget is held back for the answer's encoding
}

local LEVELS = { "beginner", "club", "pro" }

local F = nil   -- the neighbours of this Lua state (one set, like the session's S)

-- ---------- small helpers ----------

local function check(ok, why)
	if not ok then error(why, 0) end
	return ok
end

local function whole(v) return type(v) == "number" and v == floor(v) and math.abs(v) < 2 ^ 53 end

-- The session's seed mix (docs/SESSION.md "Determinism").
local function mix(seed, purpose, n)
	return ((seed * 0x9E3779B1) ~ (purpose * 0x85EBCA6B) ~ (n * 0xC2B2AE35)) & 0x7fffffff
end

local function ms(v) return floor(v * 1000 + 0.5) / 1000 end

local function between(r, range) return ms(range[1] + r.next() * (range[2] - range[1])) end

local function teamOf(id, kind)
	if kind ~= "kubb" then return nil end
	local c = id:match("^([ab])%d")
	return c and c:upper() or nil
end

-- ---------- the budget ----------
-- Work is cut at checkpoints: before each unit (a physics step, a set-up, a raise, a
-- choice, a recording's body, its encoding, the ruling), `checkpoint(kind)` measures the
-- unit before it and lets the next run only if it fits what is left. The first unit of a
-- call always runs, so a budget smaller than any unit still makes progress.

local function hostClock()
	local c = rawget(_G, "__kubbClock")
	return type(c) == "function" and c or nil
end

-- The estimate of `kind` after a unit of it took d ms.
local function learn(kind, d)
	local est, t = F.est, neighbours.tune
	local e = est[kind]
	if d > e * t.spike + 0.05 then d = e * t.spike + 0.05 end
	if kind == "step" then
		est[kind] = max(d, e * 0.7)
	elseif d > e then est[kind] = d
	else est[kind] = e * t.decay end
end

local function checkpoint(kind)
	local B = F.B
	local now
	if B.steps then
		if B.done > 0 and B.used + neighbours.tune.cost[kind] > B.steps then yield("budget") end
	else
		now = B.clock()
		if B.kind then learn(B.kind, now - B.last) end
		if B.done > 0 and now + F.est[kind] * neighbours.tune.margin > B.deadline then
			B.kind = nil
			yield("budget")
			now = nil
		end
	end
	-- the unit is counted against the call that runs it, in that call's own mode: a host
	-- may pass steps on one advance and budgetMs on the next while a pitch waits here
	B = F.B
	if B.steps then
		B.used, B.done = B.used + neighbours.tune.cost[kind], B.done + 1
	else
		B.last, B.kind, B.done = now or B.clock(), kind, B.done + 1
	end
end

-- Ends the unit in hand (time mode), before a pitch waits or the call returns.
local function settleClock()
	local B = F.B
	if B and not B.steps and B.kind then
		local now = B.clock()
		learn(B.kind, now - B.last)
		B.kind = nil
	end
end

-- Each spot core/raising tries for a kubb raised in a crowded corner (raising.probe, set
-- only while a pitch's coroutine runs).
local function probe() checkpoint("probe") end

-- world.run (core/world) a step at a time with a checkpoint before each: the same steps
-- in the same order. Given to core/match as m.run for settling standing pieces.
local function slicedRun(w)
	local stop = w.time + world.tune.maxTime
	while not world.isAtRest(w) and w.time < stop - 1e-9 do
		checkpoint("step")
		world.step(w)
	end
	return w
end

-- ---------- the pitch frame ----------
-- Everything a neighbour gives is in its pitch's own frame, Team A's (core/frame's world
-- frame): Team A's baseline at y = 0, Team B's at y = 8, x across. The session's
-- set-ups are in the thrower's view frame, so a Team B throw is turned here.

local K -- poseScale, set by open

local function itemOf(b, side)
	local x, y = frame.point(side, b.x, b.y)
	local qw, qx, qy, qz = frame.quat(side, b.qw, b.qx, b.qy, b.qz)
	return { id = b.id, kind = b.kind, team = teamOf(b.id, b.kind),
		x = floor(x * K + 0.5) / K, y = floor(y * K + 0.5) / K, z = floor(b.z * K + 0.5) / K,
		qw = floor(qw * K + 0.5) / K, qx = floor(qx * K + 0.5) / K, qy = floor(qy * K + 0.5) / K,
		qz = floor(qz * K + 0.5) / K, toppled = b.toppled and true or false }
end

-- The pitch as world w holds it before the throw (no stakes: `open` gives them once).
local function itemsOf(w, side)
	local out = {}
	for i = 1, w.n do
		local b = w.bodies[i]
		if b.kind ~= "stake" then out[#out + 1] = itemOf(b, side) end
	end
	return out
end

local function sameItems(a, b)
	if #a ~= #b then return false end
	local by = {}
	for _, it in ipairs(b) do by[it.id] = it end
	for _, it in ipairs(a) do
		local o = by[it.id]
		if not o or o.toppled ~= it.toppled then return false end
		for _, k in ipairs { "x", "y", "z", "qw", "qx", "qy", "qz" } do
			if math.abs(o[k] - it[k]) > 1.5 / K then return false end
		end
	end
	return true
end

local function copyItems(list)
	local out = {}
	for i, it in ipairs(list) do
		local c = {}
		for k, v in pairs(it) do c[k] = v end
		out[i] = c
	end
	return out
end

-- ---------- a pitch's matches ----------

local function drawLevel(r)
	local L = F.levels
	if L.one then return L.one end
	local x = r.next() * L.total
	for _, name in ipairs(LEVELS) do
		local wgt = L.weights[name] or 0
		if x < wgt then return name end
		x = x - wgt
	end
	return L.last
end

local function rand(r)
	return function(n)
		local k = floor(r.next() * n) + 1
		if k > n then k = n end
		return k
	end
end

-- A new match on pitch P: its teams (generated names, core/namegen), their levels and
-- sizes, the match, and its first throw set up (match.setup) with the pitch as it stands.
local function newMatch(P)
	P.matchNo = P.matchNo + 1
	local key = P.id * 4096 + P.matchNo
	local seed = F.seed
	local lr = plan.rng(mix(seed, 14, key))
	local nr = rand(plan.rng(mix(seed, 13, key)))
	local t = neighbours.tune
	local teams, levels = {}, {}
	for _, side in ipairs { "A", "B" } do
		local name = namegen.roll("team", nr)
		if side == "B" then
			for _ = 1, 8 do
				if name ~= teams.A.name then break end
				name = namegen.roll("team", nr)
			end
		end
		local level = drawLevel(lr)
		local size = t.players[1] + floor(lr.next() * (t.players[2] - t.players[1] + 1))
		if size > t.players[2] then size = t.players[2] end
		local ps = {}
		for j = 1, size do ps[j] = { name = "Player " .. j, level = level } end
		teams[side] = { name = name, players = ps }
		levels[side] = level
	end
	local first = (lr.next() < 0.5) and "A" or "B"
	local m = match.new { surface = scenes.surfaceName[F.surface], first = first, teams = teams, cpu = { "A", "B" } }
	m.run = slicedRun
	m.raising = {}
	for _, side in ipairs { "A", "B" } do
		local level = levels[side]
		m.raising[side] = function(dec, ctx)
			checkpoint("raise")
			return tw.cpu.raise(dec, ctx, level)
		end
	end
	P.m = m
	P.levels = levels
	P.teams = {
		A = { name = teams.A.name, level = levels.A, players = #teams.A.players },
		B = { name = teams.B.name, level = levels.B, players = #teams.B.players },
	}
	P.first = first
	P.throwRng = plan.rng(mix(seed, 11, key))
	P.paceRng = plan.rng(mix(seed, 12, key))
end

-- The next throw set up: { s, w, items }.
local function setUp(P)
	checkpoint("setup")
	local s = match.setup(P.m)
	if not s then return nil end
	local w = world.new { surface = s.surface or "grass", pieces = match.worldPieces(s) }
	return { s = s, w = w, items = itemsOf(w, s.side) }
end

-- A finished throw (world w, its playback pb, thrown by `side`) as a neighbour's
-- recording, in the pitch frame: only the bodies that moved, each from its first moving
-- frame to its last frame that differs from the one before (after it a body stays where
-- its last pose has it, as in the session's recording), poses `thin` frames of 1/50 s
-- apart at poseScale. Returns the recording table (poses as integer lists) and its
-- last frame.
local function recordingOf(w, pb, side)
	local bodies, last = {}, 0
	local B = side == "B"
	local L = pitch.length
	for i = 1, w.n do
		local bd = w.bodies[i]
		local r = pb.rec[i]
		if bd.kind ~= "stake" and r.start >= 0 then
			checkpoint("body")
			local d, ints = r.data, {}
			local nf = #d // 7
			local n = 0
			for f = 0, nf - 1 do
				local k = f * 7
				local x, y, z, qw, qx, qy, qz = d[k + 1], d[k + 2], d[k + 3], d[k + 4], d[k + 5], d[k + 6], d[k + 7]
				if B then
					x, y = -x, L - y
					qw, qx, qy, qz = -qz, -qy, qx, qw
				end
				ints[n + 1], ints[n + 2], ints[n + 3] = floor(x * K + 0.5), floor(y * K + 0.5), floor(z * K + 0.5)
				ints[n + 4], ints[n + 5] = floor(qw * K + 0.5), floor(qx * K + 0.5)
				ints[n + 6], ints[n + 7] = floor(qy * K + 0.5), floor(qz * K + 0.5)
				n = n + 7
			end
			-- trailing frames that repeat the one before carry nothing
			local frames = nf
			while frames > 1 do
				local a, b = (frames - 1) * 7, (frames - 2) * 7
				local same = true
				for j = 1, 7 do
					if ints[a + j] ~= ints[b + j] then same = false; break end
				end
				if not same then break end
				frames = frames - 1
			end
			for j = #ints, frames * 7 + 1, -1 do ints[j] = nil end
			local e = r.start + frames - 1
			if e > last then last = e end
			bodies[#bodies + 1] = { id = bd.id, kind = bd.kind, team = teamOf(bd.id, bd.kind), start = r.start,
				frames = frames, ints = ints, toppleT = bd.toppleT and ms(bd.toppleT) or nil,
				toppled = bd.toppled and true or false }
		end
	end
	return bodies, last
end

-- The items after a recording: each moved body at its last pose (new bodies added).
local function bake(items, bodies)
	local out = copyItems(items)
	local at = {}
	for i, it in ipairs(out) do at[it.id] = i end
	for _, b in ipairs(bodies) do
		local j = (b.frames - 1) * 7
		local p = b.ints
		local it = { id = b.id, kind = b.kind, team = b.team, x = p[j + 1] / K, y = p[j + 2] / K, z = p[j + 3] / K,
			qw = p[j + 4] / K, qx = p[j + 5] / K, qy = p[j + 6] / K, qz = p[j + 7] / K, toppled = b.toppled }
		if at[b.id] then
			it.toppled = out[at[b.id]].toppled or b.toppled
			out[at[b.id]] = it
		else
			out[#out + 1] = it
			at[b.id] = #out
		end
	end
	return out
end

local function queue(P, beat)
	P.queue[#P.queue + 1] = beat
end

-- A pitch's work, in its own coroutine: set up, choose, simulate, record, rule, and
-- schedule, one throw at a time, never more than one throw ahead of what is shown.
local function pitchLoop(P)
	local t = neighbours.tune
	local pace = t.pace
	local frameDt = F.frameDt
	local zero = function() return 0 end
	while true do
		while P.ahead > 0 do
			settleClock()
			yield("idle")
		end
		local u = P.next   -- the throw set up already (open, or a new match)
		P.next = nil
		if not u then u = setUp(P) end
		local s, w, items = u.s, u.w, u.items
		-- the beat before this throw: the walk, the raise, the next thrower, or a match
		-- setting out; with the pitch as it now stands when that differs from what shows
		local pre = P.pre
		if pre then
			if pre.phase ~= "aim" or not sameItems(items, P.lastItems) then
				pre.items = items
			end
			if pre.phase == "setup" then pre.teams = P.teams end
			queue(P, pre)
			P.pre = nil
		end
		P.lastItems = items
		checkpoint("choose")
		local a = autothrow.choose(s, P.throwRng, nil, P.levels[s.side])
		autothrow.launch(w, s, a)
		local pb = playback.new(w, frameDt)
		while not pb.done do
			checkpoint("step")
			playback.advance(pb, 0, zero)
		end
		local bodies, last = recordingOf(w, pb, s.side)
		checkpoint("encode")
		local list = {}
		for i, b in ipairs(bodies) do
			list[i] = { id = b.id, kind = b.kind, team = b.team, start = b.start, frames = b.frames,
				poses = json.raw("[" .. table.concat(b.ints, ",") .. "]"), toppleT = b.toppleT }
		end
		local res = world.result(w)
		local proj = w.projectile
		local rec = { frameDt = frameDt, frames = last, duration = ms(last * frameDt), poseScale = K,
			projectile = { id = proj.id, kind = proj.kind }, bodies = list }
		local text = json.encode(rec)
		local after = bake(items, bodies)
		checkpoint("resolve")
		local turn, side = P.m.game.turn, s.side
		match.resolve(P.m, res, not a.legal)
		if not match.over(P.m) and P.m.game.turn > t.maxTurns then match.resign(P.m) end
		local fx, fy = frame.point(side, a.x, a.y)
		local at = P.at
		local stop = at + rec.duration
		queue(P, { phase = "throw", at = at, side = side, kind = s.kind == "toss" and "kubb" or "baton",
			from = { x = ms(fx), y = ms(fy) }, recording = json.raw(text),
			down = #res.toppled, king = res.kingToppled or nil, after = after, stop = stop })
		P.lastItems = after
		P.ahead = P.ahead + 1
		local r = P.paceRng
		if match.over(P.m) then
			local g = P.m.game
			queue(P, { phase = "over", at = ms(stop + pace.ended), winner = g.winner, how = g.how })
			local setupAt = ms(stop + between(r, pace.over))
			newMatch(P)
			r = P.paceRng
			P.next = setUp(P)
			P.pre = { phase = "setup", at = setupAt }
			P.at = ms(setupAt + between(r, pace.setup))
		else
			local n = P.m.game:need()
			-- the turn over: the walk; the kubbs thrown in and the batons next (the raise,
			-- and any punishment kubb): the raise; else the next thrower steps up
			local phase = "aim"
			if P.m.game.turn ~= turn then phase = "walk"
			elseif s.kind == "toss" and n.kind ~= "toss" then phase = "raise" end
			P.pre = { phase = phase, at = ms(stop + pace.tidy) }
			if phase == "walk" then P.at = ms(stop + between(r, pace.walk))
			elseif phase == "raise" then P.at = ms(stop + between(r, pace.raise))
			else
				local gap = between(r, s.kind == "toss" and pace.kubb or pace.baton)
				P.at = ms(at + max(gap, rec.duration + pace.gap))
			end
		end
	end
end

-- ---------- open ----------

local function layout(kind, count)
	local cells = {}
	if kind == "row" then
		for k = 1, count do
			local c = (k + 1) // 2
			cells[k] = { c = (k % 2 == 1) and -c or c, r = 0 }
		end
		return cells
	end
	for ring = 1, 2 do
		local ringCells = {}
		for r = -ring, ring do
			for c = -ring, ring do
				if max(math.abs(r), math.abs(c)) == ring then ringCells[#ringCells + 1] = { c = c, r = r } end
			end
		end
		-- the pitches beside the player's first, then ahead and behind, then the corners
		table.sort(ringCells, function(p, q)
			if math.abs(p.r) ~= math.abs(q.r) then return math.abs(p.r) < math.abs(q.r) end
			if math.abs(p.c) ~= math.abs(q.c) then return math.abs(p.c) < math.abs(q.c) end
			if p.c ~= q.c then return p.c < q.c end
			return p.r < q.r
		end)
		for _, cell in ipairs(ringCells) do cells[#cells + 1] = cell end
	end
	for k = #cells, count + 1, -1 do cells[k] = nil end
	return cells
end

local function pitchOut(P)
	return { id = P.id, offset = P.offset, teams = P.shown.teams, phase = P.shown.phase,
		at = P.shown.at, items = P.shown.items }
end

function neighbours.open(a)
	a = a or {}
	local t = neighbours.tune
	local seed = a.seed == nil and 1 or a.seed
	check(whole(seed), "neighbours.open: seed is a whole number")
	local count = a.count == nil and t.count or a.count
	check(whole(count) and count >= 1 and count <= t.maxCount, "neighbours.open: count is 1 to " .. t.maxCount)
	local kind = a.layout or "grid"
	check(kind == "grid" or kind == "row", "neighbours.open: layout is \"grid\" or \"row\"")
	check(kind ~= "grid" or count <= 24, "neighbours.open: a grid holds at most 24")
	local thin = a.thin == nil and t.thin or a.thin
	check(thin == 1 or thin == 2 or thin == 3, "neighbours.open: thin is 1, 2 or 3")
	local now = a.now == nil and 0 or a.now
	check(type(now) == "number" and now == now, "neighbours.open: now is a number of seconds")
	local sp = a.spacing or {}
	local sx, sy = sp.x or t.spacing.x, sp.y or t.spacing.y
	check(type(sx) == "number" and sx >= 2 * pitch.halfWidth + 0.5 and type(sy) == "number" and sy >= pitch.length + 0.5,
		"neighbours.open: spacing keeps pitches apart (x at least 5.5, y at least 8.5)")
	local levels
	if a.level ~= nil then
		check(a.level == "beginner" or a.level == "club" or a.level == "pro",
			"neighbours.open: level is \"beginner\", \"club\" or \"pro\"")
		levels = { one = a.level }
	else
		local wts = a.levels or t.levels
		check(type(wts) == "table", "neighbours.open: levels is { beginner, club, pro } weights")
		local total, lastName = 0, nil
		for k, v in pairs(wts) do
			check(k == "beginner" or k == "club" or k == "pro", "neighbours.open: levels takes beginner, club and pro")
			check(type(v) == "number" and v >= 0, "neighbours.open: a level's weight is a number, 0 or more")
		end
		for _, name in ipairs(LEVELS) do
			local v = wts[name] or 0
			total = total + v
			if v > 0 then lastName = name end
		end
		check(total > 0, "neighbours.open: levels needs a weight above 0")
		levels = { weights = wts, total = total, last = lastName }
	end
	local scene, surface, set = scenes.resolve(a.scene or "tournament", a.surface, a.set)
	F = {
		seed = floor(seed), count = floor(count), scene = scene, surface = surface, set = set,
		frameDt = thin / 50, thin = thin, levels = levels, now = now, lastNow = now,
		pitches = {}, est = {},
	}
	for k, v in pairs(t.guess) do F.est[k] = v end
	K = t.poseScale
	-- open's own work (each first throw set up) is not sliced: a count with no budget
	F.B = { steps = math.huge, used = 0, done = 0 }
	local cells = layout(kind, F.count)
	local out = {}
	for i, cell in ipairs(cells) do
		local P = { id = i, offset = { x = cell.c * sx, y = cell.r * sy }, matchNo = 0, ahead = 0, queue = {},
			shift = 0 }
		newMatch(P)
		local u = setUp(P)
		P.next = u
		P.lastItems = u.items
		local sr = plan.rng(mix(F.seed, 15, P.id))
		P.at = ms(now + between(sr, t.pace.stagger))
		P.shown = { phase = "setup", at = now, items = u.items, teams = P.teams }
		P.co = create(pitchLoop)
		F.pitches[i] = P
		out[i] = pitchOut(P)
	end
	F.B = nil
	local stakes = {}
	for i, st in ipairs(pitch.stakes) do stakes[i] = { x = st.x, y = st.y } end
	return { pitches = out, seed = F.seed, count = F.count, scene = scene, surface = surface, set = set,
		frameDt = F.frameDt, poseScale = K, stakes = stakes, stakeHeight = world.tune.stakeHeight, now = now }
end

-- ---------- advance ----------

local function need()
	check(F, "neighbours: call neighbours.open first")
	return F
end

-- Beats of every pitch that are due at `now`, in order, onto `events`.
local function emit(now, events)
	for _, P in ipairs(F.pitches) do
		local q = P.queue
		while q[1] and q[1].at + P.shift <= now do
			local b = table.remove(q, 1)
			local at = ms(b.at + P.shift)
			local e = { id = P.id, phase = b.phase, at = at }
			local sh = P.shown
			if b.phase == "throw" then
				P.ahead = P.ahead - 1
				e.side, e.kind, e.from, e.recording = b.side, b.kind, b.from, b.recording
				e.down, e.king = b.down, b.king
				sh.rec, sh.recAt, sh.recEnd, sh.after = b.recording, at, ms(b.stop + P.shift), b.after
				sh.side, sh.kind, sh.from = b.side, b.kind, b.from
			else
				-- a beat between throws: a recording still playing has ended by now
				if sh.rec then sh.items, sh.rec = sh.after, nil end
				e.items = b.items
				if b.items then sh.items = b.items end
				if b.teams then e.teams, sh.teams = b.teams, b.teams end
				if b.winner then e.winner, e.how = b.winner, b.how end
			end
			sh.phase, sh.at = b.phase, at
			events[#events + 1] = e
		end
	end
end

local function urgent()
	local best = nil
	for _, P in ipairs(F.pitches) do
		if P.ahead == 0 and status(P.co) ~= "dead" then
			if not best or P.at + P.shift < best.at + best.shift then best = P end
		end
	end
	return best
end

function neighbours.advance(a)
	need()
	a = a or {}
	local now = a.now
	check(type(now) == "number" and now == now, "neighbours.advance: now is a number of seconds")
	check(now >= F.now, "neighbours.advance: now goes forward")
	local t = neighbours.tune
	-- a jump of the host's clock (the app was asleep): the neighbours pick up where they were
	if now - F.lastNow > t.pace.jump then
		local d = now - F.lastNow
		for _, P in ipairs(F.pitches) do P.shift = P.shift + d end
	end
	F.lastNow, F.now = now, now
	local B
	if a.steps ~= nil then
		check(whole(a.steps) and a.steps >= 0, "neighbours.advance: steps is a whole number, 0 or more")
		B = { steps = a.steps, used = 0, done = 0 }
	else
		local budget = a.budgetMs
		check(type(budget) == "number" and budget >= 0, "neighbours.advance: budgetMs or steps")
		local clock = hostClock()
		check(clock, "neighbours.advance: budgetMs needs the host's clock (__kubbClock, milliseconds); or pass steps")
		local t0 = clock()
		local hold = min(F.est.wrap, budget * t.wrapShare)
		B = { clock = clock, deadline = t0 + budget - hold, start = t0, done = 0 }
	end
	F.B = B
	local events = {}
	emit(now, events)
	if (B.steps or a.budgetMs) > 0 then
		while true do
			local P = urgent()
			if not P then break end
			if not B.steps and B.done > 0 and B.clock() >= B.deadline then break end
			-- the crowded corner's search (core/raising) yields too, while this pitch runs
			tw.raising.probe = probe
			local ok, why = resume(P.co, P)
			tw.raising.probe = nil
			if not ok then
				F.B = nil
				error(why, 0)
			end
			if why == "budget" then break end
		end
		settleClock()
	end
	local workEnd = not B.steps and B.clock()
	emit(now, events)
	local late = 0
	for _, P in ipairs(F.pitches) do
		if P.ahead == 0 and P.at + P.shift <= now then late = late + 1 end
	end
	local used
	if B.steps then used = { steps = B.used }
	else
		local t1 = B.clock()
		used = { ms = t1 - B.start }
		F.tail = t1 - workEnd   -- the emission after the work: held back with the encoding
	end
	F.B = nil
	return { now = now, events = events, used = used, late = late }
end

-- ---------- view and close ----------

local function viewOf(P)
	local sh = P.shown
	if sh.rec and F.now >= sh.recEnd then
		sh.items, sh.rec = sh.after, nil
		sh.phase, sh.at = "rest", sh.recEnd
	end
	local out = { id = P.id, offset = P.offset, teams = sh.teams, phase = sh.phase, at = sh.at, items = sh.items }
	if sh.rec then
		out.recording, out.side, out.kind, out.from, out.at = sh.rec, sh.side, sh.kind, sh.from, sh.recAt
	end
	return out
end

function neighbours.view(a)
	need()
	if a and a.id ~= nil then
		local P = F.pitches[a.id]
		check(whole(a.id) and P, "neighbours.view: no pitch " .. tostring(a.id))
		return viewOf(P)
	end
	local out = {}
	for i, P in ipairs(F.pitches) do out[i] = viewOf(P) end
	return { now = F.now, pitches = out }
end

function neighbours.close()
	F = nil
	return json.object()
end

-- kubbCall("neighbours.<name>", argJson): session/api routes here.
local CALLS = { open = neighbours.open, advance = neighbours.advance, view = neighbours.view, close = neighbours.close }

function neighbours.call(name, arg)
	local f = CALLS[name]
	if not f then error("unknown call neighbours." .. tostring(name), 0) end
	local a = nil
	if arg and arg ~= "" then a = json.decode(arg) end
	local r = f(a)
	if r == nil then r = json.object() end
	-- advance's answer is encoded after its budget closed: that time is kept (est.wrap) and
	-- held back from the next call's budget, so the whole call stays inside it
	local clock = name == "advance" and F and a and a.budgetMs and hostClock()
	if not clock then return json.encode(r) end
	local t0 = clock()
	local text = json.encode(r)
	learn("wrap", clock() - t0 + (F.tail or 0))
	return text
end

tw.web = tw.web or {}
tw.web.neighbours = neighbours
