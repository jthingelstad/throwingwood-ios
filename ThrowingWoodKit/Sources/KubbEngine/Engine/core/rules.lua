-- The turn engine: U.S. National Kubb Championship Rules V4.0 as a pure state
-- machine (DESIGN.md section 6). Pure Lua: no playdate.*.
--
-- The engine knows nothing about physics. It says what is needed next
-- (game:need()) and consumes resolved throws (THROW OUTCOMES, documented in
-- docs/notes/rules-engine.md "Rules engine") and the defender's choices. Everything it does
-- is written to game.sheet (tw.notation) as it happens.
--
--   local g = tw.rules.new{ teams = { A = { name = "Jamie", players = { { name = "Jamie" } } },
--                                     B = { name = "Playdate", players = { { name = "Club" } } } },
--                           surface = "Grass", opening = "2-4-6", first = "A" }
--   local n = g:need()   -- { kind = "toss" | "raise" | "punish" | "baton" | "over", ... }
--   g:toss(outcome) / g:raise(choice) / g:placePunishment(pose) / g:throwBaton(outcome)
--   g:resign(side)
--
-- Kubbs have permanent ids "a1".."a5" (Team A's base kubbs, x = -2..2 on
-- y = 0) and "b1".."b5" (y = 8). The king is "king". A Kid match (0.15.0,
-- rules = "kid": docs/notes/kid-mode.md) has three base kubbs a side, "a1".."a3"
-- and "b1".."b3" at x = -1, 0, 1, and the gentler rules rules.kid lists.
import "core/tw"
import "core/pitch"
import "core/raising"
import "core/notation"

local pitch, raising, notation = tw.pitch, tw.raising, tw.notation
local other = pitch.other
local sort = table.sort

local rules = {}

local Game = {}
Game.__index = Game
rules.Game = Game        -- (core/save restores a saved game with it)
rules.Game = Game

local function fail(msg) error("rules: " .. msg, 3) end

local function copyPose(p) return raising.copyPose(p) end

-- The Kid rules (0.15.0; docs/notes/kid-mode.md). The owner, 2026-11-21: "kid level
-- is for kids to have fun with kubb". A game's rules are "kid" (g.rules) or standard
-- (nil, every game before 0.15). In a Kid game:
--   * three base kubbs a side, at baseX on each baseline;
--   * every kubb and every baton at a kubb is thrown from `line` metres in front of the
--     thrower's own baseline, or from the advantage line when that is nearer the middle
--     (the king shot stays on the baseline, as in the standard rules);
--   * the king knocked down before its time (by a baton or a kubb thrown in) is stood
--     back up where it was and the turn goes on;
--   * a kubb out twice is no punishment kubb: the engine stands it at the fair spot
--     (raising.fairSpot) and nobody chooses;
--   * no throw is illegal: a helicopter counts as thrown.
rules.kid = {
	line = 2,              -- m in front of the baseline every kubb and baton is thrown from
	baseX = { -1, 0, 1 },  -- the base kubbs: the middle three of the standard five spots
}

-- The base kubbs' x positions on each baseline for a game's rules.
function rules.baseXFor(kind)
	if kind == "kid" then return rules.kid.baseX end
	return pitch.baseX
end

-- Batons for a turn: 2-4-6 opening (II.A) or six from the start.
function rules.batonsFor(opening, turn)
	if opening ~= "six" then
		if turn == 1 then return 2 end
		if turn == 2 then return 4 end
	end
	return 6
end

