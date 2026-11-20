-- What the match's cards say (docs/design/boards/HandOff.png, Winner.png),
-- from the engine's state and its score sheet. Pure Lua: no playdate.*. Once
-- per card, not a per-frame path.
--
--   cards.batonCounts(token)   field, base kubbs a baton token toppled,
--                              whether it is a hit (toppled a kubb, or the
--                              king on a king shot) and whether it is a throw
--   cards.took(g, turn)        { field, base } toppled by batons in that turn
--   cards.handoff(m, setup)    the hand-off card's facts (below)
--   cards.hitRate(g, side)     hits, batons thrown by that side (whole game)
--   cards.winner(m, finish)    the winner card's facts (below)
import "core/tw"
import "core/notation"
import "core/frame"
import "core/pitch"
import "core/match"
import "core/history"

local notation, frame, pitch, cmatch, history = tw.notation, tw.frame, tw.pitch, tw.match, tw.history

local cards = {}

local function team(side, g)
	local t = g and g.teams and g.teams[side]
	return t and t.name or ("Team " .. side)
end
cards.teamName = team

-- "2FB" -> 2, 1, hit; "F" -> 1, 0, hit; "K" -> 0, 0, hit; "2FE" -> 2, 0,
-- hit; "E", "-", "=", "Z" -> 0, 0, no hit. The fourth value is false for
-- "X" (a baton left when the game ended) and "G" (a resign): not throws.
function cards.batonCounts(token)
	if token == "K" then return 0, 0, true, true end
	if token == "X" or token == "G" then return 0, 0, false, false end
	local f, b = 0, 0
	local fs = token:match("^(%d*)F")
	if fs then f = fs == "" and 1 or tonumber(fs) end
	local bs = token:match("(%d*)BE?$")
	if bs then b = bs == "" and 1 or tonumber(bs) end
	return f, b, f + b > 0, true
end

-- Kubbs the batons of sheet turn `turn` toppled (nil when there is no such
-- turn).
function cards.took(g, turn)
	local t = g.sheet.turns[turn]
	if not t then return nil end
	local field, base = 0, 0
	for _, bt in ipairs(t.batons) do
		local f, b = cards.batonCounts(bt.token)
		field, base = field + f, base + b
	end
	return { field = field, base = base }
end

-- Batons a side threw in the whole game and how many were hits.
function cards.hitRate(g, side)
	local hits, thrown = 0, 0
	for _, t in pairs(g.sheet.turns) do
		if t.side == side then
			for _, bt in ipairs(t.batons) do
				local _, _, hit, isThrow = cards.batonCounts(bt.token)
				if isThrow then thrown = thrown + 1 end
				if hit then hits = hits + 1 end
			end
		end
	end
	return hits, thrown
end

