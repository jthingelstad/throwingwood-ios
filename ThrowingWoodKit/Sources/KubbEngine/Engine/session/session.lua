-- The web session (docs/SESSION.md): a practice pitch or a match, behind a
-- few coarse calls. Pure Lua 5.4 over the vendored core.
--
-- This is the Playdate's scenes/match.lua and scenes/settle.lua with the
-- screen taken out (../../playdate-kubb), over session/throw (its throw
-- scene). What the Playdate showed as cards, rails and flags is returned as
-- data; what it read from the d-pad and the crank comes in as calls.
--
-- Sharing (DESIGN 4.3): the state that matters is the match (core/save),
-- the session's options, a throw counter and the aim memory carried from
-- one throw to the next. Every random draw is a fresh core/autothrow rng
-- seeded from the match seed, a purpose and a counter held in that state:
--   the computer's throw   mix(seed, 1, throws)
--   the wind of a turn     mix(seed, 2, turn)
--   the gust of a throw    mix(seed, 3, throws)
-- so a session restored from a snapshot draws exactly what the original
-- would have. (The Playdate keeps one rng per purpose running instead; the
-- draws are the same kind, not the same numbers.)
import "core/tw"
import "core/match"
import "core/cards"
import "core/save"
import "core/autothrow"
import "core/wind"
import "core/raising"
import "core/frame"
import "core/pitch"
import "core/world"
import "core/quat"
import "core/swing"
import "core/throwplan"
import "core/camera"
import "core/names"
import "core/notation"
import "core/gamefile"
import "version"
import "session/json"
import "session/throw"

local cmatch, cards, save, autothrow, wind = tw.match, tw.cards, tw.save, tw.autothrow, tw.wind
local raising, frame, pitch, quat, swing, plan = tw.raising, tw.frame, tw.pitch, tw.quat, tw.swing, tw.plan
local camera = tw.camera
local notation, gamefile = tw.notation, tw.gamefile
local json, throw = tw.web.json, tw.web.throw

local fmt, upper = string.format, string.upper
local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

local session = {}
session.version = tw.engine.version
session.snapshotVersion = 1

-- ---------- what the host sets at start-up ----------

-- The client label written into every game file the session makes ("Scored by"):
-- what the host is and its version, like "web 0.4.2". Not in the snapshot, so it
-- never changes a hash.
session.client = "kubb-engine " .. tw.engine.version

function session.setClient(label)
	assert(type(label) == "string" and #label >= 1 and #label <= 40 and label:match("^[%w%.%-%+ ]+$")
		and not label:match("^ ") and not label:match(" $"),
		"setClient: a label of 1 to 40 letters, digits, spaces, dots, hyphens or pluses, like \"web 0.4.2\"")
	session.client = label
	return label
end

-- The host's tune: tune/<name>.lua, its values for the core's tune tables (put in
-- once, here) and the session's dial and throw tables. One per Lua state, chosen
-- before the first new or restore; it cannot change after.
session.tuneName = nil

function session.useTune(name)
	assert(type(name) == "string" and name:match("^[a-z][a-z0-9]*$"), "useTune: a tune name, like \"pointer\"")
	if session.tuneName then
		assert(session.tuneName == name, "the tune is already " .. session.tuneName .. "; it cannot change")
		return name
	end
	import("tune/" .. name)
	local t = tw.tune and tw.tune[name]
	assert(t, "no tune " .. name)
	t.apply()
	tw.web.tune = t
	session.tuneName = name
	return name
end

local function needTune()
	assert(session.tuneName, "no tune: call useTune first")
end

-- ---------- words ----------

-- render/hud.lua hud.short, line for line: the match's ruling (m.text) as
-- the result flag's words.
local SHORT = {
	{ "^king down early", "KING TOO EARLY: GAME OVER" }, { "^king down", "KING DOWN" }, { "^resigned", "RESIGNED" },
	{ "^missed the king", "KING STANDS" }, { "^missed", "MISS" }, { "^helicopter", "HELICOPTER: DOESN'T COUNT" },
	{ "^own%-half kubb hit", "OWN HALF HIT: PUT BACK" }, { "^own half hit", "OWN HALF HIT: KUBB OUT" },
	{ "^kubb in for now", "IN FOR NOW" }, { "^kubb out for now", "OUT FOR NOW" },
	{ "^kubb in", "IN" }, { "^all in", "ALL IN" }, { "^kubb out: rethrown", "OUT: THROW AGAIN" },
	{ "^(%d+) out: rethrown", "%1 OUT: THROW AGAIN" }, { "^out twice", "OUT TWICE: PUNISHMENT" },
	{ "^(%d+) punishment", "%1 PUNISHMENT KUBBS" }, { "^on a kubb", "ON A KUBB: LOWERED" }, { "rescue", "RESCUE" },
}
function session.short(s)
	if not s then return nil end
	local first = s:match("^[^;]*")
	for _, r in ipairs(SHORT) do
		if first:find(r[1]) then return (first:gsub("^.*$", function(m) return (m:gsub(r[1] .. ".*$", r[2])) end)) end
	end
	if first:find("down$") then
		local n = 0
		for c in first:gmatch("(%d*) ?[fb]%a+ kubbs?") do n = n + (c == "" and 1 or tonumber(c)) end
		if n > 0 then return n .. " DOWN" end
	end
	return first:upper():sub(1, 12)
end