function rules.new(opts)
	opts = opts or {}
	local g = setmetatable({}, Game)
	g.teams = {}
	for _, side in ipairs { "A", "B" } do
		local t = (opts.teams or {})[side] or {}
		local players = {}
		for i, p in ipairs(t.players or { { name = t.name or ("Team " .. side) } }) do
			if type(p) == "string" then p = { name = p } end
			players[i] = { name = p.name, id = p.id }
		end
		g.teams[side] = { name = t.name or ("Team " .. side), players = players }
	end
	notation.assignIds(g.teams)
	g.surface = opts.surface or "Grass"
	g.opening = opts.opening == "six" and "six" or "2-4-6"
	g.first = opts.first == "B" and "B" or "A"
	g.raisePolicy = opts.raisePolicy or "apart"
	-- the Kid rules (rules.kid), or nil: the standard rules, as every game before 0.15
	if opts.rules == "kid" then g.rules = "kid" end
	g.kubbs, g.ids = {}, {}
	for _, side in ipairs { "A", "B" } do
		for i, x in ipairs(rules.baseXFor(g.rules)) do
			local id = side:lower() .. i
			g.kubbs[id] = {
				id = id, kind = "base", half = side, where = "pitch",
				pose = { x = x, y = pitch.baseline[side], standing = true, angle = 0 },
				thrown = 0, established = false,
			}
			g.ids[#g.ids + 1] = id
		end
	end
	g.king = { id = "king", pose = { x = pitch.king.x, y = pitch.king.y, standing = true, angle = 0 } }
	g.hand = { A = {}, B = {} }
	g.sheet = notation.sheet()
	g.turn = 0
	g.winner, g.how = nil, nil
	g:_startTurn()
	return g
end

-- ---------- queries ----------

function Game:player(side, p)
	local ps = self.teams[side].players
	if p == nil then return ps[1].id end
	for _, q in ipairs(ps) do
		if q.id == p or q.name == p then return q.id end
	end
	fail("no player " .. tostring(p) .. " on Team " .. side)
end

-- Kubbs on the pitch, in id order, optionally filtered.
function Game:onPitch(filter)
	local out = {}
	for _, id in ipairs(self.ids) do
		local k = self.kubbs[id]
		if k.where == "pitch" and (not filter or filter(k)) then out[#out + 1] = k end
	end
	return out
end

-- Standing field kubbs in `side`'s half.
function Game:fieldKubbs(side)
	return self:onPitch(function(k) return k.kind == "field" and k.half == side end)
end

function Game:baseKubbs(side)
	return self:onPitch(function(k) return k.kind == "base" and k.half == side end)
end

-- Every kubb of `side`'s half is down: what a king shot needs.
function Game:allDown(side)
	return #self:fieldKubbs(side) == 0 and #self:baseKubbs(side) == 0
end

-- Context for raising/punishment geometry in `half`, without kubb `except`.
function Game:context(half, except)
	local others = {}
	for _, k in ipairs(self:onPitch()) do
		if k.id ~= except then others[#others + 1] = { id = k.id, pose = k.pose, kind = k.kind } end
	end
	return { half = half, king = self.king.pose, others = others }
end

-- Where kubbs are: counts by `where` (pitch, hand, out, punish). Ten always.
function Game:census()
	local c = { pitch = 0, hand = 0, out = 0, punish = 0, total = 0 }
	for _, id in ipairs(self.ids) do
		local w = self.kubbs[id].where
		c[w] = (c[w] or 0) + 1
		c.total = c.total + 1
	end
	return c
end

-- What the engine needs next.
function Game:need()
	local ph = self.phase
	if ph == "over" then
		return { kind = "over", winner = self.winner, how = self.how }
	elseif ph == "toss" or ph == "rethrow" then
		local throwY = pitch.baseline[self.attacker]
		if self.rules == "kid" then throwY = self:kidLineY(self.attacker) end
		return { kind = "toss", side = self.attacker, kubb = self.current, rethrow = ph == "rethrow",
			throwY = throwY, half = self.defender,
			left = #self.firstQueue + #self.rethrowQueue }
	elseif ph == "raise" then
		local k = self.kubbs[self.current]
		local ctx = self:context(self.defender, k.id)
		-- lying (1.4.0): every field kubb of the half still lying, in id order (the first is
		-- `kubb`, the one raised when an action names none); any may be raised next
		-- (Game:raise with an id)
		local lying = {}
		for _, f in ipairs(self:lyingKubbs()) do lying[#lying + 1] = f.id end
		return { kind = "raise", side = self.defender, kubb = k.id, pose = copyPose(k.pose),
			decision = raising.options(k.pose, ctx), lying = lying }
	elseif ph == "punish" then
		return { kind = "punish", side = self.defender, kubb = self.current, half = self.defender }
	elseif ph == "batons" then
		local def = self.defender
		local kingShot = self:allDown(def)
		local targets = {}
		if kingShot then
			targets = { "king" }
		else
			local f = self:fieldKubbs(def)
			if #f == 0 then f = self:baseKubbs(def) end
			for _, k in ipairs(f) do targets[#targets + 1] = k.id end
		end
		local throwY = pitch.baseline[self.attacker]
		if self.advantageY and not kingShot then throwY = self.advantageY end
		if self.rules == "kid" and not kingShot then throwY = self:kidThrowY(self.attacker) end
		return { kind = "baton", side = self.attacker, n = self.batonIndex + 1, of = self.batonsTotal,
			left = self.batonsLeft, kingShot = kingShot, throwY = throwY,
			advantageY = self.advantageY, targets = targets }
	end
end

-- The Kid line of `side` (rules.kid.line in front of its own baseline), world y.
function Game:kidLineY(side)
	local b = pitch.baseline[side]
	return b + (side == "A" and 1 or -1) * rules.kid.line
end

-- The line a Kid game's batons at kubbs are thrown from: the Kid line, or the advantage
-- line when that is nearer the middle.
function Game:kidThrowY(side)
	local y = self:kidLineY(side)
	if self.advantageY and pitch.fromBaseline(side, self.advantageY) > pitch.fromBaseline(side, y) then
		y = self.advantageY
	end
	return y
end

-- ---------- turn flow ----------

function Game:_startTurn()
	self.turn = self.turn + 1
	local att = (self.turn % 2 == 1) and self.first or other(self.first)
	local def = other(att)
	self.attacker, self.defender = att, def
	self.batonsTotal = rules.batonsFor(self.opening, self.turn)
	self.batonsLeft, self.batonIndex = self.batonsTotal, 0
	-- Every field kubb standing now is established (left from an earlier turn).
	for _, k in ipairs(self:onPitch()) do
		k.thrown = 0
		if k.kind == "field" then k.established = true end
	end
	local q = self.hand[att]
	sort(q)
	for _, id in ipairs(q) do
		local k = self.kubbs[id]
		k.thrown, k.established, k.kind = 0, false, "field"
	end
	self.firstQueue, self.rethrowQueue, self.punishQueue = q, {}, {}
	self.hand[att] = {}
	self.firstThrows = 0
	self.roundThrows = 0          -- kubbs thrown in the round not yet judged
	self.judgment = nil           -- what the last judgment did (set by _judge)
	self.lastTosser = nil
	self.tossSeq = 0
	self.sheet:beginTurn(self.turn, att)
	-- II.B.2: the opponent left field kubbs standing in the attacker's own
	-- half; the line runs through the center of the one closest to the
	-- centerline. The inkast cannot legally move them (II.C.4b puts them
	-- back), so it is fixed for the turn.
	self:_advantage()
	self.phase = "toss"
	self:_next()
end

-- The advantage line from the attacker's own field kubbs as they stand now,
-- written to the sheet. _startTurn sets it; core/match calls it again when it
-- settles a carried standing kubb before the turn's first throw.
function Game:_advantage()
	local att = self.attacker
	self.advantageY = nil
	self.sheet:advantage(nil)
	local own = self:fieldKubbs(att)
	if #own > 0 then
		local best
		for _, k in ipairs(own) do
			if not best or pitch.fromBaseline(att, k.pose.y) > pitch.fromBaseline(att, best.pose.y) then best = k end
		end
		self.advantageY = best.pose.y
		self.sheet:advantage(pitch.advantageMeters(att, best.pose.y))
	end
end

-- Pick the phase and current piece from the queues.
function Game:_next()
	if self.phase == "over" then return end
	if self.phase == "toss" or self.phase == "rethrow" then
		if #self.firstQueue > 0 then
			self.phase, self.current = "toss", self.firstQueue[1]
			return
		elseif #self.rethrowQueue > 0 then
			self.phase, self.current = "rethrow", self.rethrowQueue[1]
			return
		end
		self.phase = "raise"
	end
	if self.phase == "raise" then
		for _, k in ipairs(self:fieldKubbs(self.defender)) do
			if not k.pose.standing then
				self.current = k.id
				return
			end
		end
		self.phase = "punish"
	end
	if self.phase == "punish" then
		-- the Kid rules: no punishment kubbs; the engine stands each kubb out twice at
		-- the fair spot, and nobody is asked
		while self.rules == "kid" and #self.punishQueue > 0 do self:_placeFair(self.punishQueue[1]) end
		if #self.punishQueue > 0 then
			self.current = self.punishQueue[1]
			return
		end
		self.phase, self.current = "batons", nil
		self:_inkastPositions()
	end
end

-- Where the turn's kubbs thrown in stand (kept once, as the batons begin: every
-- kubb thrown this turn is raised or placed by then), for the game file's pitch
-- line (core/notation.positionLines). Each kubb a player threw this turn that is
-- on the pitch now, where it stands, in the order of its last throw, with the
-- player who made that throw; a punishment kubb with the player whose token
-- counts its P. Kubbs out of play have none. A turn saved before
-- positions has no inkBy on its kubbs: they go to its one inkaster, or
-- nowhere when it had several.
-- Written as the batons begin; core/match calls it again (it starts the list
-- afresh) when it settles the turn's kubbs before the first baton.
function Game:_inkastPositions()
	local t = self.sheet.current
	if not t then return end
	t.inkastAt = nil
	if #t.inkastOrder == 0 then return end
	local def = self.defender
	local list = {}
	for _, id in ipairs(self.ids) do
		local k = self.kubbs[id]
		if k.where == "pitch" and k.kind == "field" and k.half == def and (k.thrown or 0) > 0 then
			list[#list + 1] = k
		end
	end
	sort(list, function(a, b)
		local sa, sb = a.tossSeq or 0, b.tossSeq or 0
		if sa ~= sb then return sa < sb end
		return a.id < b.id
	end)
	local only = #t.inkastOrder == 1 and t.inkastOrder[1] or nil
	for _, k in ipairs(list) do
		local pid = k.inkBy or only
		if pid and t.inkast[pid] then self.sheet:inkAt(pid, k.pose.x, k.pose.y) end
	end
end

local function removeFrom(list, id)
	for i, v in ipairs(list) do
		if v == id then table.remove(list, i) return true end
	end
	return false
end

-- Game over: the rest of this turn's batons are X.
function Game:_finish(winner, how)
	if self.winner then fail("winner already set") end
	self.winner, self.how = winner, how
	self.phase, self.current = "over", nil
	for _ = 1, self.batonsLeft do self.sheet:baton(nil, "X") end
	self.batonsLeft = 0
end

-- When a game ends before the inkast is done (king toppled by a kubb, or a
-- resign), the inkast token still counts every kubb that was to be thrown,
-- so it says how many kubbs the turn had (kubb.js checks I against the
-- kubbs knocked down last turn). Returns how many were added.
function Game:_completeInkast(pid)
	local pending = #self.firstQueue
	if pending > 0 then self.sheet:ink(pid, "I", pending) end
	return pending
end

-- ---------- kubb tossing (II.C) ----------

local function poseFrom(o, fallback)
	if not o then return copyPose(fallback) end
	return { x = o.x, y = o.y, standing = o.standing and true or false, angle = o.angle or 0, onTop = o.onTop }
end

-- The kubb throwing is judged at the final position (Jamie, 2026-11-13):
-- whether a thrown kubb is in or out is not decided when it stops. Every
-- thrown kubb stays a piece on the pitch at its rest pose (in, out of
-- bounds, short of the middle line, in the thrower's own half) and later
-- kubbs may move it. A round is every kubb queued when it starts (first
-- throws before rethrows, II.C.6); when its last throw has come to rest,
-- _judge rules on every field kubb of the target half by where it lies
-- then.

-- Out for now: a fouled kubb (II.C.4b), or one that cannot be raised in
-- bounds where it lies.
function Game:_outNow(k)
	return k.fouled and true or not raising.canRaise(k.pose, self.defender)
end

-- Where a kubb thrown this turn lies before the round is judged: "in" or
-- "out" (what the judgment would say if the round ended now, before any
-- lowering), or nil when it is not on the pitch.
function Game:liesNow(id)
	local k = self.kubbs[id]
	if not k or k.where ~= "pitch" then return nil end
	return self:_outNow(k) and "out" or "in"
end

-- Lower a kubb resting on another (II.D.6) and count N.
function Game:_settle(k, pid)
	if k.pose.onTop then
		local lower = self.kubbs[k.pose.onTop]
		local lp = lower and lower.pose or self.king.pose
		k.pose = raising.lower(k.pose, lp)
		self.sheet:ink(pid, "N")
		return true
	end
	return false
end

-- The judgment at the end of a round, on every field kubb of the target
-- half as it lies now (II.C.4, II.C.5a/b/c, II.C.6, II.D.6, II.D.11):
--   * a kubb resting on another is lowered beside it (N), unless the kubb
--     under it is itself out (it is lifted away: the upper one lies where
--     it is, no N);
--   * an established field kubb that cannot be raised in bounds is rescued
--     (Q): back to the attacker as a kubb not yet thrown this turn;
--   * a kubb thrown once that cannot be raised in bounds (or that fouled,
--     II.C.4b) is picked up and rethrown in the next round;
--   * a kubb thrown twice that is still out is a punishment kubb (P).
-- Sets self.judgment = { thrown, rethrow, punish, rescue, lowered, lifted }
-- (lifted: ids of kubbs whose support was picked up).
function Game:_judge(pid)
	local def = self.defender
	local cands = self:onPitch(function(k) return k.kind == "field" and k.half == def end)
	local isCand = {}
	for _, k in ipairs(cands) do isCand[k.id] = true end
	local status, pending = {}, {}
	for _, k in ipairs(cands) do
		if k.pose.onTop then pending[#pending + 1] = k
		else status[k.id] = self:_outNow(k) and "out" or "in" end
	end
	local j = { thrown = self.roundThrows, rethrow = 0, punish = 0, rescue = 0, lowered = 0, lifted = {} }
	-- kubbs resting on another, each once the kubb under it is judged (a
	-- support whose own support is never judged counts as in)
	while #pending > 0 do
		local rest, progress = {}, false
		for _, k in ipairs(pending) do
			local sid = k.pose.onTop
			local sup = "in"
			if isCand[sid] then sup = status[sid] end
			if sup == nil then
				rest[#rest + 1] = k
			else
				progress = true
				if sup == "out" then
					k.pose.onTop, k.pose.standing = nil, false
					j.lifted[#j.lifted + 1] = k.id
				elseif self:_settle(k, pid) then
					j.lowered = j.lowered + 1
				end
				status[k.id] = self:_outNow(k) and "out" or "in"
			end
		end
		if not progress then
			-- a ring of kubbs on each other (cannot happen in practice)
			for _, k in ipairs(rest) do
				if self:_settle(k, pid) then j.lowered = j.lowered + 1 end
				status[k.id] = self:_outNow(k) and "out" or "in"
			end
			rest = {}
		end
		pending = rest
	end
	for _, k in ipairs(cands) do
		if status[k.id] == "out" then
			if k.established then
				-- II.C.5a, the rescue
				k.established, k.thrown, k.where = false, 0, "hand"
				self.firstQueue[#self.firstQueue + 1] = k.id
				self.sheet:ink(pid, "Q")
				j.rescue = j.rescue + 1
			elseif k.thrown <= 1 then
				k.where = "out"
				self.rethrowQueue[#self.rethrowQueue + 1] = k.id
				j.rethrow = j.rethrow + 1
			else
				k.where = "punish"
				k.inkBy = pid          -- its position goes on the token that counts its P
				self.punishQueue[#self.punishQueue + 1] = k.id
				-- the Kid rules have no punishment kubbs: no P (Game:_placeFair)
				if self.rules ~= "kid" then self.sheet:ink(pid, "P") end
				j.punish = j.punish + 1
			end
		end
		k.fouled = nil
	end
	self.roundThrows = 0
	self.judgment = j
end

-- outcome: see docs/notes/rules-engine.md "Kubb-toss outcome".
function Game:toss(o, player)
	if self.phase ~= "toss" and self.phase ~= "rethrow" then fail("not tossing now (" .. self.phase .. ")") end
	o = o or {}
	local att, def = self.attacker, self.defender
	local pid = self:player(att, player)
	local k = self.kubbs[self.current]
	removeFrom(self.firstQueue, k.id)
	removeFrom(self.rethrowQueue, k.id)
	self.judgment = nil
	k.thrown = k.thrown + 1
	if k.thrown == 1 then
		self.sheet:ink(pid, "I")
		self.firstThrows = self.firstThrows + 1
	else
		self.sheet:ink(pid, "R")
	end
	self.lastTosser = pid
	self.roundThrows = self.roundThrows + 1
	-- who threw it last, and when (for the inkast positions)
	self.tossSeq = (self.tossSeq or 0) + 1
	k.inkBy, k.tossSeq = pid, self.tossSeq

	-- the Kid rules: the king a kubb thrown in knocks down is stood back up where it was,
	-- and the inkast goes on
	local kidKing = o.kingToppled and self.rules == "kid"
	if kidKing then
		self.sheet:note("a kubb thrown in knocked the king down; stood back up (kid rules)")
	end
	if o.kingToppled and not kidKing then
		k.where, k.kind, k.half = "pitch", "field", def
		k.pose = poseFrom(o.rest, k.pose)
		self:_completeInkast(pid)
		self.sheet:ink(pid, "E")
		self.sheet:note("king toppled by a thrown kubb")
		self:_finish(def, "king toppled by a thrown kubb")
		return
	end

	-- Other pieces it moved. Base kubbs are stood back where they were; a
	-- piece in the thrower's own half makes it II.C.4b. Kubbs thrown this
	-- turn are field kubbs of the target half wherever they lie, so moving
	-- one is never II.C.4b.
	local ownHit = false
	for _, id in ipairs(o.ownHalfHit or {}) do
		local p = self.kubbs[id]
		if p and p.where == "pitch" and p.half == att then ownHit = true end
	end
	local struck = {}
	for id, pose in pairs(o.moved or {}) do
		if id == "king" then
			if not kidKing then
				self.king.pose = poseFrom(pose, self.king.pose)
				self.king.pose.standing = true
			end
		else
			local p = self.kubbs[id]
			if not p then fail("unknown piece " .. tostring(id)) end
			if p.where == "pitch" and p.id ~= k.id then
				if p.half == att then
					ownHit = true
				elseif p.kind == "field" then
					struck[#struck + 1] = { p = p, pose = poseFrom(pose, p.pose) }
				end
			end
		end
	end

	-- Kubbs it struck lie where the throw left them (II.C.4); nothing is
	-- judged until the round is over. When the toss is II.C.4b nothing in
	-- the own half was applied (put back); kubbs it moved in the target half
	-- still stay where they came to rest.
	sort(struck, function(a, b) return a.p.id < b.p.id end)
	for _, s in ipairs(struck) do s.p.pose = s.pose end

	-- The thrown kubb lies where it stopped, a field kubb of the target half
	-- (in or out), until the round is judged.
	k.kind, k.half, k.established = "field", def, false
	k.pose = poseFrom(o.rest, k.pose)
	k.where = "pitch"
	if ownHit then
		-- II.C.4b at the final position: a kubb that touched a field kubb in
		-- the thrower's own half is out whatever later kubbs do to it
		k.fouled = true
		k.pose.onTop = nil
		self.sheet:note("a kubb hit a field kubb in the thrower's own half (II.C.4b)")
	end

	if #self.firstQueue == 0 and #self.rethrowQueue == 0 then self:_judge(pid) end
	self:_next()
end

-- ---------- raising (II.D) ----------

-- The field kubbs of the defender's half still lying, in id order (1.4.0): the kubbs
-- that may be raised now, in any order.
function Game:lyingKubbs()
	local out = {}
	if self.phase ~= "raise" then return out end
	for _, k in ipairs(self:fieldKubbs(self.defender)) do
		if not k.pose.standing then out[#out + 1] = k end
	end
	return out
end

-- The raise of kubb `id` as it lies now (1.4.0): its decision (raising.options, the same
-- as need().decision gives the first) and its context, or nil and why ("not raising",
-- "not lying": no field kubb of the defender's half lying with that id).
function Game:raiseOptions(id)
	if self.phase ~= "raise" then return nil, "not raising" end
	local k = id and self.kubbs[id]
	if not (k and k.where == "pitch" and k.kind == "field" and k.half == self.defender and not k.pose.standing) then
		return nil, "not lying"
	end
	local ctx = self:context(self.defender, k.id)
	return raising.options(k.pose, ctx), ctx, k
end

-- Could kubb `id` be raised on end `which` now (1.4.0)? true, the choice's index; or
-- false and why: "not raising", "not lying", "no end" (no end of it can stand in
-- bounds), "that end" (`which` is not one of the decision's choices). which nil: the
-- side's choice (policy), always one when the kubb has any.
function Game:canRaise(id, which)
	local dec, why = self:raiseOptions(id)
	if not dec then return false, why end
	if #dec.choices == 0 then return false, "no end" end
	if which == nil then return true, nil end
	for i, c in ipairs(dec.choices) do
		if c.which == which then return true, i end
	end
	return false, "that end"
end

-- choice: an index into need().decision.choices, or nil for the automatic
-- chooser (game.raisePolicy, or `policy`). id (1.4.0): the lying field kubb to raise,
-- any of need().lying, its choice an index into its own decision (Game:raiseOptions);
-- nil: need().kubb, as before. Raising one kubb can change another's ends (a kubb
-- stood up in the way), so each raise reads the pitch as it is then.
function Game:raise(choice, policy, id)
	if self.phase ~= "raise" then fail("not raising now (" .. self.phase .. ")") end
	local k = self.kubbs[self.current]
	if id ~= nil and id ~= k.id then
		local dec, why = self:raiseOptions(id)
		if not dec then fail("no lying kubb " .. tostring(id) .. " to raise (" .. why .. ")") end
		k = self.kubbs[id]
	end
	local ctx = self:context(self.defender, k.id)
	local dec = raising.options(k.pose, ctx)
	if #dec.choices == 0 then fail("kubb " .. k.id .. " cannot be raised in bounds") end
	if choice == nil then choice = raising.choose(dec, ctx, policy or self.raisePolicy) end
	local c = dec.choices[choice]
	if not c then fail("no raising choice " .. tostring(choice)) end
	k.pose = copyPose(c.pose)
	k.pose.standing, k.pose.onTop = true, nil
	self:_next()
	return c
end

-- Raise kubb `id` on its end `which` (1.4.0; nil: the side's choice, `policy`): the
-- choice made. Fails as Game:raise does when it cannot (Game:canRaise says first).
function Game:raiseKubb(id, which, policy)
	local ok, i = self:canRaise(id, which)
	if not ok then fail("cannot raise " .. tostring(id) .. " on end " .. tostring(which) .. " (" .. tostring(i) .. ")") end
	return self:raise(i, policy, id)
end

-- Raise every pending kubb automatically.
function Game:raiseAll(policy)
	while self.phase == "raise" do self:raise(nil, policy) end
end

-- ---------- punishment kubbs (II.D.11) ----------

function Game:placePunishment(pose)
	if self.phase ~= "punish" then fail("no punishment kubb to place (" .. self.phase .. ")") end
	local k = self.kubbs[self.current]
	local p = { x = pose.x, y = pose.y, standing = true, angle = pose.angle or 0 }
	local ok, why = raising.punishmentCheck(p, self:context(self.defender, k.id))
	if not ok then return false, why end
	removeFrom(self.punishQueue, k.id)
	k.pose, k.where, k.kind, k.half = p, "pitch", "field", self.defender
	self:_next()
	return true
end

function Game:autoPunishment(policy)
	local k = self.kubbs[self.current]
	local pose = raising.autoPunishment(self:context(self.defender, k.id), policy)
	if not pose then fail("no valid punishment spot") end
	return self:placePunishment(pose)
end

-- The Kid rules: kubb `id`, out twice, stood at the fair spot (raising.fairSpot) for
-- nobody's advantage. Kept on the sheet as a note and in t.placed (the turn's pitch line
-- is then left out: the kubb does not stand where it was thrown).
function Game:_placeFair(id)
	local k = self.kubbs[id]
	local pose = raising.fairSpot(self:context(self.defender, k.id))
		or raising.autoPunishment(self:context(self.defender, k.id))
	if not pose then fail("no spot for kubb " .. id) end
	removeFrom(self.punishQueue, k.id)
	k.pose, k.where, k.kind, k.half = pose, "pitch", "field", self.defender
	local t = self.sheet.current
	t.placed = (t.placed or 0) + 1
	self.sheet:note("a kubb out twice was stood at the fair spot, no punishment kubb (kid rules)")
end

-- ---------- batons (II.B) ----------

local function set(list)
	local s = {}
	for _, v in ipairs(list or {}) do s[v] = true end
	return s
end

-- outcome: see docs/notes/rules-engine.md "Baton outcome".
function Game:throwBaton(o, player)
	if self.phase ~= "batons" then fail("not throwing batons now (" .. tostring(self.phase) .. ")") end
	o = o or {}
	local att, def = self.attacker, self.defender
	local pid = self:player(att, player)
	local n = self.batonIndex + 1
	self.batonIndex, self.batonsLeft = n, self.batonsLeft - 1
	local kingShot = self:allDown(def)
	local toppled = set(o.toppled)
	local kingDown = o.kingToppled or toppled.king
	toppled.king = nil
	-- the Kid rules: no throw is illegal (a helicopter counts as thrown), and the king
	-- knocked down before its time is stood back up where it was (kingBack) while the
	-- throw counts as it would otherwise
	local kingBack = false
	if self.rules == "kid" then
		if o.illegal then self.sheet:note("b" .. n .. " helicopter; counted (kid rules)") end
		o = { toppled = o.toppled, moved = o.moved, ownHalfHit = o.ownHalfHit }
		if kingDown and not kingShot then
			kingBack, kingDown = true, false
			self.sheet:note("b" .. n .. " knocked the king down early; stood back up (kid rules)")
		end
	end
	for id in pairs(toppled) do
		local k = self.kubbs[id]
		if not k then fail("unknown piece " .. tostring(id)) end
		if k.where ~= "pitch" then fail("piece " .. id .. " is not on the pitch") end
	end

	local function earlyKing(token, why, at)
		self.sheet:baton(pid, token, at)
		self.sheet:note("b" .. n .. " " .. why)
		self:_finish(def, "king toppled early")
	end

	-- II.B.1: an illegal throw (helicopter). Everything is put back and the
	-- baton is forfeited. Interpretation: a king it topples before every
	-- kubb is down still loses the game; on a king shot it is stood up.
	if o.illegal then
		if kingDown and not kingShot then
			return earlyKing("E", "illegal throw toppled the king early")
		end
		self.sheet:baton(pid, "Z")
		return self:_afterBaton()
	end

	-- II.B.11: field kubbs in the attacker's own half hit by its baton.
	local own = false
	for _, id in ipairs(o.ownHalfHit or {}) do
		local k = self.kubbs[id]
		if k and k.where == "pitch" and k.kind == "field" and k.half == att then own = true end
	end
	for id in pairs(toppled) do
		local k = self.kubbs[id]
		if k.kind == "field" and k.half == att then own = true end
	end
	for id in pairs(o.moved or {}) do
		local k = self.kubbs[id]
		if k and k.where == "pitch" and k.kind == "field" and k.half == att then own = true end
	end
	if own then
		if kingDown and not kingShot then
			return earlyKing("E", "baton hit its own half and toppled the king early")
		end
		self.sheet:baton(pid, "Z")
		self.sheet:note("b" .. n .. " hit a field kubb in the thrower's own half; all put back (II.B.11)")
		return self:_afterBaton()
	end

	-- A legal throw.
	local standingAfter = 0
	for _, k in ipairs(self:fieldKubbs(def)) do
		if not toppled[k.id] then standingAfter = standingAfter + 1 end
	end
	local f, b, early = 0, 0, 0
	local fAt, bAt = {}, {}   -- where the kubbs the token counts stood before the throw
	local ids = {}
	for id in pairs(toppled) do ids[#ids + 1] = id end
	sort(ids)
	for _, id in ipairs(ids) do
		local k = self.kubbs[id]
		if k.half == def and k.kind == "field" then
			f = f + 1
			fAt[#fAt + 1] = { x = k.pose.x, y = k.pose.y }
			k.where = "hand"
			self.hand[def][#self.hand[def] + 1] = id
		elseif k.half == def and k.kind == "base" then
			if standingAfter > 0 then
				early = early + 1   -- II.B.4a: raised where it was, still a base kubb
			else
				b = b + 1
				bAt[#bAt + 1] = { x = k.pose.x, y = k.pose.y }
				k.where = "hand"
				self.hand[def][#self.hand[def] + 1] = id
			end
		end
		-- An attacker's own base kubb toppled: stood back up (nothing applied).
	end
	-- Pieces moved without toppling stay where they came to rest, unless
	-- pushed out of bounds (II.B.7: returned to where they were).
	local pushedOut = 0
	for id, pose in pairs(o.moved or {}) do
		if not toppled[id] then
			local piece = id == "king" and self.king or self.kubbs[id]
			if piece and (id == "king" or piece.where == "pitch") and not (id == "king" and (kingDown or kingBack)) then
				if pitch.onPitch(pose.x, pose.y) then
					piece.pose = { x = pose.x, y = pose.y, standing = true, angle = pose.angle or piece.pose.angle or 0 }
				else
					pushedOut = pushedOut + 1
				end
			end
		end
	end
	if early > 0 then
		self.sheet:note("b" .. n .. " toppled " .. (early == 1 and "a base kubb" or (early .. " base kubbs"))
			.. " early; raised (II.B.4a)")
	end
	if pushedOut > 0 then
		self.sheet:note("b" .. n .. " pushed " .. (pushedOut == 1 and "a kubb" or (pushedOut .. " kubbs"))
			.. " out without toppling; put back (II.B.7)")
	end

	for _, p in ipairs(bAt) do fAt[#fAt + 1] = p end
	if kingShot then
		if kingDown then
			self.sheet:baton(pid, "K")
			self:_finish(att, "king")
			return
		end
		self.sheet:baton(pid, "=")
		return self:_afterBaton()
	end
	if kingDown then
		return earlyKing(notation.hitToken(f, b, true), "toppled the king early", fAt)
	end
	self.sheet:baton(pid, notation.hitToken(f, b, false), fAt)
	return self:_afterBaton()
end

function Game:_afterBaton()
	if self.phase == "over" then return end
	if self.batonsLeft <= 0 then self:_startTurn() end
end

-- ---------- resign ----------

-- Resign from the menu, on the resigning team's own turn: `G`, then X for
-- the batons left. An unfinished inkast is written in full (see
-- _completeInkast) with a note.
function Game:resign(side, player)
	if self.phase == "over" then fail("the game is over") end
	side = side or self.attacker
	if side ~= self.attacker then fail("a team resigns on its own turn") end
	local pid = self:player(side, player)
	if self.phase == "toss" or self.phase == "rethrow" then
		local tosser = self.lastTosser or pid
		local added = self:_completeInkast(tosser)
		if added > 0 or #self.rethrowQueue > 0 then self.sheet:note("resigned during the inkast") end
	end
	self.sheet:baton(pid, "G")
	self:_finish(other(side), "resigned")
end

tw.rules = rules
