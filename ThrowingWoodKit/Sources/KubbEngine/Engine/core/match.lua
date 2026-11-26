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
import "core/cpu"      -- the computer's raising by level (match.raisePolicy)

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
-- order: { A = { { id, key, level, guest, cpu } }, B = ... }. rules.new keeps the
-- players in order, so the two lists line up. `cpu` (0.17.0) is true for a computer
-- player in a team (a computer partner, or one of a team of computers at mixed
-- levels), and absent for everyone else, so a lineup without one is the lineup it
-- always was. `throw` (1.3.0) is a person's throw level when their entry gave one
-- (easy or hard; the session keeps no standard), the meter they throw on.
function match.lineupOf(g, teams)
	local out = {}
	for _, side in ipairs { "A", "B" } do
		local given = teams and teams[side] and teams[side].players or {}
		local list = {}
		for i, p in ipairs(g.teams[side].players) do
			local q = given[i] or {}
			if type(q) ~= "table" then q = {} end
			list[i] = { id = p.id, key = q.key, level = q.level, guest = q.guest or nil, cpu = (q.cpu == true) or nil,
				throw = (q.cpu ~= true and type(q.throw) == "string") and q.throw or nil }
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
		rules = opts.rules,   -- "kid": the Kid rules (core/rules rules.kid); nil: the standard rules
	}
	local m = {
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
		cpu = opts.cpu,           -- the sides the computer plays (match.raisePolicy), or nil
		raising = opts.raising,   -- a policy by side (match.raisePolicy), or nil
	}
	-- (0.17.0) a team with a computer player has its kubbs thrown by each player in turn
	-- (core/order rotateInk), so a computer partner takes its share of the inkasts
	for _, side in ipairs { "A", "B" } do
		for _, e in ipairs(m.lineup[side]) do
			if e.cpu then m.order[side].rotateInk = true end
		end
	end
	return m
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
	return { id = pid, name = p and p.name or pid, key = e and e.key, level = e and e.level,
		cpu = (e and e.cpu) or nil, throw = e and e.throw or nil }
end

-- ---------- computer players (0.17.0) ----------
--
-- A team may hold people, computers, or both. A computer player is either every player
-- of a side the computer plays (match.cpuSides: m.cpu, the session's old `cpu` option,
-- or the "Vs Playdate" mode's Team B), or a player whose lineup entry says `cpu`
-- (match.lineupOf). Each throws at its own level (its lineup entry's: autothrow.choose
-- reads the thrower's), in the team's throwing order (core/order), so a computer
-- partner takes its share of the batons and, when the order makes it the inkaster, the
-- turn's kubbs.

-- Is `id` of `side` a computer player?
function match.isComputer(m, side, id)
	local sides = match.cpuSides(m)
	if sides and sides[side] then return true end
	local e = match.member(m, side, id)
	return e ~= nil and e.cpu == true
end

-- Is `id` of `side` a computer player in a team (its lineup entry says so), as opposed
-- to a player of a side the computer plays whole?
function match.isSeat(m, side, id)
	local e = match.member(m, side, id)
	return e ~= nil and e.cpu == true
end

-- Has `side` a person on it? A team with one decides what the rules give the team
-- (raising, the punishment kubb) by its people; a team of computers decides them itself.
function match.hasPerson(m, side)
	local sides = match.cpuSides(m)
	if sides and sides[side] then return false end
	for _, p in ipairs(m.game.teams[side].players) do
		if not match.isComputer(m, side, p.id) then return true end
	end
	return false
end

-- The people on `side`: how many.
function match.people(m, side)
	local sides = match.cpuSides(m)
	if sides and sides[side] then return 0 end
	local n = 0
	for _, p in ipairs(m.game.teams[side].players) do
		if not match.isComputer(m, side, p.id) then n = n + 1 end
	end
	return n
end

-- The levels in order of strength.
match.LEVEL_RANK = { kid = 1, beginner = 2, club = 3, pro = 4 }

-- The strongest level among `side`'s computer players in a team (lineup entries that
-- say cpu), or nil when it has none: the level a team of computers makes its team
-- decisions at.
function match.strongestLevel(m, side)
	local best, rank = nil, 0
	for _, e in ipairs(m.lineup and m.lineup[side] or {}) do
		local r = e.cpu and match.LEVEL_RANK[e.level] or 0
		if r > rank then best, rank = e.level, r end
	end
	return best
end

-- Hand the throw set up (m.setup) to another player of its team: the kubbs
-- (the inkaster, core/order.setInkaster) or this baton (core/order.change).
-- Returns ok, why ("team", "cap", "distinct"); on ok m.setup.thrower is the
-- new player's.
function match.changeThrower(m, pid)
	local s, g = m.setup, m.game
	if not s then return false, "none" end
	-- (0.17.0) a person may never act for a computer partner, nor hand a throw to one: the
	-- change is between people. A computer's throw is its own, and one person's throw
	-- given to another swaps with that person's next one (core/order.change), so a
	-- computer's batons stay where the order put them. ("computer"; a side the computer
	-- plays whole is as it always was)
	if (s.thrower and match.isSeat(m, s.side, s.thrower.id)) or match.isSeat(m, s.side, pid) then
		return false, "computer"
	end
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
		local seat = match.isSeat(m, s.side, p.id)
		if seat then ok, why = false, "computer"
		elseif s.kind == "toss" then ok = true else ok, why = order.allowed(o, s.n, p.id, s.n - 1) end
		out[#out + 1] = { id = p.id, name = p.name, ok = ok and true or false, why = why,
			current = s.thrower and s.thrower.id == p.id, cpu = seat or nil }
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
			local e = match.isSeat(m, o.side, pid) and match.member(m, o.side, pid)
			out[#out + 1] = { id = pid, name = p and p.name or pid, n = 1, cpu = e and true or nil,
				level = e and e.level or nil }
		end
	end
	return out, o.inkaster and match.player(m, o.side, o.inkaster)