-- scenes/settle.lua whyLabel.
local WHY = {
	["not in the half"] = "NOT IN THE HALF",
	["closer than a baton length to the king"] = "TOO NEAR THE KING",
	["closer than a baton length to a stake"] = "TOO NEAR A STAKE",
}
local function whyLabel(why)
	if not why then return nil end
	if WHY[why] then return WHY[why] end
	if why:find("^overlaps") then return "ON A KUBB" end
	return upper(why)
end

-- ---------- numbers and randomness ----------

local function mix(seed, purpose, n)
	return ((seed * 0x9E3779B1) ~ (purpose * 0x85EBCA6B) ~ (n * 0xC2B2AE35)) & 0x7fffffff
end
session.mix = mix

local function rngFor(s, purpose, n)
	return autothrow.rng(mix(s.seed, purpose, n))
end

-- A number from JSON as a float (JavaScript writes 3.0 as 3).
local function F(v)
	if v == nil then return nil end
	return v + 0.0
end
-- A number from JSON as an integer.
local function I(v)
	if v == nil then return nil end
	return math.tointeger(v) or floor(v + 0.5)
end

local function fnv(text)
	local h = 0x811c9dc5
	for i = 1, #text do
		h = ((h ~ text:byte(i)) * 0x01000193) & 0xffffffff
	end
	return fmt("%08x", h)
end
session.fnv = fnv

local function viewPose(side, p)
	if not p then return nil end
	local v = frame.pose(side, p)
	return { x = v.x, y = v.y, standing = v.standing and true or false, angle = v.angle }
end

-- ---------- options ----------

local SURFACES = { grass = "Grass", sand = "Sand", snow = "Snow" }

local function surfaceKey(name)
	name = string.lower(name or "grass")
	if not SURFACES[name] then name = "grass" end
	return name
end

