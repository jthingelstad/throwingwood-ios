-- A finished match played again (docs/CLIENT.md "Replays"; Jamie, 2026-11-16: "When a
-- game is finished playing on a pitch I'd like the URL to allow people to come and watch
-- a replay of the match."). Not a video: the match is set out again from its options and
-- every committed action goes through this engine in order, the same throws with the
-- same physics. What it needs is the newMatch options, the hash at the start, and each
-- action with the hash after it: the pitch server's `meta` and log (docs/PITCH.md).
--
--   local r = replay.new { setup = <newMatch options>, h0 = "<hash>", log = { { a = action, h = "<hash>" }, ... } }
--   replay.new { start = "<snapshot>", h0 = ..., log = ... } sets out from the match's first
--   snapshot instead: a match kept after it was played, from its recorded start
--   (tools/backfill-replay.mjs), whose document had no options.
--   r:step()   the next action: { ok, recording?, need, action }
--   r:back()   to the start of the previous turn (from the snapshot kept there)
--   r:info()   { i, total, turn, thrown, throws, differs, done } (and since 0.7.2 the checks:
--              forged, outOfBounds, refusedAt and the rest, below)
--   r:finish() every action left; the info
--   r:document() the pitch document of the finished match (below)
--
-- Checking a shared match (docs/SESSION.md "What a server can prove"), options of new:
--   checkCpu = true     before each of the computer's throws the engine makes its own from
--                       the snapshot before it (Session:cpuAction); one that differs marks
--                       the replay `forged`, with `forgedAt` the first one's log index
--                       (0-based) and `forgedWhy` the first field that differs
--   checkThrows = true  each person's throw is held to what the dial could give
--                       (session/check); one that is not marks `outOfBounds`, with
--                       `outOfBoundsAt` and `outOfBoundsWhy`
--   document = true     build the pitch document as it goes (r:document; or { ids, host });
--                       also keeps the hash after each action (r.hashes)
--   names = "check"     refuse a replay whose names session/namecheck does not allow
--                       (since 0.13.4; absent, no check, as before)
-- A refused action sets `refusedAt` (the first one's index) as well as `differs`.
--
-- The session it plays in belongs to nobody: no side and not the computer, so nothing in
-- it can act but the log (session/api refuses every action while a replay is loaded).
-- A hash that disagrees (an old match after a physics change) or an action this engine
-- refuses marks the replay `differs` and it goes on: a refused action is passed over.
import "core/tw"
import "version"
import "session/json"
import "session/session"
import "session/check"
import "pitch/lobby"
import "session/namecheck"

local session, check, json, lobby = tw.web.session, tw.web.check, tw.web.json, tw.shared.lobby
local NULL = json.null

local replay = {}

local Replay = {}
Replay.__index = Replay

replay.NOBODY = { sides = {}, cpu = false }

local startDoc, commitDoc -- below: the finished document

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

function replay.new(d)
	assert(type(d) == "table" and (type(d.setup) == "table" or type(d.start) == "string")
		and type(d.log) == "table", "a replay needs its setup (or its start) and its log")
	-- names = "check" (since 0.13.4): refused, before anything is set out, when a name
	-- in it (its setup or start, its snap and players if given, a thrower's id) is not
	-- one session/namecheck allows: for a replay that came from someone else
	if d.names ~= nil then
		tw.web.namecheck.strict(d.names, "replayLoad", function() return tw.web.namecheck.replay(d) end)
	end
	local r = setmetatable({}, Replay)
	r.setup, r.h0, r.log = d.setup, d.h0, d.log
	r.total = #d.log
	r.throws = 0
	for _, e in ipairs(d.log) do
		assert(type(e) == "table" and type(e.a) == "table", "a log entry is { a, h }")
		if e.a.type == "throw" then r.throws = r.throws + 1 end
	end
	r.differs = false
	r.marks = {}
	r.checkCpu, r.checkThrows = d.checkCpu == true, d.checkThrows == true
	r.keepDoc = d.document == true or type(d.document) == "table"
	r.forged, r.outOfBounds = false, false
	r.cpuChecked, r.throwsChecked = 0, 0
	if type(d.start) == "string" then
		r.start = d.start
		r.s = session.restore(d.start, replay.NOBODY)
	else
		local o = copy(r.setup)
		o.mode = "match"
		r.s = session.new(o)
	end
	r.s:setControl(replay.NOBODY)
	if r.h0 ~= nil and r.s:hash() ~= r.h0 then r.differs = true end
	r.i, r.thrown = 0, 0
	if r.keepDoc then
		r.hashes = {}
		r.firstSnap = r.s:snapshot()
		r.firstHash = session.fnv(r.firstSnap)
		r.doc, r.docWhy = startDoc(r, d.document)
	end
	r:mark()
	return r
end

function Replay:turn()
	return self.s.m.game.turn
end

-- A turn's start, kept the first time the replay gets there: where BACK goes.
function Replay:mark()
	local last = self.marks[#self.marks]
	if last and (self.i <= last.i or self:turn() == last.turn) then return end
	self.marks[#self.marks + 1] = { i = self.i, thrown = self.thrown, turn = self:turn(), snap = self.s:snapshot() }
end

function Replay:done()
	return self.i >= self.total
end

-- The checks before an action (the options above).
function Replay:checkAction(a, at)
	local s = self.s
	if a.type ~= "throw" or s.kind ~= "match" or s.phase ~= "throw" or not s.setup then return end
	if session.cpuThrow(s, s.setup) then
		if not self.checkCpu then return end
		self.cpuChecked = self.cpuChecked + 1
		local ok, want = pcall(check.cpuAction, s)
		if not ok or not check.same(a, want) then
			if not self.forged then
				self.forged, self.forgedAt = true, at
				self.forgedWhy = ok and ("not the computer's throw: " .. tostring(check.firstDiff(a, want)))
					or ("the computer's throw could not be made: " .. tostring(want))
			end
		end
	elseif self.checkThrows then
		self.throwsChecked = self.throwsChecked + 1
		local r = check.throw(s, a)
		if not r.ok and not self.outOfBounds then
			self.outOfBounds, self.outOfBoundsAt, self.outOfBoundsWhy = true, at, r.why
		end
	end
end

-- The next action in the log, through this engine. `standing` is the kubbs standing in
-- each half before and after it (Session:standing).
function Replay:step()
	if self:done() then return { ok = false, done = true, need = self.s:need() } end
	local e = self.log[self.i + 1]
	local before = self.s:standing()
	if type(e.a) == "table" then self:checkAction(e.a, self.i) end
	local ok, out = pcall(self.s.apply, self.s, e.a)
	self.i = self.i + 1
	if e.a.type == "throw" then self.thrown = self.thrown + 1 end
	local good = ok and type(out) == "table" and out.ok ~= false
	local snap, hash = nil, nil
	if self.keepDoc or e.h ~= nil then
		snap = self.s:snapshot()
		hash = session.fnv(snap)
	end
	if not good then
		self.differs = true
		if self.refusedAt == nil then self.refusedAt = self.i - 1 end
	elseif e.h ~= nil and hash ~= e.h then
		self.differs = true
	end
	if self.keepDoc then
		self.hashes[self.i] = hash
		if self.s.phase == "over" and self.overAt == nil then self.overAt = self.i end
		if good then commitDoc(self, e.a, snap, hash) else self.doc, self.docWhy = nil, "action " .. (self.i - 1) .. " was refused" end
	end
	self:mark()
	return { ok = good, recording = good and out.recording or nil, need = self.s:need(), action = e.a,
		standing = { before = before, after = self.s:standing() } }
end

-- Every action left, then the info.
function Replay:finish()
	while not self:done() do self:step() end
	return self:info()
end

-- The document is built once, forward: going back ends it (the checks keep what they found).
function Replay:wentBack()
	if self.keepDoc then self.doc, self.docWhy, self.overAt = nil, "the replay went back", nil end
end

-- Back to the start of the previous turn: the turn before the one the replay is in, or
-- the start of the match from the first turn.
function Replay:back()
	local cur = 1
	for k = #self.marks, 1, -1 do
		if self.marks[k].i <= self.i then cur = k; break end
	end
	local m = self.marks[math.max(1, cur - 1)]
	self:wentBack()
	self.s = session.restore(m.snap, replay.NOBODY)
	self.i, self.thrown = m.i, m.thrown
	return m
end

-- From the very start again.
function Replay:rewind()
	local m = self.marks[1]
	self:wentBack()
	self.s = session.restore(m.snap, replay.NOBODY)
	self.i, self.thrown = m.i, m.thrown
end

function Replay:info()
	return { i = self.i, total = self.total, turn = self:turn(), thrown = self.thrown, throws = self.throws,
		differs = self.differs, done = self:done(), over = self.s.phase == "over",
		refusedAt = self.refusedAt,
		forged = self.forged, forgedAt = self.forgedAt, forgedWhy = self.forgedWhy,
		outOfBounds = self.outOfBounds, outOfBoundsAt = self.outOfBoundsAt, outOfBoundsWhy = self.outOfBoundsWhy,
		cpuChecked = self.cpuChecked, throwsChecked = self.throwsChecked }
end

-- The pitch document a finished match would have, with its full match (docs/PITCH.md
-- "The full match"), built by the pitch's own reducers: the teams joined, the options set, START
-- with the first snapshot, then (in step) every action committed with the snapshot and
-- hash after it, over on the one that ends the match. new's `document` = true or { ids =
-- { A = { ... }, B = { ... } }, host }: the members' ids in throwing order (default each
-- player's key, else the side and number, "A1") and the host (default the first person).
function startDoc(r, o)
	o = type(o) == "table" and o or {}
	local setup = r.setup
	if not setup then
		local ok, why = session.startCheck(r.start)
		if not ok then return nil, why end
		setup = session.setupOf(r.start)
	end
	local opts = r.s.opts
	if #opts.cpu > 1 then return nil, "a match of the computer against itself has no room" end
	local cpu = opts.cpu[1]
	local ids, members, players = o.ids or {}, {}, { A = {}, B = {} }
	local doc = nil
	for _, side in ipairs { "A", "B" } do
		if side ~= cpu then
			for i, p in ipairs(opts.teams[side].players) do
				if p.cpu then
					-- a computer player in a team (0.17.0): a computer seat, by the host's
					-- addComputer. The seat keeps the level the host gave it (the setup's entry),
					-- the level it throws at is the match's: in a Kid match every computer is the
					-- Kid computer (opts says "kid"), never a seat's level. A setup that no
					-- longer has it (a start's own options, already the Kid level) sits at club
					local given = type(setup.teams) == "table" and type(setup.teams[side]) == "table"
						and type(setup.teams[side].players) == "table" and setup.teams[side].players[i] or nil
					local level = "club"
					for _, lv in ipairs(lobby.SEAT_LEVELS) do
						if lv == p.level or (type(given) == "table" and lv == given.level) then level = lv end
					end
					local d2 = lobby.addComputer(doc, side, level, i, p.name)
					if not d2 then return nil, "a computer player cannot sit on side " .. side end
					doc = d2
					local seat = doc.teams[side][#doc.teams[side]]
					players[side][i] = { id = seat, name = p.name, cpu = true, level = level }
				else
					local id = (ids[side] and ids[side][i]) or p.key or (side .. i)
					if type(id) ~= "string" then return nil, "a member id is a string" end
					members[#members + 1] = { id = id, me = { name = p.name, level = p.level, engine = tw.engine.version } }
					players[side][i] = { id = id, name = p.name }
					doc = lobby.joinTeam(doc, id, side)
					if not doc then return nil, "member " .. id .. " cannot join side " .. side end
				end
			end
		end
	end
	local options = {}
	for k in pairs(lobby.OPTION_DEFAULTS) do options[k] = opts[k] end
	doc = lobby.setOptions(doc, options) or doc
	local host = o.host
	if not host then
		for _, side in ipairs { "A", "B" } do
			for _, p in ipairs(players[side]) do if not host and not p.cpu then host = p.id end end
		end
	end
	if not host then return nil, "a match with no person has no room" end
	doc = lobby.startMatch(doc, { snap = r.firstSnap, hash = r.firstHash, players = players, cpu = cpu or NULL,
		host = host, setup = setup, members = members })
	if not doc then return nil, "START refused" end
	return doc
end

function commitDoc(r, a, snap, hash)
	if not r.doc then return end
	-- docSizes: the log's entry sizes kept from commit to commit, so the log budget's
	-- measure (lobby.docSize, the same number) does not encode the whole log each action
	r.docSizes = r.docSizes or {}
	local doc = lobby.commitAction(r.doc, { n = r.doc.n, seq = r.i, snap = snap, hash = hash, action = a,
		over = r.s.phase == "over" }, r.docSizes)
	if doc then r.doc = doc else r.doc, r.docWhy = nil, "action " .. r.i .. " not committed" end
end

-- The finished document: the replay played to its end, every action taken and the match
-- over at the last. Returns the document (json.encode it), or nil and why.
function Replay:document()
	if not self.keepDoc then return nil, "make the replay with document" end
	if not self:done() then return nil, "play the replay to its end first" end
	if self.refusedAt ~= nil then return nil, "action " .. self.refusedAt .. " was refused" end
	if self.total == 0 or self.overAt ~= self.total then return nil, "the match is not over at its last action" end
	if not self.doc then return nil, self.docWhy end
	return self.doc
end

tw.web.replay = replay