end

function match.over(m) return m.game.phase == "over" end

local function countTurn(m)
	if m.game.turn ~= m.turn then m.turn, m.tossed = m.game.turn, 0 end
end

-- ---------- raising by side (0.12.0) ----------
--
-- The defender's kubbs are raised by the policy of the side that defends: the computer
-- by its level (core/cpu.raising: pro par, club apart, beginner first), a person by the
-- engine's best advice (cpu.advice, par). That needs to know which sides the computer
-- plays, which a match knows from
--   m.cpu      the sides the computer plays: a list ({ "B" }, {} for none) or a set
--              ({ B = true }); match.new's `cpu`. Not saved (core/save): a client that
--              resumes a match sets it again (the session does, from its options).
--   m.mode     "Vs Playdate" when m.cpu is not given: Team B is the Playdate (core/lineup's
--              VS PLAYDATE). The mode is saved, so a resumed match knows it too.
-- and each computer side's level from the lineup (its first player that has one; none:
-- autothrow.tune.level, as its throws). Since 0.17.0 a team may hold computer players
-- (lineup entries that say cpu): a team with a person on it raises as a person's side,
-- by the engine's advice; a team of computers raises as the computer at its strongest
-- player's level (match.strongestLevel). m.raising = { A = policy, B = policy }
-- (match.new's `raising`, not saved) names a side's policy outright, a name in
-- tw.raising.policies or a function(dec, ctx); it wins over the rest.
-- A match that says none of this (no cpu, no raising, another mode) raises every kubb
-- with the game's one policy, game.raisePolicy (apart), as before 0.12.

-- The sides the computer plays as a set ({ B = true }), {} for none, or nil when the
-- match does not say.
function match.cpuSides(m)
	local c = m.cpu
	if c == nil then
		if m.mode == "Vs Playdate" then return { B = true } end
		return nil
	end
	local out = {}
	for k, v in pairs(c) do
		if type(k) == "number" then out[v] = true elseif v then out[k] = true end
	end
	return out
end

-- The level of `side` (its first player in the lineup that has one), or nil.
function match.sideLevel(m, side)
	for _, e in ipairs(m.lineup and m.lineup[side] or {}) do
		if e.level then return e.level end
	end
	return nil
end

-- The policy `side`'s kubbs are raised with when the engine raises them: m.raising's;
-- else, when the match knows which sides the computer plays, a function that raises as
-- the computer at the side's level (cpu.raise, which keeps its reason in cpu.last) for a
-- computer side and cpu.advice ("par") for a person's; else nil, which Game:raise takes
-- as the game's own (game.raisePolicy).
function match.raisePolicy(m, side)
	local r = m.raising and m.raising[side]
	if r ~= nil then return r end
	local sides = match.cpuSides(m)
	if not (sides and sides[side]) and not match.hasPerson(m, side) then
		-- a team of computer players (0.17.0): the computer at its strongest level
		local level = match.strongestLevel(m, side)
		return function(dec, ctx) return tw.cpu.raise(dec, ctx, level) end
	end
	if not sides then return nil end
	if sides[side] then
		local level = match.sideLevel(m, side)
		return function(dec, ctx) return tw.cpu.raise(dec, ctx, level) end
	end
	return tw.cpu.advice
end

local function poseCopy(p)
	if not p then return nil end
	return { x = p.x, y = p.y, standing = p.standing and true or false, angle = p.angle or 0 }
end

-- Raise every lying kubb and place every punishment kubb (automatically,
-- with the engine's policies: the raising is the defender's, match.raisePolicy).
-- Returns how many of each, and the list of what was done in order (0.16.0, the
-- setup's `settled`): { kind = "raise", id, side (who raised), which (the end, as a
-- raise action names it), lying, standing (poses, the engine's frame), displaced,
-- crowded } or { kind = "punish", id, side, pose }. Nothing here is saved or hashed.
-- Since 1.0 each also has `seat`, the quaternion the kubb will stand at in the next
-- throw's world (its seat, engine frame; nil when plumb), so a client ends a watched raise
-- where the kubb will stand.
-- Since 0.17.0 each entry also has the surroundings as they stood while it was done,
-- what a raise or a punishment kubb by hand is shown with (the session's raiseInfo and
-- punishInfo, Game:context): `others` = { { id, kind, pose } } every other piece on the
-- pitch, and `king` its pose (the engine's frame). Per entry, since a kubb raised earlier
-- stands among the next one's others.
local function surroundings(g, side, id)
	local ctx = g:context(side, id)
	local others = {}
	for i, o in ipairs(ctx.others) do others[i] = { id = o.id, kind = o.kind, pose = poseCopy(o.pose) } end
	return others, poseCopy(ctx.king)
end

-- The pose a standing kubb at engine pose p takes in the next throw's world, its seat
-- (world.seat, 1.0), in the engine's frame: { qw, qx, qy, qz }, or nil when it stands
-- plumb (the grid, the seat off, or no world loaded). Engine and side A's view are the
-- same frame; another view turns it with frame.quat.
local function seatOf(g, p)
	local world = tw.world
	if not (world and world.seat and p and p.standing) then return nil end
	local a = p.angle or 0
	local qw, qx, qy, qz, seated = world.seat(match.surfaceName(g), "kubb", p.x, p.y, math.cos(a / 2), 0, 0, math.sin(a / 2))
	if not seated then return nil end
	return { qw = qw, qx = qx, qy = qy, qz = qz }
end

function match.settle(m)
	local g = m.game
	local raised, punished = 0, 0
	local list = {}
	while true do
		local n = g:need()
		if n.kind == "raise" then
			local lying = poseCopy(n.pose)
			local others, king = surroundings(g, n.side, n.kubb)
			local c = g:raise(nil, match.raisePolicy(m, n.side))
			raised = raised + 1
			list[#list + 1] = { kind = "raise", id = n.kubb, side = n.side, which = c.which, lying = lying,
				standing = poseCopy(c.pose), displaced = c.displaced or false, crowded = c.crowded or false,
				others = others, king = king }
			list[#list].standing.standing = true
			list[#list].seat = seatOf(g, list[#list].standing)
		elseif n.kind == "punish" then
			local id = n.kubb
			local others, king = surroundings(g, n.side, id)
			g:autoPunishment()
			punished = punished + 1
			local k = g.kubbs[id]
			list[#list + 1] = { kind = "punish", id = id, side = n.side, pose = poseCopy(k and k.pose),
				others = others, king = king }
			list[#list].seat = seatOf(g, list[#list].pose)
		else
			break
		end
	end
	return raised, punished, list
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
--   kid         true in a Kid game (core/rules rules.kid), else nil
--   kidY        a Kid game's Kid line (view frame: rules.kid.line), which every kubb and
--               every baton at a kubb is thrown from unless the advantage line is
--               nearer the middle; nil in a standard game
--   targets     ids to frame: standing field kubbs, else base kubbs, else
--               the king (batons); nil for a toss
--   n, of       this throw's number and the throws of its kind this turn (a toss: kubbs
--               and rethrows together, the count Choose reads)
--   roundN, roundOf  a toss's place in its round (0.17.0): the kubbs thrown in first, or
--               the kubbs rethrown; what the label and the session's need say
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
	local raised, punished, list = match.settle(m)
	if raised > 0 or punished > 0 then m.settled = { raised = raised, punished = punished, list = list } else m.settled = nil end
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
	if g.rules == "kid" then
		-- the Kid rules: the thrower stands up to the Kid line (or the advantage line
		-- beyond it) for kubbs and batons at kubbs; the king from the baseline
		s.kid, s.kidY = true, frame.y(side, g:kidLineY(side))
		if not n.kingShot then s.forwardY = frame.y(side, n.throwY) end
	end
	if n.kind == "toss" then
		s.projectile, s.kubb = "kubb", n.kubb
		s.rethrow = n.rethrow
		s.n, s.of = m.tossed + 1, m.tossed + n.left
		-- what a player is told (0.17.0): the kubb's place in its round, the kubbs thrown in
		-- first or the ones rethrown (g.roundThrows: thrown in the round so far), so two in
		-- and one out reads "rethrow 1 of 1", not "kubb 3 of 3". s.n and s.of stay the
		-- turn's count, which the computer's inkast reads (kubbs still in hand)
		s.roundN, s.roundOf = (g.roundThrows or 0) + 1, (g.roundThrows or 0) + n.left
		s.label = fmt("%s  %s %d of %d", match.teamName(side, g), n.rethrow and "rethrow" or "kubb", s.roundN, s.roundOf)
	else
		s.projectile = "baton"
		s.kingShot = n.kingShot
		if n.advantageY and not n.kingShot and not s.kid then s.forwardY = frame.y(side, n.advantageY) end
		s.targets = n.targets
		s.n, s.of = n.n, n.of
		s.batonId = "baton" .. n.n
		s.label = fmt("%s  %s %d of %d", match.teamName(side, g), n.kingShot and "king shot, baton" or "baton", n.n, n.of)
	end
	s.thrower = match.thrower(m)
	-- what the engine raised and placed before this throw (match.settle; 0.16.0)
	s.settled = m.settled
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
	-- a kubb's seat (world.seat, 1.0) is a lean on its own edge, not a tilt something
	-- props: within the surface's seat a standing kubb is left as it is (woken, it rocks
	-- back plumb and its seat is lost at every settle)
	local wt = tw.world and tw.world.tune
	local surf = tw.world and tw.world.surfaces[s.surface or "grass"]
	local seatDeg = (wt and wt.seatOn > 0 and surf and surf.seat or 0)
	local cosKubb = math.cos(math.rad(match.tune.settleDeg + seatDeg))
	local wake = nil
	for _, p in ipairs(s.pieces) do
		local e, k = d.exact[p.id], body.kinds[p.kind]
		if e and e.standing and not p.toppled and p.z and k then
			local cosTol = p.kind == "kubb" and cosKubb or cosTol
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
	-- m.run, when a host sets it, runs the world to rest in its place: the same steps in
	-- the same order, in slices (session/neighbours, 0.15.1). Never saved (core/save).
	local run = m.run or world.run
	run(w)
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

-- A short line for a baton token (and the notes the throw added), and the same as
-- codes: a list of { code, n } beside the words (m.ruling), one per part of the line,
-- so a reader need not parse the English. The words are what they always were.
local function batonText(g, token, notes, from)
	local parts, codes = {}, {}
	if token == "K" then return "king down: " .. wins(g), { { code = "kingWin" } } end
	if token:sub(-1) == "E" then return "king down early: " .. wins(g), { { code = "kingEarly" } } end
	if token == "G" then return "resigned: " .. wins(g), { { code = "resigned" } } end
	if token == "=" then
		parts[1], codes[1] = "missed the king", { code = "kingMiss" }
	elseif token == "Z" then
		if hasNote(notes, from, "II.B.11") then parts[1], codes[1] = "own-half kubb hit: all put back", { code = "ownHalf" }
		else parts[1], codes[1] = "helicopter: illegal", { code = "helicopter" } end
	elseif token == "-" then
		parts[1], codes[1] = "missed", { code = "miss" }
	else
		local function n(c) if not c then return 0 end return c == "" and 1 or tonumber(c) end
		local f, b = n(token:match("^(%d*)F")), n(token:match("(%d*)B$"))
		if f > 0 then parts[#parts + 1] = plural(f, "field kubb", "field kubbs"); codes[#codes + 1] = { code = "field", n = f } end
		if b > 0 then parts[#parts + 1] = plural(b, "base kubb", "base kubbs"); codes[#codes + 1] = { code = "base", n = b } end
		parts = { table.concat(parts, " and ") .. " down" }
	end
	if hasNote(notes, from, "II.B.4a") then
		parts[#parts + 1] = "base kubb early: raised"; codes[#codes + 1] = { code = "baseEarly" }
	end
	if hasNote(notes, from, "II.B.7") then
		parts[#parts + 1] = "pushed out: put back"; codes[#codes + 1] = { code = "pushedOut" }
	end
	-- the Kid rules (0.15.0): the king knocked down early is stood back up; a helicopter counts
	if hasNote(notes, from, "king down early; stood back up") then
		parts[#parts + 1] = "king down early: stood back up"; codes[#codes + 1] = { code = "kingUp" }
	end
	if hasNote(notes, from, "helicopter; counted") then
		parts[#parts + 1] = "helicopter: counted"; codes[#codes + 1] = { code = "helicopterCounts" }
	end
	return table.concat(parts, "; "), codes
end

-- Apply a finished physics throw. `res` is tw.world.result of a world
-- built from m.setup.pieces with the projectile launched (a kubb toss's
-- projectile body has the kubb's id); `illegal` is true for a helicopter
-- baton. Sets m.text (and m.ruling, its codes: { parts = { { code, n } }, winner })
-- and returns the outcome record given to the engine. m.ruling is not saved.
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
		local parts, codes = {}, {}
		local function say(text, code, n)
			parts[#parts + 1] = text
			codes[#codes + 1] = { code = code, n = n }
		end
		local fouled = hasNote(sheetTurn.notes, nn + 1, "II.C.4b")
		local j = g.judgment
		local kingUp = hasNote(sheetTurn.notes, nn + 1, "knocked the king down; stood back up")
		if g.phase == "over" then
			say("king down: " .. wins(g), "kingKubb")
		elseif not j then
			if kingUp then say("king down: stood back up", "kingUp") end
			-- more kubbs to throw in this round: only where it lies now
			if fouled then say("own half hit: kubb out", "ownHalfOut")
			elseif g:liesNow(s.kubb) == "out" then say("kubb out for now", "outForNow")
			else say("kubb in for now", "inForNow") end
		else
			-- the last throw of the round: the judgment
			if kingUp then say("king down: stood back up", "kingUp") end
			if fouled then say("own half hit", "ownHalf") end
			if j.rethrow == 0 and j.punish == 0 and j.rescue == 0 and not fouled then
				say(j.thrown == 1 and "kubb in" or "all in", "in", j.thrown)
			end
			if j.rethrow > 0 then
				say(j.rethrow == 1 and "kubb out: rethrown" or (j.rethrow .. " out: rethrown"), "rethrow", j.rethrow)
			end
			if j.punish > 0 and g.rules == "kid" then
				-- the Kid rules: no punishment kubb; the engine stands it at the fair spot
				say(j.punish == 1 and "out twice: stood at the fair spot" or (j.punish .. " out twice: stood at the fair spot"),
					"placed", j.punish)
			elseif j.punish > 0 then
				say(j.punish == 1 and "out twice: punishment kubb" or (j.punish .. " punishment kubbs"), "punish", j.punish)
			end
			if inkCount("N") > before.N then say("on a kubb: lowered", "lowered") end
			local q = inkCount("Q") - before.Q
			if q > 0 then say(plural(q, "rescue", "rescues"), "rescue", q) end
		end
		m.text = table.concat(parts, "; ")
		m.ruling = { parts = codes, winner = g.winner }
	else
		o = outcome.baton(res, s.pieces, s.side, illegal)
		g:throwBaton(o, s.thrower and s.thrower.id)
		local b = sheetTurn.batons[nb + 1]
		local codes
		m.text, codes = batonText(g, b and b.token or "-", sheetTurn.notes, nn + 1)
		m.ruling = { parts = codes, winner = g.winner }
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
	m.ruling = { parts = { { code = "resigned" } }, winner = g.winner }
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

-- The game file's [Throw Levels] (notation.render's meta.levels): the computer's
-- players only (0.13.2), each "id level" in the order they are written, Team A's
-- then Team B's. A level is the computer's standard: since 0.13.0 every person throws
-- on one meter and a person's level changes nothing (docs/notes/throw.md "The
-- person's meter"), so a person is not listed. Which sides the computer plays is
-- match.cpuSides (match.new's `cpu`, or the "Vs Playdate" mode's Team B); a match that
-- says neither (pass and play, a match from a caller before 0.12) lists no one, and
-- the file has no [Throw Levels]. A computer player's level is the one it throws at
-- (cpu.levelName: its lineup's level, else autothrow.tune.level). Since 0.17.0 a
-- computer player in a team (match.isComputer) is listed with its own level beside the
-- rest, in team order, so a team of computers at mixed levels or a person's computer
-- partner reads as it played. Since 1.3.0 a person who threw on a player level other
-- than standard (their lineup entry's `throw`: easy or hard) is listed too, with that
-- level, so the file says which meter they threw on; a person on standard is not
-- listed, and in a Kid match no person is (every person throws on the Kid meter). The
-- words never meet: a computer's level is beginner, club, pro or kid, a person's easy or
-- hard.
function match.fileLevels(m)
	local levels = {}
	local kid = m.game.rules == "kid"
	for _, side in ipairs { "A", "B" } do
		for _, p in ipairs(m.game.teams[side].players) do
			local e = match.member(m, side, p.id)
			if match.isComputer(m, side, p.id) then
				levels[#levels + 1] = p.id .. " " .. tw.cpu.levelName { thrower = e }
			elseif e and e.throw and not kid then
				levels[#levels + 1] = p.id .. " " .. e.throw
			end
		end
	end
	return levels
end

-- The game file (DESIGN 7): text and file name. finish = {year, month, day,
-- hour, min}; the start is m.start (finish when it was not given). location: the
-- Location line (nil: notation.location).
function match.file(m, finish, version, location)
	local start = m.start or finish
	local g = m.game
	local text = notation.render(g, { start = start, finish = finish, version = version, mode = m.mode,
		levels = match.fileLevels(m), location = location, firstBy = g.firstBy })
	return text, notation.filename(start, g.teams.A.name, g.teams.B.name)
end

-- ---------- the throw to go (1.4.0, core/togo) ----------

-- Who throws `side`'s baton to go: the first player in its throwing order (the team's
-- first player), with match.thrower's shape { id, name, key, level, cpu, throw }.
function match.togoThrower(m, side)
	local p = m.game.teams[side].players[1]
	local e = match.member(m, side, p.id)
	local cpu = match.isComputer(m, side, p.id) or nil
	local level = e and e.level
	return { id = p.id, name = p.name, key = e and e.key, level = level, cpu = cpu, throw = e and e.throw or nil }
end

-- The set-up for `side`'s baton to go (view frame of side): the pitch as the match
-- starts, one baton from the middle of its own baseline, the king its only target. The
-- shape of match.setup's, kind "togo"; not kept on m (m.setup stays the turn's).
function match.togoSetup(m, side)
	local g = m.game
	local s = { kind = "togo", side = side, pieces = outcome.pieces(g, side), lineY = 0, forwardY = 0,
		surface = match.surfaceName(g), debris = {}, projectile = "baton", targets = {},
		n = 1, of = 1, batonId = "togo" .. side, togo = true, markerNear = 2 }
	s.label = fmt("%s  throw to go", match.teamName(side, g))
	s.thrower = match.togoThrower(m, side)
	return s
end

-- The throw to go decided it: `side` throws first. Only before the first throw of the
-- match; the game is made again with that side first (nothing has happened in it), its
-- players' ids kept, and `how` (togo.text) kept on it as game.firstBy, which the game
-- file writes as [Engine:first]. Returns the new game.
function match.setFirst(m, side, how)
	local g = m.game
	assert(g.turn == 1 and #g.sheet.turns <= 1 and m.tossed == 0, "setFirst: only before the first throw")
	local teams = {}
	for _, sd in ipairs { "A", "B" } do
		local ps = {}
		for i, p in ipairs(g.teams[sd].players) do ps[i] = { name = p.name } end
		teams[sd] = { name = g.teams[sd].name, players = ps }
	end
	local ng = rules.new { teams = teams, surface = g.surface, opening = g.opening, first = side, rules = g.rules,
		raisePolicy = g.raisePolicy }
	for _, sd in ipairs { "A", "B" } do
		for i, p in ipairs(g.teams[sd].players) do ng.teams[sd].players[i].id = p.id end
	end
	ng.firstBy = how
	m.game, m.turn = ng, ng.turn
	return ng
end

-- Standing kubbs of a side's half (field and base), for the HUD.
function match.standing(m, side)
	local g = m.game
	return #g:fieldKubbs(side) + #g:baseKubbs(side)
end

tw.match = match