-- The match options, checked and filled in (a plain table: it goes into the snapshot).
local function matchOptions(o)
	local out = {}
	out.surface = surfaceKey(o.surface)
	out.opening = (o.opening == "six") and "six" or "2-4-6"
	out.raising = (o.raising == "auto") and "auto" or "hand"
	local w = o.wind or "off"
	if not wind.levels[w] then w = "off" end
	out.wind = w
	out.set = o.set or "classic"
	out.seed = I(o.seed or 1)
	out.first = (o.first == "B") and "B" or "A"
	local cpu = {}
	local c = o.cpu
	if type(c) == "string" then c = (c == "both") and { "A", "B" } or { c } end
	for _, side in ipairs(c or {}) do
		if side == "A" or side == "B" then cpu[#cpu + 1] = side end
	end
	table.sort(cpu)
	out.cpu = cpu
	out.maxTurns = o.maxTurns and I(o.maxTurns) or nil
	out.start = o.start or { year = 2026, month = 1, day = 1, hour = 12, min = 0 }
	for _, k in ipairs { "year", "month", "day", "hour", "min" } do out.start[k] = I(out.start[k] or 0) end
	out.mode = o.modeName
	-- the teams: { A = { name, players = { { name, level } } }, B = ... }, 1 to 6 players each
	local teams = {}
	for _, side in ipairs { "A", "B" } do
		local t = (o.teams or {})[side] or {}
		local name = t.name or ((#cpu == 1 and cpu[1] == side) and "Computer" or ("Team " .. side))
		local players = {}
		for i, p in ipairs(t.players or {}) do
			if i > 6 then break end
			if type(p) == "string" then p = { name = p } end
			players[#players + 1] = { name = tostring(p.name or ("Player " .. i)), level = p.level, key = p.key }
		end
		if #players == 0 then players[1] = { name = name } end
		teams[side] = { name = name, players = players }
	end
	out.teams = teams
	return out
end

local function isCpu(s, side)
	for _, c in ipairs(s.opts.cpu or {}) do if c == side then return true end end
	return false
end

-- ---------- the session ----------

local Session = {}
Session.__index = Session

-- A new session. o.mode = "practice" | "match"; the rest as matchOptions
-- (match) or { surface, level, set, drill } (practice).
function session.new(o)
	needTune()
	o = o or {}
	local s = setmetatable({}, Session)
	s.kind = (o.mode == "match") and "match" or "practice"
	s.control = { A = true, B = true, cpu = true }
	s.throws = 0
	s.recording = nil
	if s.kind == "practice" then
		s.opts = { surface = surfaceKey(o.surface), level = o.level, set = o.set or "classic" }
		s.ts = throw.new { surface = s.opts.surface, level = o.level, set = s.opts.set }
		s.phase = "throw"
		if o.drill then throw.setDrill(s.ts, true) end
		s.ts.railName = "PRACTICE"
		return s
	end
	s.opts = matchOptions(o)
	s.seed = s.opts.seed
	s.ts = throw.new { surface = s.opts.surface, set = s.opts.set }
	local mode = s.opts.mode
	if not mode then
		local n = #s.opts.cpu
		mode = (n == 2) and "Computer vs Computer" or ((n == 1) and "Vs Computer" or "Pass and Play")
	end
	local teams = {}
	for _, side in ipairs { "A", "B" } do
		local t = s.opts.teams[side]
		local ps = {}
		for i, p in ipairs(t.players) do ps[i] = { name = p.name, level = p.level, key = p.key } end
		teams[side] = { name = t.name, players = ps }
	end
	s.m = cmatch.new { start = s.opts.start, surface = SURFACES[s.opts.surface], opening = s.opts.opening,
		teams = teams, first = s.opts.first, mode = mode }
	s.byHand = s.opts.raising == "hand"
	s.side, s.lastThrower = nil, nil
	s:advance()
	return s
end

-- The aim memory the next throw's set-up reads (throw.prepare): kept in the
-- snapshot as it was before that set-up, so a restore sets the throw up again
-- exactly.
local MEM = { "playerX", "playerY", "stanceSet", "stanceSide", "stanceKind", "markerX", "markerY", "markerSet",
	"markerOnId", "markerSide", "drill", "lastBack", "lastStop" }

local setMem

-- Normalizes the live fields first (floats, booleans: what a restore sets), so
-- the acting browser and a restored one hold the very same values.
local function memOf(ts)
	local m = {}
	for _, k in ipairs(MEM) do m[k] = ts[k] end
	setMem(ts, m)
	for _, k in ipairs(MEM) do m[k] = ts[k] end
	return m
end

function setMem(ts, m)
	for _, k in ipairs(MEM) do ts[k] = m[k] end
	ts.markerX, ts.markerY = F(ts.markerX) or 0, F(ts.markerY) or 0
	ts.playerX, ts.playerY = F(ts.playerX) or 0, F(ts.playerY) or 0
	ts.lastBack, ts.lastStop = F(ts.lastBack), F(ts.lastStop)
	ts.stanceSet, ts.markerSet, ts.drill = ts.stanceSet and true or false, ts.markerSet and true or false,
		ts.drill and true or false
end

-- scenes/settle.lua begin: the next raise or punishment kubb (or done).
local function settleBegin(s)
	local g = s.m.game
	local n = g:need()
	local st = s.settle
	if n.kind == "raise" then
		st.mode, st.side, st.kubb = "raise", n.side, n.kubb
		if not st.raiseTotal then
			st.raiseTotal = 0
			for _, k in ipairs(g:fieldKubbs(n.side)) do
				if not k.pose.standing then st.raiseTotal = st.raiseTotal + 1 end
			end
		end
		return true
	elseif n.kind == "punish" then
		st.mode, st.side, st.kubb = "punish", n.side, n.kubb
		if not st.punishTotal then st.punishTotal = #g.punishQueue end
		return true
	end
	return false
end

-- scenes/match.lua nextThrow: the defender settles by hand, or the next
-- throw is set up (its wind, rail and cards), or the match is over.
function Session:advance()
	local m, opts = self.m, self.opts
	self.pre = { side = self.side, lastThrower = self.lastThrower, mem = memOf(self.ts) }
	if opts.maxTurns and m.game.turn > opts.maxTurns and not cmatch.over(m) then
		cmatch.resign(m)
		self.resignNote = "turn limit"
	end
	if self.resignPending and not cmatch.over(m) and m.game.attacker == self.resignPending
		and m.game:need().kind ~= "raise" and m.game:need().kind ~= "punish" then
		self.resignPending = nil
		cmatch.resign(m)
	end
	self.setup = nil
	self.card = nil
	if self.byHand and not cmatch.over(m) then
		local n = m.game:need()
		if (n.kind == "raise" or n.kind == "punish") and not isCpu(self, n.side) then
			self.phase = "settle"
			if not self.settle then
				self.settle = { raised = 0, placed = 0 }
				-- PASS + PLAY: the attacker hands over to the defender first (no
				-- card when the computer plays a side: the player holds it already)
				if #opts.cpu == 0 then self.card = { kind = "settle", settle = cards.settle(m.game) } end
			end
			settleBegin(self)
			return
		end
	end
	self.settle = nil
	local setup = (not cmatch.over(m)) and cmatch.setup(m) or nil
	if not setup then return self:over() end
	self.setup = setup
	self.phase = "throw"
	local ts = self.ts
	throw.prepare(ts, setup)
	self.frameSide = setup.side -- the frame ts is in now (session/wide)
	ts.level = setup.thrower and setup.thrower.level or nil
	ts.watching = isCpu(self, setup.side)
	ts.scripted = false
	-- the wind: a direction and speed for each turn, a gust of it for each throw
	ts.windX, ts.windY, ts.windText = 0, 0, nil
	self.windInfo = nil
	if (wind.levels[opts.wind] or 0) > 0 then
		local turn = m.game.turn
		local dir, speed = wind.turn(rngFor(self, 2, turn), opts.wind)
		local d, sp = wind.gust(rngFor(self, 3, self.throws), dir, speed)
		local wx, wy = wind.vector(d, sp, setup.side)
		ts.windX, ts.windY, ts.windText = wx, wy, wind.text(sp)
		self.windInfo = { x = wx, y = wy, speed = sp, text = ts.windText }
	end
	-- the rail
	local r1, r2
	if setup.kingShot then
		r1 = "KING"
	elseif setup.kind ~= "toss" then
		local field, base = 0, 0
		for _, p in ipairs(setup.pieces) do
			if not p.toppled and p.half ~= setup.side then
				if p.role == "field" then field = field + 1 elseif p.role == "base" then base = base + 1 end
			end
		end
		if field > 0 then r1 = "FIELD " .. field end
		r2 = "BASE " .. base
		if not r1 then r1, r2 = r2, nil end
	end
	self.rail = { r1 = r1, r2 = r2 }
	ts.railName = self:railName(setup)
	-- the cards
	local cpu = isCpu(self, setup.side)
	if setup.side ~= self.side then
		self.side = setup.side
		if not cpu then self.card = { kind = "handoff", handoff = cards.handoff(m, setup) } end
	end
	local th = setup.thrower
	local passes = not cpu and #m.game.teams[setup.side].players > 1
	if not self.card and passes and th and th.id ~= self.lastThrower then
		self.card = { kind = "pass", pass = cards.pass(m, setup) }
	end
	self.lastThrower = th and th.id
	self.cpuAim = nil
end

function Session:railName(setup)
	local name = cmatch.teamName(setup.side, self.m.game)
	if #self.m.game.teams[setup.side].players > 1 and setup.thrower then name = name .. ": " .. setup.thrower.name end
	return upper(name)
end

function Session:over()
	self.phase = "over"
	self.setup = nil
	local finish = self.finish or self.opts.start
	self.overInfo = {
		winner = cards.winner(self.m, finish),
		how = cmatch.howText(self.m),
	}
	local text, name = cmatch.file(self.m, finish, session.client)
	self.overInfo.file = { text = text, name = name }
end

-- The score sheet (docs/CLIENT.md "The score sheet"): the game file as it stands, in
-- Planet Kubb Notation. Mid-match it is the turns so far, with no End, Duration or Win
-- (core/notation writes Win only once there is a winner); once the match is over it is
-- the finished file (Session:over). `shown` is each line as a screen shows it, without
-- the positions on the pitch (core/gamefile.shown); `text` keeps them.
function Session:sheet()
	if self.kind ~= "match" then return nil end
	local text, name
	if self.phase == "over" and self.overInfo and self.overInfo.file then
		text, name = self.overInfo.file.text, self.overInfo.file.name
	else
		local m = self.m
		local levels = {}
		for _, side in ipairs { "A", "B" } do
			for _, e in ipairs(m.lineup and m.lineup[side] or {}) do
				if e.level then levels[#levels + 1] = e.id .. " " .. e.level end
			end
		end
		text = notation.render(m.game, { start = m.start, version = session.client, mode = m.mode,
			levels = levels })
		local start = m.start or self.opts.start
		name = start and notation.filename(start, m.game.teams.A.name, m.game.teams.B.name) or "kubb-game.txt"
	end
	local shown = {}
	for line in text:gmatch("([^\n]*)\n") do shown[#shown + 1] = gamefile.shown(line) end
	return { text = text, name = name, shown = shown, done = self.phase == "over" }
end

-- ---------- what the client asks ----------

local function plainSetup(setup)
	if not setup then return nil end
	return {
		kind = setup.kind, side = setup.side, projectile = setup.projectile, kubb = setup.kubb,
		n = setup.n, of = setup.of, label = setup.label, kingShot = setup.kingShot or false,
		rethrow = setup.rethrow or false, lineY = setup.lineY, forwardY = setup.forwardY, advY = setup.advY,
		targets = setup.targets, batonId = setup.batonId,
		-- key: the lineup's key for the player (on the web, the room member it belongs to)
		thrower = setup.thrower and { id = setup.thrower.id, name = setup.thrower.name,
			level = setup.thrower.level, key = setup.thrower.key } or nil,
		settled = setup.settled,
	}
end

-- The raise: the kubb, its two ends (footprints), the engine's choices, the
-- default choice, the pieces near it (view frame of the defender).
function Session:raiseInfo()
	local g, st = self.m.game, self.settle
	local n = g:need()
	local side = n.side
	local ctx = g:context(side, n.kubb)
	local dec = n.decision
	local default = raising.choose(dec, ctx, g.raisePolicy) or 1
	local choices = {}
	for i, c in ipairs(dec.choices) do
		choices[i] = { which = c.which, pose = viewPose(side, c.pose), displaced = c.displaced or false,
			crowded = c.crowded or false }
	end
	local ends = {}
	local fps = n.pose.standing and {} or raising.footprints(n.pose)
	for i = 1, #fps do
		local e = dec.ends and dec.ends[i]
		local ok = false
		for _, c in ipairs(dec.choices) do if c.which == i then ok = true end end
		ends[i] = { which = i, pose = viewPose(side, fps[i]), inBounds = e and e.inBounds or false,
			obstructedBy = e and e.obstructedBy or nil, ok = ok,
			why = (not ok) and ((e and not e.inBounds) and "THAT END IS OUT" or "THAT END IS BLOCKED") or nil }
	end
	local others = {}
	for _, o in ipairs(ctx.others) do others[#others + 1] = { id = o.id, pose = viewPose(side, o.pose) } end
	return {
		kind = "raise", side = side, kubb = n.kubb, pose = viewPose(side, n.pose), mode = dec.mode,
		choices = choices, ends = ends, default = default, others = others,
		king = viewPose(side, ctx.king),
		n = st.raised + 1, of = max(st.raiseTotal or 0, st.raised + 1),
		team = upper(cmatch.teamName(side, g)),
	}
end

-- The punishment kubb: the default cursor, the keep-out circles, the kubbs
-- on the pitch, the cursor's bounds (view frame of the defender).
function Session:punishInfo()
	local g, st = self.m.game, self.settle
	local n = g:need()
	local side = n.side
	local ctx = g:context(side, n.kubb)
	local p = raising.autoPunishment(ctx)
	local vx, vy = 0, 2
	if p then vx, vy = frame.point(side, p.x, p.y) end
	local hk = pitch.kubbSide / 2
	local keepOut = {}
	for i, stk in ipairs(pitch.stakes) do
		local x, y = frame.point(side, stk.x, stk.y)
		if y >= -0.01 and y <= 4.01 then
			keepOut[#keepOut + 1] = { kind = "stake", id = "stake" .. i, x = x, y = y, r = pitch.batonLength + hk }
		end
	end
	if ctx.king then
		local x, y = frame.point(side, ctx.king.x, ctx.king.y)
		keepOut[#keepOut + 1] = { kind = "king", id = "king", x = x, y = y, r = pitch.batonLength + pitch.kingSide / 2 + hk }
	end
	local others = {}
	for _, o in ipairs(ctx.others) do
		local x, y = frame.point(side, o.pose.x, o.pose.y)
		if y >= -0.2 and y <= 4.2 then others[#others + 1] = { id = o.id, pose = viewPose(side, o.pose) } end
	end
	return {
		kind = "punish", side = side, kubb = n.kubb, cursor = { x = vx, y = vy },
		bounds = { xMin = -2.5 + hk, xMax = 2.5 - hk, yMin = hk, yMax = 4 - hk },
		keepOut = keepOut, others = others,
		n = st.placed + 1, of = max(st.punishTotal or 0, st.placed + 1),
		team = upper(cmatch.teamName(side, g)),
	}
end

-- What happens next: { kind = "throw" | "raise" | "punish" | "over", ... }.
function Session:need()
	if self.kind == "practice" then
		return { kind = "throw", practice = true, drill = self.ts.drill, surface = self.opts.surface,
			level = throw.levelFor(self.ts), set = self.opts.set }
	end
	local out
	if self.phase == "over" then
		local o = self.overInfo
		out = { kind = "over", winner = o.winner, how = o.how, file = o.file, text = self.m.text,
			short = session.short(self.m.text) }
	elseif self.phase == "settle" then
		out = (self.settle.mode == "raise") and self:raiseInfo() or self:punishInfo()
		out.cpu = false
		out["local"] = self.control[out.side] and true or false
	else
		local setup = self.setup
		local cpu = isCpu(self, setup.side)
		out = {
			kind = "throw", side = setup.side, setup = plainSetup(setup), cpu = cpu,
			["local"] = (cpu and self.control.cpu or (not cpu and self.control[setup.side])) and true or false,
			candidates = (not cpu and #self.m.game.teams[setup.side].players > 1) and cmatch.candidates(self.m) or nil,
			wind = self.windInfo,
		}
	end
	out.card = self.card
	out.turn = self.m.game.turn
	out.throws = self.throws
	out.teams = { A = cmatch.teamName("A", self.m.game), B = cmatch.teamName("B", self.m.game) }
	out.standing = { A = cmatch.standing(self.m, "A"), B = cmatch.standing(self.m, "B") }
	out.last = self.m.text and { text = self.m.text, short = session.short(self.m.text) } or nil
	out.resignPending = self.resignPending
	return out
end

-- The aim as drawn: the circle, the stance, the plan, the arc, the rail.
function Session:aimView()
	local ts = self.ts
	local sol = ts.sol
	local arc = nil
	if throw.tune.arc and (ts.drill or ts.projectile ~= "kubb") and not (ts.watching and not ts.cpuTarget) then
		local pts = throw.arcPoints(ts)
		arc = {}
		for i, p in ipairs(pts) do arc[i] = { x = p[1], y = p[2], z = p[3] } end
	end
	local rail = { name = ts.railName }
	if self.kind == "practice" then
		if ts.drill then
			local d = floor((ts.markerY - ts.lineY) * 10 + 0.5)
			rail.r1 = fmt("%d.%d M", d // 10, d % 10)
		else
			local n = 0
			for _, it in ipairs(ts.items) do if it.base and not it.toppled then n = n + 1 end end
			rail.r1 = "BASE " .. n
		end
	elseif self.setup then
		local st = self.setup
		rail.kind, rail.n, rail.of = st.projectile, st.n, st.of
		if ts.drill then
			local d = floor((ts.markerY - ts.lineY) * 10 + 0.5)
			rail.r1 = fmt("%d.%d M", d // 10, d % 10)
		else
			rail.r1, rail.r2 = self.rail.r1, self.rail.r2
		end
	end
	return {
		marker = { x = ts.markerX, y = ts.markerY, r = throw.tune.markerRadius, on = ts.markerOnId,
			set = ts.markerSet, kind = ts.markerKind, shown = not (ts.watching and not ts.cpuTarget) },
		thrower = { x = ts.playerX, y = ts.playerY, swivel = ts.swivel, set = ts.stanceSet },
		plan = {
			release = ts.release, arcSet = ts.arcSet, tilt = ts.tilt, spin = ts.spin,
			level = throw.levelFor(ts), speed = sol.speed, loft = sol.loft, swivel = sol.swivel, dist = sol.dist,
			back = sol.back, powerLo = sol.powerLo, powerHi = sol.powerHi,
			releaseLo = sol.releaseLo, releaseHi = sol.releaseHi,
		},
		arc = arc,
		projectile = ts.projectile, drill = ts.drill,
		lineY = ts.lineY, forwardY = ts.forwardY, advY = ts.advY, advText = ts.advText,
		halfWidth = throw.tune.halfWidth, backMax = throw.tune.backMax,
		rail = rail,
		flag = ts.flagText, restText = ts.restText,
		verdicts = ts.showVerdicts and ts.verdicts or nil,
		wind = ts.windText and { x = ts.windX, y = ts.windY, text = ts.windText } or nil,
		mix = ts.camMix,
		watching = ts.watching or (self.remoteSide and true) or false,
	}
end

-- The minimap: every piece as a dot, the aim line, the advantage line, the wind.
function Session:minimap(items)
	local ts = self.ts
	local dots = {}
	for _, it in ipairs(items or throw.items(ts)) do
		if it.kind ~= "stake" then
			dots[#dots + 1] = { id = it.id, kind = it.kind, x = it.x, y = it.y, toppled = it.toppled, team = it.team }
		end
	end
	return {
		pieces = dots,
		aim = { x0 = ts.playerX, y0 = ts.playerY, x1 = ts.markerX, y1 = ts.markerY },
		advY = ts.advY, lineY = ts.lineY,
		wind = ts.windText and { x = ts.windX, y = ts.windY, text = ts.windText } or nil,
	}
end

-- Everything the screen needs when nothing is playing back.
function Session:view()
	local ts = self.ts
	local items = throw.items(ts)
	return {
		need = self:need(),
		items = items,
		minimap = self:minimap(items),
		aim = self:aimView(),
		camera = ts.aimCam,
		dial = throw.dial(ts, true),
		surface = ts.surface, set = ts.set,
	}
end

-- ---------- aiming ----------

function Session:canAim()
	return self.phase == "throw" and self.ts.mode == "aim" and not self.ts.watching
end

local function aimOut(s)
	return { aim = s:aimView(), camera = s.ts.aimCam }
end

function Session:setTarget(x, y, snap)
	if not self:canAim() then return aimOut(self) end
	throw.setTarget(self.ts, F(x), F(y), snap)
	return aimOut(self)
end

function Session:nudgeTarget(dx, dy)
	return self:setTarget(self.ts.markerX + (dx or 0), self.ts.markerY + (dy or 0), false)
end

function Session:setStance(x, y)
	if not self:canAim() then return aimOut(self) end
	if x == nil then throw.freeStance(self.ts) else throw.setStance(self.ts, F(x), F(y)) end
	return aimOut(self)
end

function Session:stepArc(step)
	if self:canAim() then throw.stepArc(self.ts, I(step or 1)) end
	return aimOut(self)
end

function Session:setArc(deg)
	if self:canAim() then throw.setArc(self.ts, F(deg)) end
	return aimOut(self)
end

function Session:stepSide(step)
	if self:canAim() then throw.stepSide(self.ts, I(step or 1)) end
	return aimOut(self)
end

function Session:freshPlan()
	if self:canAim() then throw.freshPlan(self.ts) end
	return aimOut(self)
end

function Session:setLevel(level)
	if self.kind == "practice" then
		self.ts.defaultLevel = level
	else
		self.ts.level = level
	end
	self.ts.planDirty = true
	throw.replan(self.ts)
	throw.aimCamera(self.ts)
	return aimOut(self)
end

-- Practice only.
function Session:setDrill(on)
	assert(self.kind == "practice", "setDrill is for practice")
	throw.setDrill(self.ts, on)
	return self:view()
end

function Session:reset()
	assert(self.kind == "practice", "reset is for practice")
	throw.reset(self.ts)
	self.ts.flagText = nil
	return self:view()
end

function Session:setSurface(name)
	assert(self.kind == "practice", "setSurface is for practice")
	self.opts.surface = surfaceKey(name)
	self.ts.surface = self.opts.surface
	self.ts.planDirty = true -- a drill runs on by the ground
	return self:view()
end

-- Which sides this browser plays, and whether it throws for the computer.
function Session:setControl(c)
	c = c or {}
	local sides = c.sides or { "A", "B" }
	self.control = { A = false, B = false, cpu = c.cpu ~= false }
	for _, side in ipairs(sides) do self.control[side] = true end
	return self:need()
end

-- ---------- the throw ----------

-- The action for a throw with launch L ("how": baton, drill or lob), from
-- where the throw scene stands now.
function Session:throwAction(L, how, info)
	local ts = self.ts
	local a = {
		type = "throw", seq = self.throws, how = how,
		launch = {
			speed = L.speed, loft = L.loft, swivel = L.swivel, tilt = L.tilt or 0, tumble = L.tumble or 0,
			legal = L.legal ~= false,
			noseDown = L.noseDown, rollLand = L.rollLand, spin = L.spin, wobble = L.wobble,
		},
		stance = { x = ts.playerX, y = ts.playerY, set = ts.stanceSet },
		target = { x = ts.markerX, y = ts.markerY, set = ts.markerSet, on = ts.markerOnId },
		scripted = info.scripted or false,
	}
	if info.back then a.swing = { back = info.back, stop = info.stop } end
	if info.verdicts then
		a.verdicts = { powerV = info.verdicts.powerV, releaseV = info.verdicts.releaseV,
			steady = info.verdicts.steady and true or false, sideV = info.verdicts.sideV }
	end
	return a
end

-- Run a throw action: the same path for the actor and for every other
-- browser (docs/SESSION.md "Determinism"). Returns the recording.
function Session:applyThrow(a)
	if self.kind == "match" then
		assert(self.phase == "throw", "no throw set up")
		assert(I(a.seq) == self.throws, "throw out of step: seq " .. tostring(a.seq) .. ", expected " .. self.throws)
	end
	local ts = self.ts
	-- the frame this throw's recording is in (session/wide)
	self.recSide = self.kind == "match" and self.setup.side or nil
	local st, tg = a.stance or {}, a.target or {}
	ts.playerX, ts.playerY, ts.stanceSet = F(st.x), F(st.y), st.set and true or false
	ts.markerX, ts.markerY, ts.markerSet, ts.markerOnId = F(tg.x), F(tg.y), tg.set and true or false, tg.on
	local l = a.launch
	local L = {
		speed = F(l.speed), loft = F(l.loft), swivel = F(l.swivel), tilt = F(l.tilt or 0), tumble = F(l.tumble or 0),
		legal = l.legal ~= false,
		noseDown = F(l.noseDown), rollLand = F(l.rollLand), spin = F(l.spin), wobble = F(l.wobble),
	}
	local how = a.how
	local verdicts = nil
	if a.verdicts then
		verdicts = { powerV = I(a.verdicts.powerV), releaseV = I(a.verdicts.releaseV), steady = a.verdicts.steady,
			sideV = a.verdicts.sideV and I(a.verdicts.sideV) or nil }
	end
	local sw = a.swing
	local back, stop = sw and F(sw.back), sw and F(sw.stop)
	ts.scripted = a.scripted and true or false
	-- the playback camera starts from the aim camera as every browser has it
	local cpuSide = self.kind == "match" and isCpu(self, self.setup.side)
	ts.watching, ts.cpuTarget = cpuSide, cpuSide
	ts.camMix = 0
	local rec = throw.fire(ts, L, how, { verdicts = verdicts, back = back, stop = stop })
	ts.lastBack, ts.lastStop = back, stop
	ts.verdicts = rec.result.verdicts
	ts.showVerdicts = (not ts.scripted) and verdicts ~= nil
	ts.restText = rec.result.restText
	ts.flagText = rec.result.flag
	self.throws = self.throws + 1
	if a.at then self.finish = a.at end
	if self.kind == "practice" then
		throw.afterRest(ts)
		ts.mode = "aim"
	else
		local m = self.m
		cmatch.resolve(m, ts.result, not rec.result.legal)
		rec.result.ruling = { text = m.text, short = session.short(m.text) }
		ts.flagText = session.short(m.text)
		ts.mode = "aim"
		ts.watching = false
		self:advance()
	end
	rec.seq = self.throws - 1
	self.recording = rec
	return rec
end

-- ---------- the frame ----------

-- One frame while aiming (docs/SESSION.md "The frame"). inp = { dt, arm,
-- plan, move = {dx, dy}, walk = {dx, dy} }. Returns { dial, camera, aim,
-- event, action, recording, need }.
function Session:frame(inp)
	inp = inp or {}
	local dt = F(inp.dt or 1 / 60)
	if dt <= 0 then dt = 1 / 60 end
	if dt > 0.1 then dt = 0.1 end
	local ts = self.ts
	local out = {}
	if self.phase ~= "throw" then
		out.dial = throw.dial(ts, true)
		return out
	end
	local cpu = self.kind == "match" and isCpu(self, self.setup.side)
	local ev, L, how, info
	if cpu then
		if ts.mode == "aim" then
			-- the computer's throw: its aim shows (cpuThink), then its arm plays on the dial
			local a = autothrow.choose(self.setup, rngFor(self, 1, self.throws), tw.web.tune.throw.cpuScatter)
			self.cpuAim = a
			throw.cpuBegin(ts, a)
		end
		ev = throw.cpuFrame(ts, dt)
		if ev == "release" then
			if self.control.cpu then
				local a = self.cpuAim
				L, how = throw.cpuLaunch(ts, a)
				ts.playerX, ts.playerY = a.x, a.y
				info = { scripted = true, back = a.swing and a.swing.back, stop = a.swing and a.swing.releaseAngle }
			else
				-- another browser throws for the computer: hold at the release
				ts.mode = "cpuhold"
				ev = nil
			end
		end
	elseif self.kind == "match" and not self.control[self.setup.side] then
		-- someone else's throw: their aim comes in by showAim
		throw.aimCamera(ts)
		out.dial = throw.dial(ts, true)
		out.camera = ts.aimCam
		out.aim = self:aimView()
		return out
	else
		local changed
		ev, changed = throw.aimFrame(ts, inp)
		if ev == "release" then
			local r = ts.swing.result
			L, how = throw.playerLaunch(ts, r)
			info = { back = r.back, stop = r.releaseAngle, verdicts = L }
		end
	end
	out.event = ev
	if L then
		local action = self:throwAction(L, how, info)
		-- the actor runs the action exactly as every other browser will: through JSON
		action = json.decode(json.encode(action))
		out.action = action
		out.recording = self:applyThrow(action)
		out.need = self:need()
	end
	out.dial = throw.dial(ts, not L)
	out.camera = ts.aimCam
	out.aim = self:aimView()
	return out
end

-- The last throw at shown time t.
function Session:showAt(t)
	local r = throw.showAt(self.ts, F(t or 0))
	if not r then return nil end
	r.dial = throw.dial(self.ts, false)
	return r
end

-- ---------- watching ----------

function Session:aimState()
	local ts = self.ts
	local sw = ts.swing
	return {
		seq = self.throws, x = ts.playerX, y = ts.playerY, stanceSet = ts.stanceSet,
		tx = ts.markerX, ty = ts.markerY, markerSet = ts.markerSet, on = ts.markerOnId,
		release = ts.release, arcSet = ts.arcSet, tilt = ts.tilt, spin = ts.spin,
		arm = ts.arm or 0, phase = sw.phase, back = sw.back, mix = ts.camMix,
	}
end

-- Someone else's aim (their aimState): the circle, stance, plan, dial and
-- plan-view mix follow it.
function Session:showAim(a)
	if self.phase ~= "throw" or (a.seq ~= nil and I(a.seq) ~= self.throws) then return nil end
	local ts = self.ts
	ts.playerX, ts.playerY, ts.stanceSet = F(a.x), F(a.y), a.stanceSet and true or false
	ts.markerX, ts.markerY, ts.markerSet, ts.markerOnId = F(a.tx), F(a.ty), a.markerSet and true or false, a.on
	ts.release, ts.arcSet = F(a.release), a.arcSet and true or false
	ts.tilt, ts.spin = a.tilt or 0, a.spin or 0
	ts.camMix = F(a.mix or 0)
	ts.remote = { arm = F(a.arm or 0), phase = a.phase or "idle", back = F(a.back or 0) }
	throw.replan(ts)
	throw.aimCamera(ts)
	return { aim = self:aimView(), camera = ts.aimCam, dial = throw.dial(ts, true) }
end

-- ---------- the match's other actions ----------

function Session:checkPunish(x, y)
	assert(self.phase == "settle" and self.settle.mode == "punish", "no punishment kubb to place")
	local g = self.m.game
	local n = g:need()
	local wx, wy = frame.point(n.side, F(x), F(y))
	local ok, why = raising.punishmentCheck({ x = wx, y = wy, standing = true, angle = 0 }, g:context(n.side, n.kubb))
	return { ok = ok and true or false, why = why, label = whyLabel(why) }
end

-- apply(action): any action, from this browser or another. Returns
-- { ok, recording?, need, error? }.
function Session:apply(a)
	local t = a.type
	if t == "throw" then
		local rec = self:applyThrow(a)
		return { ok = true, recording = rec, need = self:need() }
	end
	assert(self.kind == "match", "only a match takes " .. tostring(t))
	local g = self.m.game
	if t == "raise" then
		assert(self.phase == "settle" and self.settle.mode == "raise", "no kubb to raise")
		local choice = a.choice and I(a.choice) or nil
		local dec = g:need().decision
		assert(choice == nil or dec.choices[choice], "no raising choice " .. tostring(choice))
		g:raise(choice)
		self.settle.raised = self.settle.raised + 1
		self.card = nil
		if not settleBegin(self) then self.settle = nil; self:advance() end
		return { ok = true, need = self:need() }
	elseif t == "punish" then
		assert(self.phase == "settle" and self.settle.mode == "punish", "no punishment kubb to place")
		local n = g:need()
		local wx, wy = frame.point(n.side, F(a.x), F(a.y))
		local ok, why = g:placePunishment({ x = wx, y = wy, standing = true, angle = 0 })
		if not ok then return { ok = false, why = why, label = whyLabel(why), need = self:need() } end
		self.settle.placed = self.settle.placed + 1
		self.card = nil
		if not settleBegin(self) then self.settle = nil; self:advance() end
		return { ok = true, need = self:need() }
	elseif t == "resign" then
		if self.phase == "over" then return { ok = false, why = "over", need = self:need() } end
		local side = a.side or g.attacker
		if a.at then self.finish = a.at end
		if g.attacker == side and self.phase == "throw" then
			cmatch.resign(self.m)
			self:over()
		else
			-- the rules allow a resign only on the team's own turn: it waits for it
			self.resignPending = side
		end
		return { ok = true, need = self:need() }
	elseif t == "thrower" then
		assert(self.phase == "throw", "no throw set up")
		local ok, why = cmatch.changeThrower(self.m, a.id)
		if not ok then return { ok = false, why = why, need = self:need() } end
		local setup = self.setup
		self.lastThrower = setup.thrower.id
		self.ts.level = setup.thrower.level
		self.ts.planDirty = true
		throw.replan(self.ts)
		self.ts.railName = self:railName(setup)
		if self.card and self.card.kind == "handoff" then self.card.handoff = cards.handoff(self.m, setup)
		elseif self.card and self.card.kind == "pass" then self.card.pass = cards.pass(self.m, setup) end
		return { ok = true, need = self:need() }
	end
	error("unknown action " .. tostring(t))
end

-- ---------- snapshot ----------

function Session:snapshotTable()
	assert(self.kind == "match", "only a match has a snapshot")
	local pre = self.pre
	return {
		v = session.snapshotVersion,
		opts = self.opts,
		save = save.pack(self.m, nil),
		throws = self.throws,
		finish = self.finish,
		resignPending = self.resignPending,
		side = pre.side, lastThrower = pre.lastThrower, mem = pre.mem,
		settle = self.settle and { raised = self.settle.raised, placed = self.settle.placed,
			raiseTotal = self.settle.raiseTotal, punishTotal = self.settle.punishTotal } or nil,
	}
end

function Session:snapshot()
	return json.encode(self:snapshotTable())
end

function Session:hash()
	return fnv(self:snapshot())
end

function session.restore(text, control)
	needTune()
	local d = type(text) == "string" and json.decode(text) or text
	assert(type(d) == "table" and d.v == session.snapshotVersion, "not a snapshot of this version")
	local s = setmetatable({}, Session)
	s.kind = "match"
	s.control = { A = true, B = true, cpu = true }
	s.opts = d.opts
	s.opts.cpu = s.opts.cpu or {}
	s.seed = I(d.opts.seed)
	s.throws = I(d.throws)
	s.finish = d.finish
	s.resignPending = d.resignPending
	local m, why = save.unpack(d.save)
	assert(m, why)
	s.m = m
	s.byHand = s.opts.raising == "hand"
	s.ts = throw.new { surface = s.opts.surface, set = s.opts.set }
	setMem(s.ts, d.mem or {})
	s.side, s.lastThrower = d.side, d.lastThrower
	if d.settle then
		s.settle = { raised = I(d.settle.raised), placed = I(d.settle.placed), raiseTotal = I(d.settle.raiseTotal),
			punishTotal = I(d.settle.punishTotal) }
	end
	s:advance()
	if control then s:setControl(control) end
	return s
end

tw.web.session = session
