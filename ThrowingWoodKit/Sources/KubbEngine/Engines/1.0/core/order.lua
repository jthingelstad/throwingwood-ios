-- The throwing order inside a team (docs/PLAYERS.md section 5): who throws
-- every baton and kubb, decided before the throw, within Rules V4.0. Pure
-- Lua: no playdate.*. Once per throw, not a per-frame path.
--
-- The rules (V4.0), kept as far as a team's size allows:
--   II.B.5  no player throws more than two batons in a turn: a team of n
--           players caps each at max(2, ceil(batons / n)) (one player
--           throws all six, two throw three each);
--   II.A.4  in the 2-4-6 opening the two batons are thrown by two different
--           players and the four by at least three (fewer when the team is
--           smaller).
-- kubb.js checks neither; order.checkSheet does, for the headless games.
--
-- Each team has a rotation, its players in order. A turn's batons are dealt
-- from it in blocks, as evenly as possible over as many players as there
-- are batons (order.split): a player throws their batons in a row, so the
-- Playdate changes hands as few times as the rules allow. The next turn
-- starts past the players who threw an extra baton (past everyone dealt
-- when all threw the same), so the doubles go round the team. The kubbs (first throws,
-- rethrows) are thrown by one inkaster, by default the turn's first baton
-- thrower. Either can be changed before a throw (order.change,
-- order.setInkaster) as long as the rules still hold.
--
--   local o = order.new(g.teams)          -- plain tables: core/save keeps it
--   local pid = order.thrower(o, g)       -- who throws what g:need() asks for
--   g:throwBaton(outcome, pid)
--
-- The state:
--   o.A, o.B   { ids = { player ids in rotation order }, start = index of
--              the player who opens the team's next turn }
--   o.turn, o.side, o.batons   the turn dealt (the engine's turn number)
--   o.deal     player id per baton of that turn
--   o.inkaster player id who throws that turn's kubbs
--   o.A.rotateInk, o.A.ink   (0.17.0) the kubbs go round the team (a team with a
--              computer player), and the index of the last turn's inkaster
import "core/tw"
import "core/rules"

local rules = tw.rules
local ceil = math.ceil

local order = {}

-- Batons one player may throw in a turn of `batons` (II.B.5) on a team of n.
function order.cap(n, batons)
	local c = ceil(batons / n)
	if c < 2 then c = 2 end
	return c
end

-- Different players a turn of `batons` needs on a team of n (II.A.4: two
-- for the opening's two batons, three for its four).
function order.distinct(n, batons)
	local d = 1
	if batons == 2 then d = 2 elseif batons == 4 then d = 3 end
	if d > n then d = n end
	return d
end

-- The blocks: batons each player throws, in rotation order, for a turn of
-- `batons` on a team of n. { 2, 2, 1, 1 } for six batons and four players.
function order.split(n, batons)
	local k = n < batons and n or batons
	local base, extra = batons // k, batons % k
	local out = {}
	for i = 1, k do out[i] = base + (i <= extra and 1 or 0) end
	return out
end

-- Whether the batons thrown so far (`pids`, player ids in order) can still
-- make a legal turn of `batons` on a team of n. false and why ("cap": a
-- player over the limit, "distinct": too few different players left
-- possible) otherwise.
function order.check(n, batons, pids)
	local count, distinct = {}, 0
	local cap = order.cap(n, batons)
	for _, pid in ipairs(pids) do
		local c = (count[pid] or 0) + 1
		if c == 1 then distinct = distinct + 1 end
		if c > cap then return false, "cap" end
		count[pid] = c
	end
	if distinct + (batons - #pids) < order.distinct(n, batons) then return false, "distinct" end
	return true
end

function order.new(teams)
	local o = {}
	for _, side in ipairs { "A", "B" } do
		local ids = {}
		for i, p in ipairs(teams[side].players) do ids[i] = p.id end
		o[side] = { ids = ids, start = 1 }
	end
	return o
end

local function onTeam(o, side, pid)
	for _, id in ipairs(o[side].ids) do
		if id == pid then return true end
	end
	return false
end

-- Deal the turn: `side` throws `batons` in engine turn `turn`.
function order.beginTurn(o, side, turn, batons)
	local t = o[side]
	local n = #t.ids
	local blocks = order.split(n, batons)
	local deal = {}
	for i, c in ipairs(blocks) do
		local pid = t.ids[(t.start - 1 + i - 1) % n + 1]
		for _ = 1, c do deal[#deal + 1] = pid end
	end
	o.turn, o.side, o.batons, o.deal, o.inkaster = turn, side, batons, deal, deal[1]
	-- (0.17.0) a team holding a computer player (t.rotateInk, set by core/match) has its
	-- kubbs thrown by each player in turn, turn by turn, so a computer partner takes its
	-- share: with 1, 2, 3 or 6 players and six batons the deal opens every turn with the
	-- same player, who would otherwise throw every turn's kubbs. A team without one keeps
	-- the turn's first baton thrower, as before
	if t.rotateInk then
		t.ink = (t.ink or 0) % n + 1
		o.inkaster = t.ids[t.ink]
	end
	-- move on past those who threw an extra baton, so the doubles go round
	-- the team; past everyone dealt when all threw the same (in the
	-- opening, whoever did not throw opens the team's next turn)
	local extra = batons % #blocks
	t.start = (t.start - 1 + (extra > 0 and extra or #blocks)) % n + 1
end

-- Deal the engine's current turn if it has not been dealt yet.
function order.sync(o, g)
	if g.phase ~= "over" and o.turn ~= g.turn then
		order.beginTurn(o, g.attacker, g.turn, g.batonsTotal)
	end
end

-- Who throws next in game g: the inkaster during the kubb throwing, the
-- dealt player for the next baton otherwise (also while the defender
-- raises, so a resign then is the next baton thrower's). nil once over.
function order.thrower(o, g)
	if g.phase == "over" then return nil end
	order.sync(o, g)
	if g.phase == "toss" or g.phase == "rethrow" then return o.inkaster end
	return o.deal[g.batonIndex + 1] or o.deal[#o.deal]
end

-- Whether `pid` may take baton n of the dealt turn: the deal with pid on
-- baton n and the player it replaces on pid's first later baton (a swap,
-- so the rest of the turn keeps its shape), checked whole. Returns ok, why
-- ("team", "cap", "distinct", "thrown") and the new deal.
function order.allowed(o, n, pid, thrown)
	if not onTeam(o, o.side, pid) then return false, "team" end
	if thrown and n <= thrown then return false, "thrown" end
	local deal = {}
	for i, p in ipairs(o.deal) do deal[i] = p end
	local was = deal[n]
	if was == pid then return true, nil, deal end
	deal[n] = pid
	for j = n + 1, #deal do
		if deal[j] == pid then deal[j] = was; break end
	end
	local ok, why = order.check(#o[o.side].ids, o.batons, deal)
	if not ok then return false, why end
	return true, nil, deal
end

-- Give baton n to `pid` (order.allowed); returns ok, why.
function order.change(o, n, pid, thrown)
	local ok, why, deal = order.allowed(o, n, pid, thrown)
	if ok then o.deal = deal end
	return ok, why
end

-- The turn's kubbs go to `pid` (any player of the team); returns ok, why.
function order.setInkaster(o, pid)
	if not onTeam(o, o.side, pid) then return false, "team" end
	o.inkaster = pid
	return true
end

-- Every way game g's score sheet breaks the order's rules or its teams:
-- a list of strings, empty when it keeps them all.
function order.checkSheet(g)
	local out = {}
	for _, t in ipairs(g.sheet.turns) do
		local side = t.side
		local members = {}
		for _, p in ipairs(g.teams[side].players) do members[p.id] = true end
		local n = #g.teams[side].players
		local batons = rules.batonsFor(g.opening, t.n)
		local pids = {}
		for _, b in ipairs(t.batons) do
			if b.player and not members[b.player] then
				out[#out + 1] = ("turn %d: %s is not on Team %s"):format(t.n, b.player, side)
			end
			if b.token ~= "X" and b.token ~= "G" then pids[#pids + 1] = b.player end
		end
		for _, pid in ipairs(t.inkastOrder) do
			if not members[pid] then out[#out + 1] = ("turn %d: kubbs by %s, not on Team %s"):format(t.n, pid, side) end
		end
		local ok, why = order.check(n, batons, pids)
		if not ok then
			out[#out + 1] = ("turn %d: %s (%d players, %s)"):format(t.n,
				why == "cap" and "a player over the baton limit (II.B.5)" or "too few different throwers (II.A.4)",
				n, table.concat(pids, " "))
		end
	end
	return out
end

tw.order = order
