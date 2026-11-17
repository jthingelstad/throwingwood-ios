-- A finished match played again (docs/CLIENT.md "Replays"; Jamie, 2026-11-16: "When a
-- game is finished playing on a pitch I'd like the URL to allow people to come and watch
-- a replay of the match."). Not a video: the match is set out again from its options and
-- every committed action goes through this engine in order, the same throws with the
-- same physics. The pitch's document keeps what it needs (src/net/lobby.js): the
-- newMatch options, the hash at the start, and each action with the hash after it.
--
--   local r = replay.new { setup = <newMatch options>, h0 = "<hash>", log = { { a = action, h = "<hash>" }, ... } }
--   replay.new { start = "<snapshot>", h0 = ..., log = ... } sets out from the match's first
--   snapshot instead: a match kept after it was played, from its recorded start
--   (tools/backfill-replay.mjs), whose document had no options.
--   r:step()   the next action: { ok, recording?, need, action }
--   r:back()   to the start of the previous turn (from the snapshot kept there)
--   r:info()   { i, total, turn, thrown, throws, differs, done }
--
-- The session it plays in belongs to nobody: no side and not the computer, so nothing in
-- it can act but the log (lua/web/api refuses every action while a replay is loaded).
-- A hash that disagrees (an old match after a physics change) or an action this engine
-- refuses marks the replay `differs` and it goes on: a refused action is passed over.
import "core/tw"
import "web/session"

local session = tw.web.session

local replay = {}

local Replay = {}
Replay.__index = Replay

replay.NOBODY = { sides = {}, cpu = false }

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

function replay.new(d)
	assert(type(d) == "table" and (type(d.setup) == "table" or type(d.start) == "string")
		and type(d.log) == "table", "a replay needs its setup (or its start) and its log")
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
	if type(d.start) == "string" then
		r.s = session.restore(d.start, replay.NOBODY)
	else
		local o = copy(r.setup)
		o.mode = "match"
		r.s = session.new(o)
	end
	r.s:setControl(replay.NOBODY)
	if r.h0 ~= nil and r.s:hash() ~= r.h0 then r.differs = true end
	r.i, r.thrown = 0, 0
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

-- The next action in the log, through this engine.
function Replay:step()
	if self:done() then return { ok = false, done = true, need = self.s:need() } end
	local e = self.log[self.i + 1]
	local ok, out = pcall(self.s.apply, self.s, e.a)
	self.i = self.i + 1
	if e.a.type == "throw" then self.thrown = self.thrown + 1 end
	local good = ok and type(out) == "table" and out.ok ~= false
	if not good then
		self.differs = true
	elseif e.h ~= nil and self.s:hash() ~= e.h then
		self.differs = true
	end
	self:mark()
	return { ok = good, recording = good and out.recording or nil, need = self.s:need(), action = e.a }
end

-- Back to the start of the previous turn: the turn before the one the replay is in, or
-- the start of the match from the first turn.
function Replay:back()
	local cur = 1
	for k = #self.marks, 1, -1 do
		if self.marks[k].i <= self.i then cur = k; break end
	end
	local m = self.marks[math.max(1, cur - 1)]
	self.s = session.restore(m.snap, replay.NOBODY)
	self.i, self.thrown = m.i, m.thrown
	return m
end

-- From the very start again.
function Replay:rewind()
	local m = self.marks[1]
	self.s = session.restore(m.snap, replay.NOBODY)
	self.i, self.thrown = m.i, m.thrown
end

function Replay:info()
	return { i = self.i, total = self.total, turn = self:turn(), thrown = self.thrown, throws = self.throws,
		differs = self.differs, done = self:done() }
end

tw.web.replay = replay