-- The hand-off card, before team `setup.side` takes the Playdate (call it
-- after match.setup, so raising and punishment are done):
--   to, toName        the team on turn
--   from, fromName    the team that threw last turn (nil on turn 1)
--   took              { field, base } its batons toppled last turn (nil on turn 1)
--   kubbs             kubbs to throw in first (0 when it starts with batons)
--   batons            batons this turn
--   turn              the turn number
--   base              { top, bottom } standing base kubbs: `from`'s half
--                     (the far end), then `to`'s
--   baseText          the card's line for them, the receiving team's own
--                     first: "YOUR BASE 4 · THEIRS 5" ("BASE 5 V 4" read the
--                     wrong way round: the RC review of 2026-11-15)
--   pieces            the pitch in `to`'s view frame (it throws from y = 0,
--                     the bottom): { x, y, kind = "base"|"field"|"king",
--                     down }: the ten base slots (down = that base kubb is
--                     no longer standing there), every field kubb on the
--                     pitch, then the king
-- and for a team of several players (core/order, docs/PLAYERS.md 5):
--   thrower           the name of the player who throws first (the card is
--                     passed to them)
--   order             this turn's batons by player: { { name, n }, ... }
--   inkaster          the name of the player who throws the kubbs in
function cards.handoff(m, setup)
	local g = m.game
	local to = setup.side
	local from = to == "A" and "B" or "A"
	local c = {
		to = to, toName = team(to, g), turn = g.turn,
		kubbs = setup.kind == "toss" and setup.of or 0,
		batons = g.batonsTotal or 6,
	}
	if g.turn > 1 then
		c.from, c.fromName = from, team(from, g)
		c.took = cards.took(g, g.turn - 1)
	end
	c.base = { #g:baseKubbs(from), #g:baseKubbs(to) }
	c.baseText = { "YOUR BASE " .. c.base[2], "THEIRS " .. c.base[1] }
	local pieces = {}
	-- the ten base slots: standing, or empty (down) once that base kubb is
	-- knocked; then every field kubb on the pitch
	for _, side in ipairs { "A", "B" } do
		for i, bx in ipairs(pitch.baseX) do
			local k = g.kubbs[side:lower() .. i]
			local x, y = frame.point(to, bx, pitch.baseline[side])
			pieces[#pieces + 1] = { id = k.id, x = x, y = y, kind = "base",
				down = not (k.kind == "base" and k.where == "pitch") }
		end
	end
	for _, id in ipairs(g.ids) do
		local k = g.kubbs[id]
		if k.kind == "field" and k.where == "pitch" then
			local x, y = frame.point(to, k.pose.x, k.pose.y)
			pieces[#pieces + 1] = { id = id, x = x, y = y, kind = "field", down = not k.pose.standing }
		end
	end
	local kp = g.king.pose
	local kx, ky = frame.point(to, kp.x, kp.y)
	pieces[#pieces + 1] = { id = "king", x = kx, y = ky, kind = "king", down = false }
	c.pieces = pieces
	if #g.teams[to].players > 1 and setup.thrower then
		c.thrower = setup.thrower.name
		local list, ink = cmatch.turnOrder(m)
		c.order = {}
		for i, e in ipairs(list) do c.order[i] = { name = e.name, n = e.n } end
		c.inkaster = ink and ink.name
	end
	return c
end

-- The pass card inside a team (docs/PLAYERS.md 5), before a throw by a
-- player other than the last one:
--   name       who takes the Playdate
--   team       the team's name
--   level      their throw level (nil when not known)
--   kind       "kubbs" (the kubbs in, and any rethrows) or "batons"
--   from, to   the batons they throw in a row from this one (baton numbers)
function cards.pass(m, setup)
	local g = m.game
	local th = setup.thrower or {}
	local c = { name = th.name or "", team = team(setup.side, g), level = th.level }
	if setup.kind == "toss" then
		c.kind = "kubbs"
	else
		c.kind = "batons"
		c.from, c.to = setup.n, setup.n
		local deal = m.order and m.order.deal or {}
		while deal[c.to + 1] == th.id do c.to = c.to + 1 end
	end
	return c
end

-- The winner card. finish = {year, month, day, hour, min} (the start is
-- m.start; minutes is nil without both):
--   winner, winnerName, how (core/match howText is the sentence), turns,
--   minutes, hits, thrown (the winner's batons)
function cards.winner(m, finish)
	local g = m.game
	local c = { winner = g.winner, winnerName = team(g.winner, g), turns = g.turn }
	if m.start and finish then c.minutes = notation.minutesBetween(m.start, finish) end
	c.hits, c.thrown = cards.hitRate(g, g.winner)
	-- a team of several: each player's hits and batons
	local ps = g.teams[g.winner].players
	if #ps > 1 then
		local stats = history.gameStats(g)
		c.players = {}
		for i, p in ipairs(ps) do
			local st = stats[p.id]
			c.players[i] = { name = p.name, hits = st.hits, thrown = st.batons }
		end
	end
	return c
end

-- The pass card before the defender raises and places punishment kubbs by
-- hand (PASS + PLAY): who takes the Playdate (the defender), how many kubbs
-- it raises (its field kubbs lying), how many punishment kubbs it places,
-- and who it hands the Playdate back to (the attacker, for its batons):
--   side, toName, raise, punish, backName
function cards.settle(g)
	local raise = 0
	for _, k in ipairs(g:fieldKubbs(g.defender)) do
		if not k.pose.standing then raise = raise + 1 end
	end
	return { side = g.defender, toName = team(g.defender, g), raise = raise,
		punish = #g.punishQueue, backName = team(g.attacker, g) }
end

tw.cards = cards
