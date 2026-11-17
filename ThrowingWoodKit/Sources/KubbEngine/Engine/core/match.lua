-- A match: the rules engine (core/rules) driven by physics throws, as the
-- match scene plays it. Pure Lua: no playdate.*. Not a per-frame path.
--
-- The engine is the truth for the layout between throws; physics is the
-- truth during a throw. match.setup says what the next throw is and gives
-- the pitch as physics pieces in the thrower's view frame (core/frame: the
-- thrower always throws from y = 0 toward +y); match.resolve takes the
-- finished physics throw, turns it into the engine's outcome record
-- (core/outcome) and applies it. Raising and punishment placement are
-- automatic (the engine's policies) and happen in match.setup.
--
--   local m = match.new{ surface = "Grass", start = {year, month, day, hour, min} }
--   while not match.over(m) do
--     local s = match.setup(m)          -- s.kind "toss" | "baton"
--     ... build tw.world from s.pieces, launch s.projectile, run to rest ...
--     match.resolve(m, tw.world.result(w), illegal)   -- m.text says what happened
--   end
--   local text, name = match.file(m, finish, version)
--
-- Everything a resume needs (stage 5) is in the one table m: the engine
-- game (plain fields and a metatable), the start time, the surface, the
-- per-turn counters and the throwing order.
--
-- Teams have 1 to 6 players (match.new's `teams`, the engine's). Who throws
-- each kubb and baton is core/order's (docs/PLAYERS.md section 5): blocks
-- dealt round each team within Rules V4.0 II.A.4 and II.B.5, one inkaster a
-- turn; match.setup names the thrower (s.thrower) and match.resolve gives
-- the engine that player's id.
import "core/tw"
import "core/rules"
import "core/notation"
import "core/frame"
import "core/outcome"
import "core/debris"
import "core/order"
import "core/world"
import "core/body"

local rules, notation, frame, outcome, debris = tw.rules, tw.notation, tw.frame, tw.outcome, tw.debris
local order, world, body, pitch = tw.order, tw.world, tw.body, tw.pitch
local fmt = string.format

local match = {}

-- A team's name: the engine's (match.new's `teams`), "Team A" / "Team B"
-- when no game is given.
function match.teamName(side, g)
	local t = g and g.teams and g.teams[side]
	return t and t.name or ("Team " .. side)
end

-- Each engine player's saved player and throw level, from the teams given
-- to match.new (core/lineup's: { name, key, level, guest }), by side and in
-- order: { A = { { id, key, level, guest } }, B = ... }. rules.new keeps the
-- players in order, so the two lists line up.
function match.lineupOf(g, teams)
	local out = {}
	for _, side in ipairs { "A", "B" } do
		local given = teams and teams[side] and teams[side].players or {}
		local list = {}
		for i, p in ipairs(g.teams[side].players) do
			local q = given[i] or {}
			list[i] = { id = p.id, key = q.key, level = q.level, guest = q.guest or nil }
		end
		out[side] = list
	end
	return out
end

-- A player's lineup entry by id ({ id, key, level, guest }), or nil.
function match.member(m, side, id)
	for _, e in ipairs(m.lineup and m.lineup[side] or {}) do
		if e.id == id then return e end
	end
	return nil
end

function match.new(opts)
	opts = opts or {}
	local g = rules.new {
		teams = opts.teams or {
			A = { name = "Team A", players = { { name = "Player A", id = "a" } } },
			B = { name = "Team B", players = { { name = "Player B", id = "b" } } },
		},
		surface = opts.surface or "Grass", opening = opts.opening or "2-4-6", first = opts.first or "A",
	}
	return {
		game = g,
		start = opts.start,       -- {year, month, day, hour, min}
		mode = opts.mode or "Pass and Play",
		turn = g.turn,            -- the turn the counters below belong to
		tossed = 0,               -- kubbs thrown (and rethrown) this turn
		text = nil,               -- what the last throw (or the automatic steps) did
		settled = nil,            -- raised and punishment kubbs placed before this throw
		setup = nil,              -- the current throw (match.setup)
		debris = debris.new(),    -- batons and downed kubbs lying on the pitch this turn
		order = order.new(g.teams),   -- who throws (core/order)
		lineup = match.lineupOf(g, opts.teams),   -- each player's roster key and level
	}
end

-- The order (a match saved before it had one gets a fresh one).
local function orderOf(m)
	if not m.order then m.order = order.new(m.game.teams) end
	return m.order
end

-- A player of the engine's team `side` by id: { id, name }.
function match.player(m, side, id)
	for _, p in ipairs(m.game.teams[side].players) do
		if p.id == id then return p end
	end
	return nil
end

-- Who throws next: { id, name } of the attacking team's player (nil when
-- the game is over).
function match.thrower(m)
	local g = m.game
	local pid = order.thrower(orderOf(m), g)
	if not pid then return nil end
	local p = match.player(m, g.attacker, pid)
	local e = match.member(m, g.attacker, pid)
	return { id = pid, name = p and p.name or pid, key = e and e.key, level = e and e.level }
end

-- Hand the throw set up (m.setup) to another player of its team: the kubbs
-- (the inkaster, core/order.setInkaster) or this baton (core/order.change).
-- Returns ok, why ("team", "cap", "distinct"); on ok m.setup.thrower is the
-- new player's.
function match.changeThrower(m, pid)
	local s, g = m.setup, m.game
	if not s then return false, "none" end
	local o = orderOf(m)
	local ok, why
	if s.kind == "toss" then ok, why = order.setInkaster(o, pid)
	else ok, why = order.change(o, s.n, pid, s.n - 1) end
	if ok then s.thrower = match.thrower(m) end
	return ok, why
end

-- Who may take the throw set up, for the change list: every player of the
-- team, in order, { id, name, ok, why } (why as match.changeThrower's).
function match.candidates(m)
	local s, g = m.setup, m.game
	local out = {}
	if not s then return out end
	local o = orderOf(m)
	for _, p in ipairs(g.teams[s.side].players) do
		local ok, why
		if s.kind == "toss" then ok = true else ok, why = order.allowed(o, s.n, p.id, s.n - 1) end
		out[#out + 1] = { id = p.id, name = p.name, ok = ok and true or false, why = why,
			current = s.thrower and s.thrower.id == p.id }
	end
	return out
end

-- This turn's batons by player, in order: { { id, name, n }, ... } (runs of
-- one player together), for the hand-off card.
function match.turnOrder(m)
	local g = m.game
	local o = orderOf(m)
	order.sync(o, g)
	local out = {}
	for _, pid in ipairs(o.deal or {}) do
		local last = out[#out]
		if last and last.id == pid then last.n = last.n + 1
		else
			local p = match.player(m, o.side, pid)
			out[#out + 1] = { id = pid, name = p and p.name or pid, n = 1 }
		end
	end
	return out, o.inkaster and match.player(m, o.side, o.inkaster)
end

function match.over(m) return m.game.phase == "over" end

local function countTurn(m)
	if m.game.turn ~= m.turn then m.turn, m.tossed = m.game.turn, 0 end
end

-- Raise every lying kubb and place every punishment kubb (automatically,
-- with the engine's policies). Returns how many of each.
function match.settle(m)
	local g = m.game
	local raised, punished = 0, 0
	while true do
		local n = g:need()
		if n.kind == "raise" then
			g:raise(nil)
			raised = raised + 1
		elseif n.kind == "punish" then
			g:autoPunishment()
			punished = punished + 1
		else
			break
		end
	end
	return raised, punished
end

-- The next throw, in the thrower's view frame:
--   kind        "toss" | "baton"
--   side        the attacker ("A" | "B")
--   projectile  "kubb" | "baton"; kubb = the id of the kubb thrown
--   pieces      outcome.pieces: what is on the pitch (view frame)
--   lineY       the baseline (0)
--   forwardY    how far forward the thrower may stand: the advantage line
--               for batons at kubbs when there is one, else the baseline
--   advY        the advantage line to draw (view frame), or nil
--   targets     ids to frame: standing field kubbs, else base kubbs, else
--               the king (batons); nil for a toss
--   n, of       this throw's number and the throws of its kind this turn
--   label       "Team A  baton 2 of 6", "Team B  kubb 1 of 3"
--   debris      core/debris pieces: the batons thrown and the kubbs knocked
--               down earlier this turn, lying where they came to rest (view
--               frame; physics bodies, not engine pieces)
--   batonId     the body id of this baton ("baton1" .. "baton6"), so it can
--               lie on the pitch as debris after it
--   thrower     { id, name }: the attacking team's player who throws it
--               (core/order)
-- Returns nil when the game is over.
-- core/world's surface for the engine's (the game file's "Grass", "Sand",
-- "Snow"); grass for anything it does not know.
function match.surfaceName(g)
	local name = string.lower(g.surface or "grass")
	if tw.world and tw.world.surfaces and not tw.world.surfaces[name] then return "grass" end
	return name
end

function match.setup(m)
	local g = m.game
	local raised, punished = match.settle(m)
	if raised > 0 or punished > 0 then m.settled = { raised = raised, punished = punished } else m.settled = nil end
	countTurn(m)
	local n = g:need()
	if n.kind == "over" then
		m.setup = nil
		return nil
	end
	local side = n.side
	debris.begin(m.debris, g.turn)
	-- from the inkast to the batons the lying kubbs were raised (by the
	-- engine here or by hand in scenes/settle): settle what they propped
	if m.debris.kind ~= n.kind then m.debris.settle = true end
	m.debris.kind = n.kind
	local s = { kind = n.kind, side = side, pieces = outcome.pieces(g, side), lineY = 0, forwardY = 0,
		surface = match.surfaceName(g) }
	debris.applyExact(m.debris, s.pieces, side)
	s.debris = debris.pieces(m.debris, side)
	-- settling can move the advantage line (and so the throw request's line)
	if m.debris.settle and match.settleStanding(m, s) > 0 then n = g:need() end
	if g.advantageY then s.advY = frame.y(side, g.advantageY) end
	if n.kind == "toss" then
		s.projectile, s.kubb = "kubb", n.kubb
		s.rethrow = n.rethrow
		s.n, s.of = m.tossed + 1, m.tossed + n.left
		s.label = fmt("%s  %s %d of %d", match.teamName(side, g), n.rethrow and "rethrow" or "kubb", s.n, s.of)
	else
		s.projectile = "baton"
		s.kingShot = n.kingShot
		if n.advantageY and not n.kingShot then s.forwardY = frame.y(side, n.advantageY) end
		s.targets = n.targets
		s.n, s.of = n.n, n.of
		s.batonId = "baton" .. n.n
		s.label = fmt("%s  %s %d of %d", match.teamName(side, g), n.kingShot and "king shot, baton" or "baton", n.n, n.of)
	end
	s.thrower = match.thrower(m)
	m.setup = s
	return s
end

-- Standing pieces keep the exact pose a throw left them in (core/debris):
-- tilted on an edge against a piece lying beside it, raised on a piece. (A
-- kubb leaning on a neighbour by its own weight is past its tipping point,
-- and the leaner rule has it down.) When what may have propped one has gone
-- since (the turn's debris picked up, the inkast's kubbs raised or lifted),
-- the world runs the tilted or raised ones to rest once, before the next
-- throw, from the pitch as it is now. One that falls back straight stands
-- where it settled (the engine's pose follows); one that topples or leaves
-- the pitch while settling was knocked by clearing the pitch and is stood
-- back up where the engine has it. Returns how many pieces it woke.
match.tune = {
	settleDeg = 0.5,   -- a standing piece tilted more than this ...
	settleGap = 0.002, -- m ... or this far off the ground is run to rest
}

function match.settleStanding(m, s)
	local d, g, side = m.debris, m.game, s.side
	d.settle = nil
	local cosTol, gapTol = math.cos(math.rad(match.tune.settleDeg)), match.tune.settleGap
	local wake = nil
	for _, p in ipairs(s.pieces) do
		local e, k = d.exact[p.id], body.kinds[p.kind]
		if e and e.standing and not p.toppled and p.z and k then
			-- the long axis (column 3 of the rotation) and the lowest corner
			local qw, qx, qy, qz = p.qw, p.qx, p.qy, p.qz
			local r31, r32, r33 = 2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)
			local gap = p.z - (k.hx * math.abs(r31) + k.hy * math.abs(r32) + k.hz * math.abs(r33))
			if math.abs(r33) < cosTol or gap > gapTol then
				wake = wake or {}
				wake[#wake + 1] = p.id
			end
		end
	end
	if not wake then return 0 end
	local w = world.new { surface = s.surface or "grass", pieces = match.worldPieces(s) }
	for _, id in ipairs(wake) do world.wake(w.byId[id]) end
	world.run(w)
	local res = world.result(w)
	local eps = debris.tune.matchEps
	for _, p in ipairs(s.pieces) do
		local rb = res.bodies[p.id]
		if rb and not p.toppled then
			local piece = p.id == "king" and g.king or g.kubbs[p.id]
			local wp = frame.pose(side, (outcome.poseOf(rb.x, rb.y, rb.z, rb.qw, rb.qx, rb.qy, rb.qz)))
			local old = piece.pose
			if rb.toppled or not wp.standing or not pitch.onPitch(wp.x, wp.y) then
				d.exact[p.id] = nil
			elseif (wp.x - old.x) ^ 2 + (wp.y - old.y) ^ 2 > eps * eps then
				piece.pose = { x = wp.x, y = wp.y, standing = true, angle = wp.angle }
			end
		end
	end
	debris.carry(d, res, side)
	debris.recordExact(d, g, res, side)
	-- a field kubb that settled may have moved the line the turn throws from
	-- (fixed for the turn once its first kubb or baton is thrown: II.C.4b)
	local cur = g.sheet.current
	if g.tossSeq == 0 and cur and #cur.batons == 0 then g:_advantage() end
	-- and where the turn's kubbs stand as the batons begin (the sheet's inkast
	-- positions, copied when the batons phase began)
	if g.phase == "batons" and cur and #cur.batons == 0 then g:_inkastPositions() end
	s.pieces = outcome.pieces(g, side)
	debris.applyExact(d, s.pieces, side)
	s.debris = debris.pieces(d, side)
	return #wake
end

-- Every body a throw's physics world starts with: the engine's pieces, then
-- the debris (a new list; once per throw).
function match.worldPieces(s)
	local out = {}
	for i, p in ipairs(s.pieces) do out[i] = p end
	for _, p in ipairs(s.debris or {}) do out[#out + 1] = p end
	return out
end

-- ---------- what happened, in words ----------

local function plural(n, one, many) return n == 1 and one or (n .. " " .. many) end

local function hasNote(notes, from, pattern)
	for i = from, #notes do
		if notes[i]:find(pattern, 1, true) then return true end
	end
	return false
end

local function wins(g)
	return match.teamName(g.winner, g) .. " wins"
end

-- A short line for a baton token (and the notes the throw added).
local function batonText(g, token, notes, from)
	local parts = {}
	if token == "K" then return "king down: " .. wins(g) end
	if token:sub(-1) == "E" then return "king down early: " .. wins(g) end
	if token == "G" then return "resigned: " .. wins(g) end
	if token == "=" then
		parts[1] = "missed the king"
	elseif token == "Z" then
		if hasNote(notes, from, "II.B.11") then parts[1] = "own-half kubb hit: all put back"
		else parts[1] = "helicopter: illegal" end
	elseif token == "-" then
		parts[1] = "missed"
	else
		local function n(c) if not c then return 0 end return c == "" and 1 or tonumber(c) end
		local f, b = n(token:match("^(%d*)F")), n(token:match("(%d*)B$"))
		if f > 0 then parts[#parts + 1] = plural(f, "field kubb", "field kubbs") end
		if b > 0 then parts[#parts + 1] = plural(b, "base kubb", "base kubbs") end
		parts = { table.concat(parts, " and ") .. " down" }
	end
	if hasNote(notes, from, "II.B.4a") then parts[#parts + 1] = "base kubb early: raised" end
	if hasNote(notes, from, "II.B.7") then parts[#parts + 1] = "pushed out: put back" end
	return table.concat(parts, "; ")
end

-- Apply a finished physics throw. `res` is tw.world.result of a world
-- built from m.setup.pieces with the projectile launched (a kubb toss's
-- projectile body has the kubb's id); `illegal` is true for a helicopter
-- baton. Sets m.text and returns the outcome record given to the engine.
-- The kubb throwing is judged at the final position (core/rules): after a
-- toss that is not the last of its round m.text says only where the kubb
-- lies for now; after the last one it says what the judgment did.
function match.resolve(m, res, illegal)
	local g, s = m.game, m.setup
	assert(s, "no throw set up")
	local turn = g.turn
	local sheetTurn = g.sheet.turns[turn]
	local nb, nn = #sheetTurn.batons, #sheetTurn.notes
	local o
	if s.kind == "toss" then
		local before = {}
		local ink = sheetTurn.inkast
		local function inkCount(code)
			local c = 0
			for _, k in pairs(ink) do c = c + (k[code] or 0) end
			return c
		end
		before.Q, before.N = inkCount("Q"), inkCount("N")
		o = outcome.toss(res, s.pieces, s.side, s.kubb)
		g:toss(o, s.thrower and s.thrower.id)
		m.tossed = m.tossed + 1
		local parts = {}
		local fouled = hasNote(sheetTurn.notes, nn + 1, "II.C.4b")
		local j = g.judgment
		if g.phase == "over" then
			parts[1] = "king down: " .. wins(g)
		elseif not j then
			-- more kubbs to throw in this round: only where it lies now
			if fouled then parts[1] = "own half hit: kubb out"
			elseif g:liesNow(s.kubb) == "out" then parts[1] = "kubb out for now"
			else parts[1] = "kubb in for now" end
		else
			-- the last throw of the round: the judgment
			if fouled then parts[1] = "own half hit" end
			if j.rethrow == 0 and j.punish == 0 and j.rescue == 0 and not fouled then
				parts[#parts + 1] = j.thrown == 1 and "kubb in" or "all in"
			end
			if j.rethrow > 0 then
				parts[#parts + 1] = j.rethrow == 1 and "kubb out: rethrown" or (j.rethrow .. " out: rethrown")
			end
			if j.punish > 0 then
				parts[#parts + 1] = j.punish == 1 and "out twice: punishment kubb" or (j.punish .. " punishment kubbs")
			end
			if inkCount("N") > before.N then parts[#parts + 1] = "on a kubb: lowered" end
			local q = inkCount("Q") - before.Q
			if q > 0 then parts[#parts + 1] = plural(q, "rescue", "rescues") end
		end
		m.text = table.concat(parts, "; ")
	else
		o = outcome.baton(res, s.pieces, s.side, illegal)
		g:throwBaton(o, s.thrower and s.thrower.id)
		local b = sheetTurn.batons[nb + 1]
		m.text = batonText(g, b and b.token or "-", sheetTurn.notes, nn + 1)
	end
	match.carryDebris(m, s, res, turn, sheetTurn.batons[nb + 1])
	countTurn(m)
	m.setup = nil
	return o
end

-- After the engine has ruled on a throw: what stays lying on the pitch for
-- the next throw of this turn. The thrown baton lies where it came to rest;
-- every kubb this throw toppled that the engine took off the pitch (into a
-- hand) lies where it fell; the debris already there moves if it was struck.
-- A throw the engine puts back (Z: a helicopter, II.B.11) leaves the earlier
-- debris where it was, as it does the standing pieces; only its baton is
-- added. The turn over: no debris is carried, only the standing pieces'
-- exact poses (core/debris); the game over: nothing.
function match.carryDebris(m, s, res, turn, batonRec)
	local g, d = m.game, m.debris
	if g.phase == "over" then
		debris.clear(d)
		return
	end
	if g.turn ~= turn then
		-- the turn is over: its debris is picked up, but the standing
		-- pieces stay as this throw left them
		debris.recordExact(d, g, res, s.side)
		debris.begin(d, g.turn)
		return
	end
	if s.kind == "toss" then
		-- the engine keeps every thrown kubb on the pitch until its round is
		-- judged (out ones too), and any it struck: only their exact rest
		-- poses are carried. A kubb whose support was picked up at the
		-- judgment lies flat where it is, not floating at its old height.
		debris.recordExact(d, g, res, s.side)
		local j = g.judgment
		for _, id in ipairs(j and j.lifted or {}) do
			d.exact[id] = nil
			d.settle = true
		end
		-- a kubb picked up for a rethrow, a rescue or a punishment may have been
		-- propping a standing one sideways: settle whenever the judgment took any
		if j and ((j.rethrow or 0) > 0 or (j.rescue or 0) > 0 or (j.punish or 0) > 0) then
			d.settle = true
		end
		return
	end
	local putBack = batonRec and batonRec.token == "Z"
	if not putBack then
		debris.carry(d, res, s.side)
		for _, id in ipairs(res.toppled or {}) do
			local k = g.kubbs[id]
			if k and k.where ~= "pitch" then debris.add(d, id, "kubb", res, s.side) end
		end
	end
	if s.batonId then debris.add(d, s.batonId, "baton", res, s.side) end
	debris.recordExact(d, g, res, s.side)
end

-- Resign: the team on turn gives up (DESIGN 7: `G` on its own turn).
function match.resign(m)
	local g = m.game
	if g.phase == "over" then return false end
	local side = g.attacker
	g:resign(side, order.thrower(orderOf(m), g))
	m.setup = nil
	debris.clear(m.debris)
	m.text = match.teamName(side, g) .. " resigned: " .. wins(g)
	return true
end

-- One line for the winner screen.
function match.howText(m)
	local g = m.game
	local loser = match.teamName(g.winner == "A" and "B" or "A", g)
	if g.how == "king" then return match.teamName(g.winner, g) .. " toppled the king"
	elseif g.how == "resigned" then return loser .. " resigned"
	elseif g.how == "king toppled by a thrown kubb" then return loser .. " toppled the king with a kubb"
	elseif g.how == "king toppled early" then return loser .. " hit the king too soon" end
	return g.how or ""
end

-- The game file (DESIGN 7): text and file name. finish = {year, month, day,
-- hour, min}; the start is m.start (finish when it was not given).
function match.file(m, finish, version)
	local start = m.start or finish
	local g = m.game
	local levels = {}
	for _, side in ipairs { "A", "B" } do
		for _, e in ipairs(m.lineup and m.lineup[side] or {}) do
			if e.level then levels[#levels + 1] = e.id .. " " .. e.level end
		end
	end
	local text = notation.render(g, { start = start, finish = finish, version = version, mode = m.mode,
		levels = levels })
	return text, notation.filename(start, g.teams.A.name, g.teams.B.name)
end

-- Standing kubbs of a side's half (field and base), for the HUD.
function match.standing(m, side)
	local g = m.game
	return #g:fieldKubbs(side) + #g:baseKubbs(side)
end

tw.match = match
