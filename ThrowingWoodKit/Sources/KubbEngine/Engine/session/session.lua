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
--   the computer's baton to go  mix(seed, 5, 2 * round + (side B: 1, A: 0))  (1.4.0)
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
import "core/scenes"
import "core/namegen"
import "core/togo"
import "version"
import "session/json"
import "session/throw"
import "pitch/lobby"
import "session/namecheck"

local cmatch, cards, save, autothrow, wind = tw.match, tw.cards, tw.save, tw.autothrow, tw.wind
local raising, frame, pitch, quat, swing, plan = tw.raising, tw.frame, tw.pitch, tw.quat, tw.swing, tw.plan
local camera, outcome, debris = tw.camera, tw.outcome, tw.debris
local notation, gamefile, scenes, namegen = tw.notation, tw.gamefile, tw.scenes, tw.namegen
local json, throw = tw.web.json, tw.web.throw
local togo = tw.togo

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

-- Where the game file says the match was played (its Location line). nil: core/notation's
-- own (notation.location, "Playdate"), as before 0.7.2. Not in the snapshot either, so it
-- never changes a hash. Every file the session writes reads it when it is written: the
-- live sheet, the over card's file, and a replay's (a replay runs a Session too).
session.location = nil

function session.setLocation(place)
	if place == nil then
		session.location = nil
		return nil
	end
	assert(type(place) == "string" and #place >= 1 and #place <= 40 and place:match("^[%w%.%-%+ ]+$")
		and not place:match("^ ") and not place:match(" $"),
		"setClient: a location of 1 to 40 letters, digits, spaces, dots, hyphens or pluses, like \"throwingwood.com\"")
	session.location = place
	return place
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
-- the result flag's words. Two differences since 0.7.4: a resignation's words begin
-- with the team's name ("Riverside resigned: Oak wins", core/match.resign), so its rule
-- comes first and takes any name (one named "rescue" or "missed" would match a later
-- rule); and a line no rule knows is cut at a word, never inside one.
local SHORT = {
	{ "^.+ resigned: ", "RESIGNED" },
	-- the Kid rules (0.15.0): the king is stood back up, and a kubb out twice is placed by
	-- the engine, so neither may read as the standard game's ending or punishment
	{ "^king down[^;:]*: stood back up", "KING BACK UP" },
	{ "^out twice: stood at the fair spot", "OUT TWICE: PLACED" },
	{ "^(%d+) out twice: stood at the fair spot", "%1 OUT TWICE: PLACED" },
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
	-- a Kid baton that only knocked the king down: the king going back up is the news
	if first == "missed" and s:find("; king down early: stood back up", 1, true) then return "KING BACK UP" end
	for _, r in ipairs(SHORT) do
		if first:find(r[1]) then return (first:gsub("^.*$", function(m) return (m:gsub(r[1] .. ".*$", r[2])) end)) end
	end
	if first:find("down$") then
		local n = 0
		for c in first:gmatch("(%d*) ?[fb]%a+ kubbs?") do n = n + (c == "" and 1 or tonumber(c)) end
		if n > 0 then return n .. " DOWN" end
	end
	-- no rule: up to 12 characters ending at a word (the first word whole when it is
	-- longer), without a trailing colon or comma
	local up = first:upper():gsub("^%s+", ""):gsub("%s+$", "")
	if #up > 12 then up = up:sub(1, 13):match("^(.*%S)%s") or up:match("^%S+") end
	return (up:gsub("[%s:,]+$", ""))
end

-- A Kid match's king knocked down early and stood back up (0.17.0; the ruling's
-- `kingUp`): it is no kubb down. The recording's result counted it in `down` and so
-- flagged a baton that felled only the king "1 DOWN" while the ruling was a miss. Here
-- `down` counts the kubbs only, and a baton's `flag` is theirs ("1 DOWN"), or "KING BACK
-- UP" when it felled none, as session.short says. A kubb's throw keeps no flag (its rest
-- text is its line). Output only: a recording is in no snapshot or hash.
function session.kingUpResult(r, ruling)
	if type(r) ~= "table" or type(ruling) ~= "table" then return end
	local up = false
	for _, p in ipairs(ruling.parts or {}) do if p.code == "kingUp" then up = true end end
	if not up then return end
	local kubbs = 0
	for _, id in ipairs(r.toppled or {}) do if type(id) == "string" and id:match("^[ab]%d+$") then kubbs = kubbs + 1 end end
	r.down = kubbs
	if r.flag ~= nil and r.flag ~= "HELICOPTER" then
		r.flag = kubbs > 0 and (kubbs .. " DOWN") or "KING BACK UP"
	end
end

-- A throw's ruling for its recording (docs/SESSION.md "Rulings"): the words (m.text), the
-- flag's (short), and since 0.7.2 the same as codes (core/match m.ruling): `code` and `n`
-- the first part's, `parts` every part's, `winner` once the match is won. The words are
-- unchanged; a reader that needs what happened reads the codes.
function session.ruling(m)
	local r = { text = m.text, short = session.short(m.text) }
	local cr = m.ruling
	if cr and cr.parts and cr.parts[1] then
		local parts = {}
		for i, p in ipairs(cr.parts) do parts[i] = { code = p.code, n = p.n } end
		r.code, r.n, r.parts = parts[1].code, parts[1].n, parts
		r.winner = cr.winner
	end
	return r
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

-- A settled kubb's seat (core/match, 1.0: the quaternion it stands at in the next throw's
-- world, engine frame) in side's view frame, or nil.
local function viewSeat(side, q)
	if not q then return nil end
	local qw, qx, qy, qz = frame.quat(side, q.qw, q.qx, q.qy, q.qz)
	return { qw = qw, qx = qx, qy = qy, qz = qz }
end

-- ---------- options ----------

local SURFACES = scenes.surfaceName -- { grass = "Grass", ..., grid = "Grid" }

local function surfaceKey(name)
	name = string.lower(name or "grass")
	if not SURFACES[name] then name = "grass" end
	return name
end

-- A scene decides (core/scenes, 0.14): options a client sets with a scene named get the
-- scene's surface and set, the surface given if the scene allows it, else its default,
-- and the set likewise; an id the catalogue does not have is Park ("day"). A copy of o;
-- o itself when it names no scene, so a setup from before 0.14 (any surface and set, no
-- scene) is made exactly as it always was. Applied where a client starts a match or
-- practice (kubbCall "new"), never to a match already started: restore, replay,
-- checkStart and renameStart make the match from its options as they were recorded.
function session.sceneOptions(o)
	if type(o) ~= "table" or o.scene == nil then return o end
	local c = {}
	for k, v in pairs(o) do c[k] = v end
	local surface = type(o.surface) == "string" and string.lower(o.surface) or nil
	c.scene, c.surface, c.set = scenes.resolve(o.scene, surface, o.set)
	c.sceneRule = true
	return c
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
	-- the starting host's UTC offset (0.18.0; minutes east of UTC, whole, -900..900): the
	-- clock every action's `at` is on. Kept when given (it is in the snapshot, so a new
	-- match that gives it has other hashes); anything else is dropped
	local off = out.start.utcOffset
	if off ~= nil then
		if type(off) == "number" and off == off and off == math.floor(off) and off >= -900 and off <= 900 then
			out.start.utcOffset = I(off)
		else
			out.start.utcOffset = nil
		end
	end
	out.mode = o.modeName
	-- the computer's level, a game setting (Jamie, 2026-11-20: "yes this should be a real
	-- per game setting"): every computer player takes it unless its entry names its own.
	-- Kept only when given and not the default, so a match without it (every one before
	-- 0.9) and one that names club have the snapshot a match always had; absent, the
	-- computer throws at club (autothrow.tune.level)
	if plan.levels[o.computer] and o.computer ~= autothrow.tune.level then out.computer = o.computer end
	-- computer players in a team (0.17.0): an entry { cpu = true, level, name?, key? }
	-- (docs/SESSION.md "Computer players"). Only these entries carry `cpu`, so a match
	-- without one (every match before 0.17) has the start it always had
	local seats = false
	for _, side in ipairs { "A", "B" } do
		for _, p in ipairs(((o.teams or {})[side] or {}).players or {}) do
			if type(p) == "table" and p.cpu == true then seats = true end
		end
	end
	-- the Kid rules (0.15.0, docs/notes/kid-mode.md): the Kid computer makes the match a
	-- Kid match (the Kid rules for both sides, the Kid meter for a person); `rules = "kid"`
	-- asks for them outright (pass and play with two children, later). Kept only for a Kid
	-- match, so every other match has the snapshot a match always had. Since 0.17.0 a
	-- computer player in a team is a computer too: with the Kid computer chosen it makes
	-- the match a Kid match, and in a Kid match every computer player is the Kid computer
	if o.rules == "kid" or (out.computer == "kid" and (#cpu > 0 or seats)) then out.rules = "kid" end
	-- the scene, a look only (pitch/lobby.isScene): kept only when given, valid and not
	-- "day", the default, so the start is otherwise the one a match always had. The
	-- physics and the rules never read it
	if tw.shared.lobby.isScene(o.scene) and o.scene ~= tw.shared.lobby.OPTION_DEFAULTS.scene then out.scene = o.scene end
	-- the teams: { A = { name, players = { { name, level } } }, B = ... }, 1 to 6 players each
	local teams = {}
	local unnamed = {}
	local taken = {}
	for _, side in ipairs { "A", "B" } do
		local t = (o.teams or {})[side] or {}
		local isCpuSide = false
		for _, c2 in ipairs(cpu) do if c2 == side then isCpuSide = true end end
		local name = t.name or ((#cpu == 1 and cpu[1] == side) and "Computer" or ("Team " .. side))
		local players = {}
		for i, p in ipairs(t.players or {}) do
			if i > 6 then break end
			if type(p) == "string" then p = { name = p } end
			if p.cpu == true then
				-- a computer player: Beginner, Club or Pro (absent: the match's computer level);
				-- Kid is the match's (computer = "kid"), never one player's
				local level = p.level
				if level == nil then level = out.computer or autothrow.tune.level end
				if out.rules == "kid" then
					level = "kid"
				elseif not session.SEAT_LEVELS[level] then
					error("newMatch: Team " .. side .. "'s player " .. i .. " is a computer player, whose level is "
						.. "beginner, club or pro (the Kid computer is the match's: computer = \"kid\")", 0)
				end
				players[#players + 1] = { name = type(p.name) == "string" and p.name or nil, level = level,
					key = p.key, cpu = true }
				if type(p.name) ~= "string" then unnamed[#unnamed + 1] = { side = side, i = #players } end
			else
				local level = p.level
				if level == nil and isCpuSide then level = out.computer end
				players[#players + 1] = { name = tostring(p.name or ("Player " .. i)), level = level, key = p.key }
				-- a person's throw level (1.3.0): the meter they throw on, easy, standard or
				-- hard (plan.THROW_LEVELS). Kept only when given and not standard, the
				-- default, so a match without it has the start a match always had
				if p.throw ~= nil and p.throw ~= plan.THROW_DEFAULT then
					if not plan.isThrowLevel(p.throw) then
						error("newMatch: Team " .. side .. "'s player " .. i .. "'s throw level is easy, standard or hard", 0)
					end
					players[#players].throw = p.throw
				end
			end
			if players[#players].name then taken[players[#players].name] = true end
		end
		if #players == 0 then players[1] = { name = name, level = isCpuSide and out.computer or nil } end
		teams[side] = { name = name, players = players, named = t.name ~= nil }
	end
	-- a computer player with no name gets a generated one (core/namegen), drawn from the
	-- match's seed and its seat (Team A's players 1 to 6, Team B's 7 to 12), never one
	-- another player of the match has, so every client makes the same names
	for _, u in ipairs(unnamed) do
		local seat = (u.side == "A" and 0 or 6) + u.i
		local r = plan.rng(mix(out.seed, 4, seat))
		local function rand(n)
			local k = floor(r.next() * n) + 1
			if k > n then k = n end
			return k
		end
		local text
		for _ = 1, 50 do
			text = namegen.roll("player", rand)
			if text and not taken[text] then break end
		end
		taken[text] = true
		teams[u.side].players[u.i].name = text
	end
	-- a team of one computer player with no name of its own is that player, as the
	-- pitch names a side of one
	for _, side in ipairs { "A", "B" } do
		local t = teams[side]
		if not t.named and #t.players == 1 and t.players[1].cpu then t.name = t.players[1].name end
		t.named = nil
	end
	out.teams = teams
	-- the throw to go (1.4.0; core/togo, docs/SESSION.md "The throw to go"): who throws
	-- first is thrown for before turn 1. Kept only when asked for (true or "on"), never in
	-- a Kid match (a child's match starts at once, as it always did) and never when no
	-- person throws a baton to go (each team's first player throws it: match.togoThrower;
	-- with the computer first on both, nobody would throw and nobody watch it decided), so
	-- every other match has the start it always had
	if (o.togo == true or o.togo == "on") and out.rules ~= "kid" then
		local person = false
		for _, side in ipairs { "A", "B" } do
			local whole = false
			for _, c2 in ipairs(cpu) do if c2 == side then whole = true end end
			local p1 = teams[side].players[1]
			if not whole and p1 and not p1.cpu then person = true end
		end
		if person then out.togo = true end
	end
	return out
end
-- (session/namecheck reads a replay's setup through it, on a copy: matchOptions fills in
-- the caller's start table)
session.matchOptions = matchOptions

-- The meter a match's people throw on (plan.meters): the Kid meter in a Kid match, else
-- nil (plan.tune.meter, the standard one).
function session.meterOf(opts)
	return (opts and opts.rules == "kid") and "kid" or nil
end

-- A computer player's levels (0.17.0): Kid is a match's rules, chosen with the
-- match's computer option, never one player's.
session.SEAT_LEVELS = { beginner = true, club = true, pro = true }

local function isCpu(s, side)
	for _, c in ipairs(s.opts.cpu or {}) do if c == side then return true end end
	return false
end
session.isCpu = isCpu

-- Is the throw set up the computer's (0.17.0): its side is one the `cpu` option names
-- (the computer plays it whole, as before), or its thrower is a computer player in a
-- team (match.thrower's `cpu`). autothrow.choose throws it at the thrower's own level.
local function cpuThrow(s, setup)
	if not setup then return false end
	if isCpu(s, setup.side) then return true end
	return setup.thrower ~= nil and setup.thrower.cpu == true
end
session.cpuThrow = cpuThrow

-- The match's [Mode] from its options when they name none: "Pass and Play" with no
-- computer in it, "Computer vs Computer" when both teams are computers only, "Vs
-- Computer" otherwise (0.17.0: a computer partner counts; before, only the sides the
-- `cpu` option named, which gives the same for every match without a computer player).
function session.modeOf(opts)
	local cpuSides = {}
	for _, c in ipairs(type(opts.cpu) == "table" and opts.cpu or {}) do cpuSides[c] = true end
	local any, whole = false, 0
	for _, side in ipairs { "A", "B" } do
		local t = type(opts.teams) == "table" and opts.teams[side] or nil
		local ps = type(t) == "table" and type(t.players) == "table" and t.players or {}
		local all = cpuSides[side] == true
		if not all then
			local seats = 0
			for _, p in ipairs(ps) do if type(p) == "table" and p.cpu == true then seats = seats + 1 end end
			if seats > 0 then any = true end
			all = seats > 0 and seats == #ps
		end
		if all then any, whole = true, whole + 1 end
	end
	if whole == 2 then return "Computer vs Computer" end
	if any then return "Vs Computer" end
	return "Pass and Play"
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
		-- the person's throw level (1.3.0), as a match's player entry takes it: absent,
		-- standard or unknown, the standard meter
		local tl = (plan.isThrowLevel(o.throw) and o.throw ~= plan.THROW_DEFAULT) and o.throw or nil
		s.opts = { surface = surfaceKey(o.surface), level = o.level, set = o.set or "classic",
			scene = tw.shared.lobby.isScene(o.scene) and o.scene ~= "day" and o.scene or nil, throw = tl }
		s.ts = throw.new { surface = s.opts.surface, level = o.level, set = s.opts.set, throwLevel = tl }
		-- practice set up under a scene (session.sceneOptions) keeps its surface to the scene's
		s.sceneRule = o.sceneRule and true or nil
		s.phase = "throw"
		if o.drill then throw.setDrill(s.ts, true) end
		s.ts.railName = "PRACTICE"
		return s
	end
	s.opts = matchOptions(o)
	s.seed = s.opts.seed
	s.ts = throw.new { surface = s.opts.surface, set = s.opts.set, meter = session.meterOf(s.opts) }
	local mode = s.opts.mode or session.modeOf(s.opts)
	local teams = {}
	for _, side in ipairs { "A", "B" } do
		local t = s.opts.teams[side]
		local ps = {}
		for i, p in ipairs(t.players) do
			ps[i] = { name = p.name, level = p.level, key = p.key, cpu = p.cpu, throw = p.throw }
		end
		teams[side] = { name = t.name, players = ps }
	end
	s.m = cmatch.new { start = s.opts.start, surface = SURFACES[s.opts.surface], opening = s.opts.opening,
		teams = teams, first = s.opts.first, mode = mode, cpu = s.opts.cpu, rules = s.opts.rules }
	s.byHand = s.opts.raising == "hand"
	s.side, s.lastThrower = nil, nil
	if s.opts.togo then
		s.togo = { round = 1, acts = {} }
		s:togoBegin()
	else
		s:advance()
	end
	return s
end

-- The aim memory the next throw's set-up reads (throw.prepare): kept in the
-- snapshot as it was before that set-up, so a restore sets the throw up again
-- exactly.
local MEM = { "playerX", "playerY", "stanceSet", "stanceSide", "stanceKind", "markerX", "markerY", "markerSet",
	"markerOnId", "markerSide", "drill", "lastBack", "lastStop", "keptSpin" }

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
	-- the kept spin (throw.prepare): absent unless a person threw a kubb with spin, so a
	-- match that never had one keeps the snapshot it always had
	ts.keptSpin = F(ts.keptSpin)
	if ts.keptSpin == 0 then ts.keptSpin = nil end
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
		-- (0.17.0) a team with a person on it raises and places by hand (its people
		-- decide: on a shared pitch any of them, pitch.actorsFor); a team of computers
		-- by the computer, at its strongest player's level (match.raisePolicy)
		if (n.kind == "raise" or n.kind == "punish") and cmatch.hasPerson(m, n.side) then
			self.phase = "settle"
			self.pitchFromMatch = true
			if not self.settle then
				self.settle = { raised = 0, placed = 0 }
				-- PASS + PLAY: the attacker hands over to the defender first (no
				-- card when the computer plays a side, or the team that threw is
				-- computers only: the player holds it already)
				if #opts.cpu == 0 and cmatch.hasPerson(m, n.side == "A" and "B" or "A") then
					self.card = { kind = "settle", settle = cards.settle(m.game) }
				end
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
	self.pitchFromMatch = nil -- ts holds the match's pitch from here on
	local ts = self.ts
	-- the thrower's throw level (1.3.0), before the plan is made: the meter it is made on
	ts.throwLevel = setup.thrower and setup.thrower.throw or nil
	throw.prepare(ts, setup)
	self.frameSide = setup.side -- the frame ts is in now (session/wide)
	ts.level = setup.thrower and setup.thrower.level or nil
	ts.watching = cpuThrow(self, setup)
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
	-- the cards (the hand-off when the team has a person on it, whoever throws first:
	-- the person's computer partner may open the turn)
	local cpu = cpuThrow(self, setup)
	if setup.side ~= self.side then
		self.side = setup.side
		if cmatch.hasPerson(m, setup.side) then self.card = { kind = "handoff", handoff = cards.handoff(m, setup) } end
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
	-- the frame the pitch is shown in: the last throw's (a restored session has none yet)
	self.frameSide = self.frameSide or self.side or "A"
	-- the last stamp an action carried; none (no host stamped), no finish: the file has no
	-- End or Duration line and the winner card no minutes (0.18.0; before, the start, so
	-- every match lasted 0 minutes)
	local finish = self.finish
	-- a stamp before the start (a host's clock wrong, or a stamp on another clock) is no
	-- finish: never negative minutes
	if finish and self.m.start and notation.minutesBetween(self.m.start, finish) < 0 then finish = nil end
	self.overInfo = {
		winner = cards.winner(self.m, finish),
		how = cmatch.howText(self.m),
	}
	local text, name = cmatch.file(self.m, finish, session.client, session.location)
	self.overInfo.file = { text = text, name = name }
end

-- The score sheet (docs/CLIENT.md "The score sheet"): the game file as it stands, in
-- Planet Kubb Notation. Mid-match it is the turns so far, with no End, Duration or Win
-- (core/notation writes Win only once there is a winner); once the match is over it is
-- the finished file (Session:over). `shown` is the lines a screen shows: every line but
-- the position lines under the turns (core/gamefile.isPosition), so one entry for each
-- header, the blank line and each turn line; `text` keeps them.
function Session:sheet()
	if self.kind ~= "match" then return nil end
	local text, name
	if self.phase == "over" and self.overInfo and self.overInfo.file then
		text, name = self.overInfo.file.text, self.overInfo.file.name
	else
		local m = self.m
		text = notation.render(m.game, { start = m.start, version = session.client, mode = m.mode,
			levels = cmatch.fileLevels(m), location = session.location })
		local start = m.start or self.opts.start
		name = start and notation.filename(start, m.game.teams.A.name, m.game.teams.B.name) or "kubb-game.txt"
	end
	local shown = {}
	for line in text:gmatch("([^\n]*)\n") do
		if not gamefile.isPosition(line) then shown[#shown + 1] = gamefile.shown(line) end
	end
	return { text = text, name = name, shown = shown, done = self.phase == "over" }
end

-- ---------- what the client asks ----------

-- What the engine raised and placed before this throw (0.16.0; core/match settle): the
-- counts and, in the order done, each kubb: { kind = "raise", id, side (the side that
-- raised: the defender), which (the end, as a raise action names it), lying, standing
-- (poses in that side's view frame, raiseInfo's frame and shape), displaced, crowded } or
-- { kind = "punish", id, side, pose }. nil when the engine raised nothing (a person who
-- raised by hand, a throw with nothing to raise, a session restored after the raise).
local function plainSettled(st)
	if not st then return nil end
	local list = {}
	for i, e in ipairs(st.list or {}) do
		-- (0.17.0) the surroundings, as raiseInfo and punishInfo give them for a kubb by
		-- hand: every other piece and the king, in the raiser's view frame (a punishment
		-- kubb's others only those near its half, as punishInfo's)
		local others = {}
		for _, o in ipairs(e.others or {}) do
			local p = viewPose(e.side, o.pose)
			if e.kind == "raise" or (p.y >= -0.2 and p.y <= 4.2) then others[#others + 1] = { id = o.id, pose = p } end
		end
		if e.kind == "raise" then
			list[i] = { kind = "raise", id = e.id, side = e.side, which = e.which,
				lying = viewPose(e.side, e.lying), standing = viewPose(e.side, e.standing),
				displaced = e.displaced, crowded = e.crowded, others = others, king = viewPose(e.side, e.king),
				seat = viewSeat(e.side, e.seat) }
		else
			list[i] = { kind = "punish", id = e.id, side = e.side, pose = viewPose(e.side, e.pose),
				others = others, king = viewPose(e.side, e.king), seat = viewSeat(e.side, e.seat) }
		end
	end
	return { raised = st.raised, punished = st.punished, list = list }
end

local function plainSetup(setup)
	if not setup then return nil end
	return {
		kind = setup.kind, side = setup.side, projectile = setup.projectile, kubb = setup.kubb,
		-- a kubb's place in its round (0.17.0): with `rethrow`, among the kubbs rethrown
		n = setup.roundN or setup.n, of = setup.roundOf or setup.of, label = setup.label, kingShot = setup.kingShot or false,
		rethrow = setup.rethrow or false, lineY = setup.lineY, forwardY = setup.forwardY, advY = setup.advY,
		-- a Kid match (0.15.0): kid is true and kidY is the Kid line (view frame), which
		-- every kubb and baton at a kubb is thrown from (forwardY is where the thrower
		-- may stand up to: the Kid line, or the advantage line beyond it)
		kid = setup.kid, kidY = setup.kidY,
		targets = setup.targets, batonId = setup.batonId,
		-- key: the lineup's key for the player (on the web, the pitch member it belongs to)
		-- cpu (0.17.0): the thrower is a computer (a computer player in a team, or a
		-- player of a side the computer plays), so a client can say "computer · Pro"
		thrower = setup.thrower and { id = setup.thrower.id, name = setup.thrower.name,
			level = setup.thrower.level, key = setup.thrower.key, cpu = setup.thrower.cpu or nil,
			throw = setup.thrower.throw } or nil,
		settled = plainSettled(setup.settled),
	}
end

-- A side's players as a need names a thrower (1.4.0).
local function sidePlayers(m, side)
	local out = {}
	for i, p in ipairs(m.game.teams[side].players) do
		local e = cmatch.member(m, side, p.id)
		out[i] = { id = p.id, name = p.name, key = e and e.key, level = e and e.level,
			cpu = cmatch.isComputer(m, side, p.id) or nil, throw = e and e.throw or nil }
	end
	return out
end

-- One lying kubb's raise (view frame of the raiser): its pose, the engine's choices, its
-- two ends (footprints) and the default choice.
local function raiseEntry(self, side, id, pose, dec, ctx)
	local g = self.m.game
	-- the end the engine would stand it on for this side: a person's, the engine's best
	-- advice (cpu.advice, par; 0.12.0)
	local default = raising.choose(dec, ctx, cmatch.raisePolicy(self.m, side) or g.raisePolicy) or 1
	local choices = {}
	for i, c in ipairs(dec.choices) do
		choices[i] = { which = c.which, pose = viewPose(side, c.pose), displaced = c.displaced or false,
			crowded = c.crowded or false }
	end
	local ends = {}
	local fps = pose.standing and {} or raising.footprints(pose)
	for i = 1, #fps do
		local e = dec.ends and dec.ends[i]
		local ok = false
		for _, c in ipairs(dec.choices) do if c.which == i then ok = true end end
		ends[i] = { which = i, pose = viewPose(side, fps[i]), inBounds = e and e.inBounds or false,
			obstructedBy = e and e.obstructedBy or nil, ok = ok,
			why = (not ok) and ((e and not e.inBounds) and "THAT END IS OUT" or "THAT END IS BLOCKED") or nil }
	end
	return { id = id, pose = viewPose(side, pose), mode = dec.mode, choices = choices, ends = ends, default = default }
end

-- The raise: the kubb, its two ends (footprints), the engine's choices, the
-- default choice, the pieces near it (view frame of the defender). Since 1.4.0 also
-- every field kubb still lying (`lying`, in id order, the first being `kubb`), each with
-- its own pose, choices, ends and default: any of them may be raised next (a raise
-- action that names `kubb` and `which`); and the camera the whole raise is shown
-- through (`camera`: at the raiser's own end, every lying kubb, its ends and the king in
-- it; one for the raise, fitted again as the kubbs stand).
function Session:raiseInfo()
	local g, st = self.m.game, self.settle
	local n = g:need()
	local side = n.side
	local ctx = g:context(side, n.kubb)
	local dec = n.decision
	local first = raiseEntry(self, side, n.kubb, n.pose, dec, ctx)
	local others = {}
	for _, o in ipairs(ctx.others) do others[#others + 1] = { id = o.id, pose = viewPose(side, o.pose) } end
	local lying = { first }
	-- (1.4.1) the camera keeps the lying kubbs and their ends alone (camera.tune.raise)
	local pts = {}
	local king = viewPose(side, ctx.king)
	for _, id in ipairs(n.lying or {}) do
		if id ~= n.kubb then
			local d2, c2, k2 = g:raiseOptions(id)
			if d2 then lying[#lying + 1] = raiseEntry(self, side, id, k2.pose, d2, c2) end
		end
	end
	for _, e in ipairs(lying) do
		pts[#pts + 1] = { e.pose.x, e.pose.y, 0 }
		for _, en in ipairs(e.ends) do pts[#pts + 1] = { en.pose.x, en.pose.y, 0 } end
	end
	return {
		kind = "raise", side = side, kubb = n.kubb, pose = first.pose, mode = first.mode,
		choices = first.choices, ends = first.ends, default = first.default, others = others,
		king = king,
		n = st.raised + 1, of = max(st.raiseTotal or 0, st.raised + 1),
		team = upper(cmatch.teamName(side, g)),
		lying = lying, frame = side,
		camera = camera.fromEnd(nil, pts, session.viewBox, "raise"),
		-- (1.4.0) the raising side's players, as a throw's `thrower` (id, name, level, key,
		-- cpu, throw: each person's meter, absent standard): any of them may raise, and the
		-- one who throws next throws on their own `throw`
		players = sidePlayers(self.m, side),
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
			level = throw.levelFor(self.ts), set = self.opts.set, throw = self.opts.throw }
	end
	local out
	if self.phase == "over" then
		local o = self.overInfo
		out = { kind = "over", winner = o.winner, how = o.how, file = o.file, text = self.m.text,
			short = session.short(self.m.text) }
	elseif self.phase == "togo" then
		out = self:togoNeed()
	elseif self.phase == "settle" then
		out = (self.settle.mode == "raise") and self:raiseInfo() or self:punishInfo()
		out.cpu = false
		out["local"] = self.control[out.side] and true or false
	else
		local setup = self.setup
		local cpu = cpuThrow(self, setup)
		local ps = plainSetup(setup)
		if cpu and ps.thrower then ps.thrower.cpu = true end
		out = {
			kind = "throw", side = setup.side, setup = ps, cpu = cpu,
			["local"] = (cpu and self.control.cpu or (not cpu and self.control[setup.side])) and true or false,
			-- (0.17.0: when the team has more than one person; a computer is listed, not ok)
			candidates = (not cpu and cmatch.people(self.m, setup.side) > 1) and cmatch.candidates(self.m) or nil,
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
	-- a Kid match (0.15.0, docs/notes/kid-mode.md): a client may say so on screen
	if self.kind == "match" and self.opts.rules == "kid" then out.kid = true end
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
		rail.kind, rail.n, rail.of = st.projectile, st.roundN or st.n, st.roundOf or st.of
		rail.rethrow = st.rethrow or nil
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
			release = sol.release or ts.release, arcSet = ts.arcSet, tilt = ts.tilt, spin = ts.spin,
			level = throw.levelFor(ts), speed = sol.speed, loft = sol.loft, swivel = sol.swivel, dist = sol.dist,
			back = sol.back, powerLo = sol.powerLo, powerHi = sol.powerHi,
			releaseLo = sol.releaseLo, releaseHi = sol.releaseHi,
		},
		arc = arc,
		controls = throw.controls(ts),
		projectile = ts.projectile, drill = ts.drill,
		lineY = ts.lineY, forwardY = ts.forwardY, advY = ts.advY, advText = ts.advText, kidY = ts.kidY,
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
		advY = ts.advY, lineY = ts.lineY, kidY = ts.kidY,
		wind = ts.windText and { x = ts.windX, y = ts.windY, text = ts.windText } or nil,
	}
end

-- The match's pitch as it stands, in the frame it is shown in (self.frameSide), for a
-- session restored while no throw is set up (raising, punishment kubbs, the end): its
-- ts.items are throw.new's practice layout, so the pieces come from the match itself, as
-- core/match's setup makes them: the engine's pieces with the exact poses a throw left,
-- and the debris lying on the pitch. A live session keeps showing its last throw's own
-- items (the physical poses, a fallen king's included). The engine keeps no pose for a
-- king that fell and ends the match, so here it lies along its last angle. Display only:
-- nothing here is in the snapshot, and the match is not changed.
function Session:pitchItems()
	local m, side = self.m, self.frameSide
	local pieces = outcome.pieces(m.game, side)
	debris.applyExact(m.debris, pieces, side)
	local how = m.game.how
	if cmatch.over(m) and type(how) == "string" and how:find("^king") then
		for _, k in ipairs(pieces) do
			if k.id == "king" and not k.toppled then
				local v = frame.pose(side, k.pose)
				v.standing = false
				k.qw, k.qx, k.qy, k.qz = outcome.quatOf(v)
				k.z, k.toppled = nil, true -- resting height from the new pose
			end
		end
	end
	return throw.itemsOf(pieces, debris.pieces(m.debris, side), cmatch.surfaceName(m.game))
end

-- Everything the screen needs when nothing is playing back.
function Session:view()
	local ts = self.ts
	local items = (self.pitchFromMatch and self.phase ~= "throw") and self:pitchItems() or throw.items(ts)
	return {
		need = self:need(),
		items = items,
		minimap = self:minimap(items),
		aim = self:aimView(),
		camera = ts.aimCam,
		dial = throw.dial(ts, true),
		surface = ts.surface, set = ts.set,
		-- the scene to draw (a look only; "day" when the match names none)
		scene = self.opts.scene or tw.shared.lobby.OPTION_DEFAULTS.scene,
	}
end

-- ---------- aiming ----------

function Session:canAim()
	-- (1.4.0) and a baton to go this client has set up (togoPrepare)
	local ph = self.phase == "throw" or (self.phase == "togo" and self.togoAt ~= nil)
	return ph and self.ts.mode == "aim" and not self.ts.watching
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

function Session:setTilt(deg)
	if self:canAim() and type(deg) == "number" then throw.setTilt(self.ts, F(deg)) end
	return aimOut(self)
end

function Session:setSpin(taps)
	if self:canAim() and type(taps) == "number" then throw.setSpin(self.ts, F(taps)) end
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
	local key = surfaceKey(name)
	-- under a scene, only a surface it allows (else as it was)
	if self.sceneRule then
		local e = scenes.get(self.opts.scene)
		local ok = false
		for _, k in ipairs(e.surfaces) do if k == key then ok = true end end
		if not ok then key = self.opts.surface end
	end
	self.opts.surface = key
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
	-- (1.4.0) the sides whose baton to go this client throws (seats.controlFor with a togo
	-- need): a host that may stand in for both sides throws only the one it is given
	if type(c.togo) == "table" then
		self.control.togo = {}
		for _, side in ipairs(c.togo) do
			if side == "A" or side == "B" then self.control.togo[side] = true end
		end
	end
	-- (0.17.0) this client now throws for the computer, which another was throwing for and
	-- this one held at the release (the host changed mid-throw): it releases on the next
	-- frame, the very throw the other would have made
	if self.control.cpu and self.ts.mode == "cpuhold" then self.ts.mode = "cpuswing" end
	if self.ts.touch and self.setup and not self.control[self.setup.side] then
		tw.web.touch.frame(self.ts, { { phase = "cancel" } })
	end
	-- (1.4.0) the throw to go: this client's baton is the first side it now controls that
	-- owes one
	if self.phase == "togo" then
		if self:togoMine() ~= self.togoAt then self:togoPrepare() end
	end
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
			scatter = L.scatter,   -- a drilled kubb's: the hand's steadiness (0.11; nil: 1)
		},
		stance = { x = ts.playerX, y = ts.playerY, set = ts.stanceSet },
		target = { x = ts.markerX, y = ts.markerY, set = ts.markerSet, on = ts.markerOnId },
		scripted = info.scripted or false, input = info.input,
	}
	if info.back then a.swing = { back = info.back, stop = info.stop } end
	-- a person's throw names its plan (since 0.9): the planned release and the baton's tilt
	-- or the kubb's spin as the thrower chose them. Every client applies the launch, never
	-- these; the kubb's spin is kept for the side's next kubb (throw.prepare) and a server
	-- checks against them (session/check)
	if not info.scripted then
		local sol = ts.sol or {}
		if ts.projectile == "kubb" then
			a.plan = { release = F(sol.release or ts.release), spin = F(ts.spin or 0) }
		else
			a.plan = { release = F(sol.release or ts.release), tilt = F(ts.tilt or 0) }
		end
	end
	if info.verdicts then
		a.verdicts = { powerV = info.verdicts.powerV, releaseV = info.verdicts.releaseV,
			steady = info.verdicts.steady and true or false, sideV = info.verdicts.sideV }
	end
	return a
end

-- A report needs only the practice pitch immediately before its throw. Keep the
-- unrounded bodies in their solver order and the counters used for projectile IDs.
-- The throw action supplies the launch, stance and target. Match snapshots use
-- their own format; this checkpoint is only for replaying one practice throw.
local function practiceCheckpoint(s)
	local ts = s.ts
	return json.encode { items = ts.items, surface = ts.surface, set = ts.set, scene = s.opts.scene,
		level = throw.levelFor(ts), throw = s.opts.throw,
		drill = ts.drill, drillSeq = ts.drillSeq, baton = ts.practiceBaton,
		throws = s.throws }
end

function session.restorePractice(text)
	local c = json.decode(text)
	local s = session.new { mode = "practice", surface = c.surface, set = c.set, scene = c.scene, level = c.level,
		throw = c.throw }
	local ts = s.ts
	ts.items, ts.drillSeq, ts.practiceBaton = c.items, c.drillSeq, c.baton
	s.throws, ts.throws = c.throws, c.throws
	throw.setDrill(ts, c.drill)
	return s
end

-- Run a throw action: the same path for the actor and for every other
-- browser (docs/SESSION.md "Determinism"). Returns the recording.
function Session:applyThrow(a)
	if self.kind == "match" then
		assert(self.phase == "throw", "no throw set up")
		assert(I(a.seq) == self.throws, "throw out of step: seq " .. tostring(a.seq) .. ", expected " .. self.throws)
	end
	local ts = self.ts
	self.togoShow = nil
	if self.kind == "practice" then self.practiceBefore = practiceCheckpoint(self) end
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
		scatter = F(l.scatter),
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
	local cpuSide = self.kind == "match" and cpuThrow(self, self.setup)
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
		rec.result.ruling = session.ruling(m)
		session.kingUpResult(rec.result, m.ruling)
		ts.flagText = session.short(m.text)
		ts.mode = "aim"
		ts.watching = false
		-- a person's kubb keeps its spin for the side's next kubb (throw.prepare): taken
		-- from the action, so every client and a restore hold the same value
		if not cpuSide and how == "drill" and type(a.plan) == "table" then
			local sp = a.plan.spin
			if type(sp) == "number" and sp == sp then
				local m3 = plan.tune.spinSteps
				sp = F(max(-m3, min(m3, sp)))
				ts.keptSpin = sp ~= 0 and sp or nil
			end
		end
		self:advance()
	end
	rec.input = a.input
	rec.seq = self.throws - 1
	self.recording = rec
	return rec
end

-- ---------- the frame ----------

-- A host's time stamp for an action it makes (0.18.0): { year, month, day, hour, min } on
-- the start's clock (docs/SESSION.md "Actions", `at`), whole numbers, or nil. Anything else
-- is no stamp: the engine never invents one.
local function stampOf(at)
	if type(at) ~= "table" then return nil end
	local o = {}
	for _, k in ipairs { "year", "month", "day", "hour", "min" } do
		local v = at[k]
		if type(v) ~= "number" or v ~= v or v ~= math.floor(v) then return nil end
		o[k] = math.tointeger(v) or v
	end
	return o
end
session.stampOf = stampOf

-- ---------- the throw to go (1.4.0; docs/SESSION.md "The throw to go") ----------
-- Before turn 1, each team throws one baton from its own baseline at the king (core/togo).
-- Blind and simultaneous: each side's baton is an action of its own ({ type = "togo",
-- side, round, ... }, no seq: it is no throw of the match), kept until both are in; then
-- each is thrown on its own world, the pitch as the match starts, the two are judged
-- (togo.decide) and one recording shows both. A computer's baton is the engine's, made
-- when the people's are in (mix(seed, 5, ...)), so it never sees theirs.

-- Does the computer throw `side`'s baton to go (the side's first player is a computer,
-- or the computer plays the side whole)?
function Session:togoCpu(side)
	if isCpu(self, side) then return true end
	return cmatch.togoThrower(self.m, side).cpu == true
end

-- The sides that still owe a baton to go (a person's to throw), in A, B order.
function Session:togoOwed()
	local out = {}
	local tg = self.togo
	if not tg then return out end
	for _, side in ipairs { "A", "B" } do
		if not tg.acts[side] and not self:togoCpu(side) then out[#out + 1] = side end
	end
	return out
end

-- The phase starts (or a round starts again): the aim memory a fresh throw state has, and
-- this client's baton set up.
function Session:togoBegin()
	self.ts = throw.new { surface = self.opts.surface, set = self.opts.set, meter = session.meterOf(self.opts) }
	self.pre = { side = nil, lastThrower = nil, mem = memOf(self.ts) }
	self.phase = "togo"
	self.card, self.windInfo, self.settle = nil, nil, nil
	self:togoPrepare()
end

-- The side whose baton to go this client throws next: the first side, A then B, that owes
-- one and that this client controls (one device: A's, then B's), or, when setControl gave a
-- `togo` list (a pitch), the first owed side in it.
function Session:togoMine()
	local only = self.control.togo
	for _, s2 in ipairs(self:togoOwed()) do
		if self.control[s2] and (not only or only[s2]) then return s2 end
	end
	return nil
end

-- Set this client's next baton to go up (togoMine).
function Session:togoPrepare()
	local side = self:togoMine()
	self.togoAt = side
	if not side then
		self.setup = nil
		return
	end
	local setup = cmatch.togoSetup(self.m, side)
	self.setup = setup
	local ts = self.ts
	ts.throwLevel = setup.thrower.throw
	throw.prepare(ts, setup)
	self.frameSide = side
	ts.level = setup.thrower.level
	ts.watching, ts.scripted = false, false
	-- no wind: the two batons are judged against each other, thrown on two worlds
	ts.windX, ts.windY, ts.windText = 0, 0, nil
	-- the starting circle: short of the king on the ground, at the arc a baton to go is
	-- thrown on (togo.tune; the person may move either)
	if togo.tune.arc then throw.setArc(ts, togo.arc()) end
	local kx, ky = pitch.king.x, pitch.king.y - togo.tune.markerShort
	throw.setTarget(ts, kx, ky, false)
	self.rail = { r1 = "TO GO" }
	ts.railName = self:railName(setup)
end

-- The computer's baton to go for `side` in this round: an action as a person's, made by
-- the engine (togo.cpuThrow at the thrower's level, the computer's scatter).
function Session:togoCpuAction(side)
	local tg = self.togo
	local setup = cmatch.togoSetup(self.m, side)
	local th = setup.thrower
	local level = th.level or self.opts.computer or autothrow.tune.level
	local r = rngFor(self, 5, 2 * tg.round + (side == "B" and 1 or 0))
	local c = togo.cpuThrow(setup, r, level, tw.web.tune.throw.cpuScatter)
	local L = c.launch
	local a = {
		type = "togo", side = side, round = tg.round, how = "baton", cpu = true,
		launch = { speed = L.speed, loft = L.loft, swivel = L.swivel, tilt = L.tilt or 0, tumble = L.tumble or 0,
			legal = L.legal ~= false },
		stance = { x = c.x, y = c.y, set = true },
		target = { x = c.tx, y = c.ty, set = true },
		scripted = true,
	}
	if c.swing then a.swing = { back = c.swing.back, stop = c.swing.releaseAngle } end
	return json.decode(json.encode(a))
end

-- One baton to go thrown on its own world: the throw state it was thrown on, its
-- recording, its gap to the king (togo.gap) and whether the king fell.
function Session:togoFire(a)
	local side = a.side
	local setup = cmatch.togoSetup(self.m, side)
	local ts = throw.new { surface = self.opts.surface, set = self.opts.set, meter = session.meterOf(self.opts) }
	ts.throwLevel = setup.thrower.throw
	throw.prepare(ts, setup)
	ts.level = setup.thrower.level
	ts.windX, ts.windY, ts.windText = 0, 0, nil
	local st, tg = a.stance or {}, a.target or {}
	ts.playerX, ts.playerY, ts.stanceSet = F(st.x), F(st.y), st.set and true or false
	ts.markerX, ts.markerY, ts.markerSet, ts.markerOnId = F(tg.x), F(tg.y), tg.set and true or false, tg.on
	local l = a.launch or {}
	local L = { speed = F(l.speed), loft = F(l.loft), swivel = F(l.swivel), tilt = F(l.tilt or 0),
		tumble = F(l.tumble or 0), legal = l.legal ~= false }
	local verdicts
	if a.verdicts then
		verdicts = { powerV = I(a.verdicts.powerV), releaseV = I(a.verdicts.releaseV), steady = a.verdicts.steady,
			sideV = a.verdicts.sideV and I(a.verdicts.sideV) or nil }
	end
	local sw = a.swing
	ts.scripted = a.scripted and true or false
	ts.watching, ts.cpuTarget, ts.camMix = false, false, 0
	local rec = throw.fire(ts, L, "baton", { verdicts = verdicts, back = sw and F(sw.back), stop = sw and F(sw.stop) })
	local gap, toppled = togo.gap(ts.last.res, setup.batonId)
	local b = ts.last.res.bodies[setup.batonId]
	return ts, rec, gap, toppled, b
end

-- The frame the throw to go is shown in on this client: A's, unless it plays B alone.
function Session:togoSide()
	if self.control.B and not self.control.A then return "B" end
	return "A"
end

-- Both batons are in: throw both, judge them, and start turn 1 (or throw again).
function Session:togoResolve()
	local tg = self.togo
	local lasts, e, res = {}, {}, {}
	local view = session.viewSide or self:togoSide()
	for _, side in ipairs { "A", "B" } do
		local ts, rec, gap, toppled, b = self:togoFire(tg.acts[side])
		lasts[side] = ts.last
		e[side] = { gap = gap, toppled = toppled }
		local mm = togo.mm(gap)
		local r = { gap = gap ~= math.huge and F(gap) or nil, mm = mm ~= math.huge and mm or nil, toppled = toppled,
			cpu = tg.acts[side].cpu or nil, verdicts = rec.result.verdicts }
		if b then
			-- where the baton came to rest, in the frame the recording is in
			local x, y = b.x, b.y
			if side ~= view then x, y = frame.point("B", x, y) end
			r.restX, r.restY = F(x), F(y)
		end
		res[side] = r
	end
	local v = togo.decide(e)
	local rounds = tg.round
	-- the king shown: the one that fell (so its fall is seen), else the winner's
	local kingFrom = (e.A.toppled and "A") or (e.B.toppled and "B") or v.first or "A"
	local result = { togo = true, A = res.A, B = res.B, first = v.first, how = v.how, why = v.why, round = rounds }
	result.text = togo.text(e, v, rounds)
	local rec = throw.togoRecording(lasts, view, kingFrom, result)
	-- the camera it is shown through: at the viewer's end, the king and both batons in it
	-- (1.4.1: from a person's eyes on the viewer's baseline, a point 2 m out stands for
	-- the viewer's own baton leaving, where before the baseline itself was kept)
	local pts = { { 0, 2, 0 }, { 0, pitch.king.y, 0.4 }, { 0, pitch.length, 0 } }
	for _, side in ipairs { "A", "B" } do
		if res[side].restX then pts[#pts + 1] = { res[side].restX, res[side].restY, 0 } end
	end
	local cam = camera.fromEnd(nil, pts, session.viewBox, "end")
	self.togoShow = { lasts = lasts, side = view, kingFrom = kingFrom, cam = cam }
	self.recSide = view
	self.togoLast = result
	if v.how == "again" then
		self.togo = { round = rounds + 1, acts = {} }
		self:togoBegin()
	else
		cmatch.setFirst(self.m, v.first, result.text)
		self.togo, self.togoAt = nil, nil
		self.ts = throw.new { surface = self.opts.surface, set = self.opts.set, meter = session.meterOf(self.opts) }
		self.side, self.lastThrower = nil, nil
		self:advance()
	end
	rec.seq = nil
	self.recording = rec
	return rec
end

-- A baton to go from this client or another: { type = "togo", side, round, launch, stance,
-- target, swing?, verdicts?, plan?, input?, at? }. Refused (ok = false, why) out of its
-- phase or round, for a side that has thrown or that the computer throws for. Returns
-- { ok, recording? (once both are in), need }.
function Session:applyTogo(a)
	local tg = self.togo
	local function no(why) return { ok = false, why = why, need = self:need() } end
	if self.kind ~= "match" or self.phase ~= "togo" or not tg then return no("no throw to go") end
	if type(a) ~= "table" or I(a.round) ~= tg.round then return no("not this round") end
	local side = a.side
	if side ~= "A" and side ~= "B" then return no("no such side") end
	if tg.acts[side] then return no("thrown") end
	if self:togoCpu(side) then return no("the computer's") end
	if type(a.launch) ~= "table" then return no("no launch") end
	local stamp = stampOf(a.at)
	-- kept (in the snapshot while the other baton is owed) with only the fields a baton
	-- reads, so nothing a client added rides along (session/namecheck checks each string)
	local keep = {}
	for _, k in ipairs { "type", "side", "round", "how", "launch", "stance", "target", "swing", "verdicts",
		"plan", "input", "scripted", "at" } do keep[k] = a[k] end
	tg.acts[side] = json.decode(json.encode(keep))
	if stamp then self.finish = stamp end
	if #self:togoOwed() > 0 then
		-- a new baton only when this client's changes (the side it threw is in): the other
		-- side's arriving leaves the baton it is aiming or swinging as it is
		if self:togoMine() ~= self.togoAt then self:togoPrepare() end
		return { ok = true, need = self:need() }
	end
	for _, s2 in ipairs { "A", "B" } do
		if not tg.acts[s2] then tg.acts[s2] = self:togoCpuAction(s2) end
	end
	local rec = self:togoResolve()
	return { ok = true, recording = rec, need = self:need() }
end

-- The throw to go's need (Session:need).
function Session:togoNeed()
	local tg = self.togo
	local thrower = {}
	for _, side in ipairs { "A", "B" } do
		local th = cmatch.togoThrower(self.m, side)
		thrower[side] = { id = th.id, name = th.name, level = th.level, key = th.key,
			cpu = self:togoCpu(side) or nil, throw = th.throw }
	end
	local ps = self.togoAt and plainSetup(self.setup) or nil
	if ps then ps.togo = true end
	return {
		kind = "togo", round = tg.round, owe = self:togoOwed(), side = self.togoAt, setup = ps,
		thrown = { A = tg.acts.A ~= nil, B = tg.acts.B ~= nil },
		throwers = thrower,
		-- which side's baton the computer throws (not `cpu`: no one acts for the computer
		-- here; the engine makes its baton when the people's are in)
		computer = { A = self:togoCpu("A"), B = self:togoCpu("B") },
		cpu = false,
		["local"] = self.togoAt ~= nil,
		-- the last round's verdict when this is a throw again (a tie, or both kings down)
		again = self.togoLast,
	}
end

-- One frame while aiming (docs/SESSION.md "The frame"). inp = { dt, arm,
-- plan, move = {dx, dy}, walk = {dx, dy}, at (a host's stamp for the action it makes) }.
-- Returns { dial, camera, aim, event, action, recording, need }.
function Session:frame(inp)
	inp = inp or {}
	local dt = F(inp.dt or 1 / 60)
	if dt <= 0 then dt = 1 / 60 end
	if dt > 0.1 then dt = 0.1 end
	local ts = self.ts
	local out = {}
	local togoPhase = self.phase == "togo"
	if self.phase ~= "throw" and not (togoPhase and self.togoAt) then
		out.dial = throw.dial(ts, true)
		return out
	end
	local cpu = self.kind == "match" and not togoPhase and cpuThrow(self, self.setup)
	-- the computer's speed (1.4.0, docs/SESSION.md "The computer's turn, fast"): 1, 2 or 4
	-- (any of 1 to 8) times the frame's time for its think and swing, after the cap, so a
	-- client at 60 frames a second plays its turn 2 or 4 times as fast. The time never
	-- changes what it throws (its throw is chosen before it shows: autothrow.choose)
	if cpu then
		local sp = F(inp.speed or 1) or 1
		if sp ~= sp or sp < 1 then sp = 1 elseif sp > 8 then sp = 8 end
		dt = dt * sp
	end
	local ev, L, how, info, crossings
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
	elseif self.kind == "match" and not togoPhase and not self.control[self.setup.side] then
		-- someone else's throw: their aim comes in by showAim
		throw.aimCamera(ts)
		out.dial = throw.dial(ts, true)
		out.camera = ts.aimCam
		out.aim = self:aimView()
		return out
	else
		local changed, input
		ev, changed, input = throw.aimFrame(ts, inp)
		crossings, ts.crossings = ts.crossings, nil
		if ev == "release" then
			local r = ts.swing.result
			L, how = throw.playerLaunch(ts, r)
			info = { input = input or "pointer", back = r.back, stop = r.releaseAngle, verdicts = L }
		end
	end
	out.event = ev
	if L then
		local action = self:throwAction(L, how, info)
		if togoPhase then
			-- a baton to go (1.4.0): no seq, its side and round instead
			action.type, action.seq, action.side, action.round = "togo", nil, self.togoAt, self.togo.round
		end
		-- the host's stamp (0.18.0): on the action, so every client applying it gets the
		-- same finish
		local at = stampOf(inp.at)
		if at then action.at = at end
		-- the actor runs the action exactly as every other browser will: through JSON
		action = json.decode(json.encode(action))
		out.action = action
		if togoPhase then
			out.recording = self:applyTogo(action).recording
		else
			out.recording = self:applyThrow(action)
		end
		out.need = self:need()
	end
	out.dial = throw.dial(ts, not L)
	out.dial.crossings = crossings
	out.camera = ts.aimCam
	out.aim = self:aimView()
	return out
end

-- The last throw at shown time t.
function Session:showAt(t)
	if self.togoShow and self.recording and self.recording.kind == "togo" then
		-- the throw to go's two batons (1.4.0), through its fixed camera at the viewer's end
		local g = self.togoShow
		local r = throw.togoShowAt(g.lasts, g.side, g.kingFrom, F(t or 0))
		r.camera = g.cam
		r.dial = throw.dial(self.ts, false)
		return r
	end
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

function Session:checkPunish(x, y, fs)
	assert(self.phase == "settle" and self.settle.mode == "punish", "no punishment kubb to place")
	local g = self.m.game
	local n = g:need()
	-- (1.4.0) fs: the frame x, y are in (a client's view from one side, need.frame)
	local wx, wy = frame.point((fs == "A" or fs == "B") and fs or n.side, F(x), F(y))
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
	if t == "togo" then return self:applyTogo(a) end
	assert(self.kind == "match", "only a match takes " .. tostring(t))
	local g = self.m.game
	-- a raise or a punishment kubb placed by hand carries the host's stamp as a throw does
	-- (0.18.0), so a match that ends on the next throw's resignation still has a finish.
	-- Kept only once the action is taken: a refused one must leave the match as it was,
	-- since `finish` is in the snapshot and its hash
	local stamp = (t == "raise" or t == "punish") and stampOf(a.at) or nil
	if t == "raise" and a.kubb ~= nil then
		-- (1.4.0) a raise that names its kubb (any of need.lying) and its end (`which`, as
		-- raiseInfo's choices name it; absent: the side's choice). Refused, the match as
		-- it was, when that kubb is not lying in the half or that end cannot stand: so a
		-- teammate's raise applied again after another's (a pitch's refusal and retry)
		-- raises the kubb it named or is cleanly refused
		if not (self.phase == "settle" and self.settle.mode == "raise") then
			return { ok = false, why = "not raising", need = self:need() }
		end
		local which = a.which ~= nil and I(a.which) or nil
		local ok, why = g:canRaise(a.kubb, which)
		if not ok then return { ok = false, why = why, label = upper(why), need = self:need() } end
		local n = g:need()
		g:raiseKubb(a.kubb, which, cmatch.raisePolicy(self.m, n.side))
		if stamp then self.finish = stamp end
		self.settle.raised = self.settle.raised + 1
		self.card = nil
		if not settleBegin(self) then self.settle = nil; self:advance() end
		return { ok = true, need = self:need() }
	elseif t == "raise" then
		assert(self.phase == "settle" and self.settle.mode == "raise", "no kubb to raise")
		local choice = a.choice and I(a.choice) or nil
		local n = g:need()
		local dec = n.decision
		assert(choice == nil or dec.choices[choice], "no raising choice " .. tostring(choice))
		-- no choice: the default raiseInfo offered (the side's policy, match.raisePolicy)
		g:raise(choice, cmatch.raisePolicy(self.m, n.side))
		if stamp then self.finish = stamp end
		self.settle.raised = self.settle.raised + 1
		self.card = nil
		if not settleBegin(self) then self.settle = nil; self:advance() end
		return { ok = true, need = self:need() }
	elseif t == "punish" then
		assert(self.phase == "settle" and self.settle.mode == "punish", "no punishment kubb to place")
		local n = g:need()
		-- (1.4.0) a.frame: the frame x, y are in (need.frame in a view from one side); absent,
		-- the placing side's
		local fs = (a.frame == "A" or a.frame == "B") and a.frame or n.side
		local wx, wy = frame.point(fs, F(a.x), F(a.y))
		local ok, why = g:placePunishment({ x = wx, y = wy, standing = true, angle = 0 })
		if not ok then return { ok = false, why = why, label = whyLabel(why), need = self:need() } end
		if stamp then self.finish = stamp end
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
		self.ts.throwLevel = setup.thrower.throw
		self.ts.planDirty = true
		throw.replan(self.ts)
		self.ts.railName = self:railName(setup)
		if self.card and self.card.kind == "handoff" then self.card.handoff = cards.handoff(self.m, setup)
		elseif self.card and self.card.kind == "pass" then self.card.pass = cards.pass(self.m, setup) end
		return { ok = true, need = self:need() }
	end
	error("unknown action " .. tostring(t))
end

-- ---------- checking a shared match (docs/SESSION.md "What a server can prove") ----------

-- The computer's next throw as Session:frame makes it (the same choice, aim, launch and
-- action, through JSON), without running it. It moves this session's aim (throw.cpuBegin),
-- so call it on a session restored for the purpose (session/replay does). The choice is
-- seeded by the match seed and the throws so far (mix(seed, 1, throws)) and read from the
-- set-up, so the snapshot before the throw is all it needs.
function Session:cpuAction(at)
	assert(self.kind == "match" and self.phase == "throw" and cpuThrow(self, self.setup),
		"cpuAction: not the computer's throw")
	local ts = self.ts
	local a = autothrow.choose(self.setup, rngFor(self, 1, self.throws), tw.web.tune.throw.cpuScatter)
	throw.cpuBegin(ts, a)
	local L, how = throw.cpuLaunch(ts, a)
	ts.playerX, ts.playerY = a.x, a.y
	local info = { scripted = true, back = a.swing and a.swing.back, stop = a.swing and a.swing.releaseAngle }
	local action = self:throwAction(L, how, info)
	local st = stampOf(at)
	if st then action.at = st end
	return json.decode(json.encode(action))
end

-- The computer's turn, fast (1.4.0; docs/SESSION.md "The computer's turn, fast"): every
-- computer throw from here until a person is needed, with no frames: each the action
-- Session:frame would have made (cpuAction) applied as any action is (applyThrow), so the
-- match ends exactly as a watched one does, throw for throw and hash for hash. Only
-- where this client throws for the computer (control.cpu). o = { at? } (a host's stamp
-- for every action it makes). Returns { steps = [{ a, h, seq, side, text, short, ruling,
-- recording? }], need, view }: each step's action and the hash after it (a log's entry,
-- docs/SESSION.md "Replay"), what it did, and, with o.recordings, its recording; then the
-- need and the view as they stand (a person's throw, a raise by hand, or the end).
function Session:cpuPlay(o)
	o = o or {}
	local steps = {}
	while self.kind == "match" and self.phase == "throw" and cpuThrow(self, self.setup) and self.control.cpu do
		local side = self.setup.side
		local a = self:cpuAction(o.at)
		local rec = self:applyThrow(a)
		local st = { a = a, h = self:hash(), seq = a.seq, side = side, text = self.m.text,
			short = self.m.text and session.short(self.m.text) or nil, ruling = rec.result.ruling }
		if o.recordings then st.recording = rec end
		steps[#steps + 1] = st
	end
	return { steps = steps, need = self:need(), view = self:view() }
end

-- Standing kubbs in each half now, by role, and the king: { A = { field, base }, B = ...,
-- king } (a toppled field kubb waiting to be raised is not standing).
function Session:standing()
	if self.kind ~= "match" then return nil end
	local g = self.m.game
	local out = { king = g.king.pose.standing and true or false }
	for _, side in ipairs { "A", "B" } do
		local field, base = 0, 0
		for _, k in ipairs(g:fieldKubbs(side)) do if k.pose.standing then field = field + 1 end end
		for _, k in ipairs(g:baseKubbs(side)) do if k.pose.standing then base = base + 1 end end
		out[side] = { field = field, base = base }
	end
	return out
end

local function copyTable(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copyTable(x) end
	return out
end

-- The newMatch options a match's first snapshot was made from (without mode = "match", as
-- a pitch's document keeps them): a new match from them makes that very snapshot
-- (session.startCheck says whether it does).
function session.setupOf(start)
	local d = type(start) == "string" and json.decode(start) or start
	assert(type(d) == "table" and d.v == session.snapshotVersion and type(d.opts) == "table",
		"not a snapshot of this version")
	local o = copyTable(d.opts)
	o.modeName, o.mode = o.mode, nil
	return o
end

local function newFromSetup(o)
	local c = copyTable(o)
	c.mode = "match"
	return session.new(c)
end

-- Is `start` a match's first snapshot, one session.new makes (no throw, nothing done)?
-- Returns true, or false and why.
function session.startCheck(start)
	needTune()
	local ok, d = pcall(json.decode, start)
	if not ok or type(d) ~= "table" or d.v ~= session.snapshotVersion then return false, "not a snapshot" end
	if I(d.throws) ~= 0 then return false, "not a start: throws made" end
	local ok2, s = pcall(newFromSetup, session.setupOf(d))
	if not ok2 then return false, "not a start: " .. tostring(s) end
	if s:snapshot() ~= start then return false, "not a start: a new match from its options differs" end
	return true
end

-- The start with a side's names changed (docs/SESSION.md "Renaming a side"). names =
-- { A = "<name>" } or { A = { name = "<team>", players = { "<name>", ... } } } (B the
-- same). A plain name is the team's and, on a side of one player, the player's too. The
-- match is made again from the start's options with the new names, so the ids made from
-- them follow and nothing else changes; the start must be one session.new makes.
function session.renameStart(start, names)
	local ok, why = session.startCheck(start)
	assert(ok, "renameStart: " .. tostring(why))
	assert(type(names) == "table", "renameStart: { A = \"<name>\" }")
	local o = session.setupOf(start)
	for _, side in ipairs { "A", "B" } do
		local n = names[side]
		if n ~= nil then
			local t = o.teams[side]
			if type(n) == "string" then n = { name = n, players = (#t.players == 1) and { n } or nil } end
			assert(type(n) == "table", "renameStart: a name or { name, players } for " .. side)
			if n.name ~= nil then
				assert(type(n.name) == "string" and #n.name >= 1, "renameStart: a team name for " .. side)
				t.name = n.name
			end
			if n.players ~= nil then
				assert(type(n.players) == "table" and #n.players == #t.players,
					"renameStart: one name for each of side " .. side .. "'s " .. #t.players .. " players")
				for i, p in ipairs(n.players) do
					assert(type(p) == "string" and #p >= 1, "renameStart: a player's name")
					t.players[i].name = p
				end
			end
		end
	end
	return newFromSetup(o):snapshot()
end

-- The players' ids (notation.assignIds) come from their names, so a rename changes them,
-- and a log's `thrower` actions name players by id. session.renameIds(start, renamed):
-- { [old id] = new id } for every player, matched by side and place. session.renameLog(
-- log, ids): a copy of the log ([{ a }], the hashes dropped: a renamed match has its own)
-- with each thrower action's id mapped, so the renamed match replays as the original did.
function session.renameIds(start, renamed)
	local a, b = session.restore(start), session.restore(renamed)
	local ids = {}
	for _, side in ipairs { "A", "B" } do
		local pa, pb = a.m.game.teams[side].players, b.m.game.teams[side].players
		assert(#pa == #pb, "renameIds: side " .. side .. " has other players")
		for i, p in ipairs(pa) do ids[p.id] = pb[i].id end
	end
	return ids
end

function session.renameLog(log, ids)
	assert(type(log) == "table", "renameLog: a log [{ a }]")
	local out = {}
	for i, e in ipairs(log) do
		local x = copyTable(e.a)
		if type(x) == "table" and x.type == "thrower" and ids[x.id] then x.id = ids[x.id] end
		out[i] = { a = x }
	end
	return out
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
		-- the throw to go while it is undecided (1.4.0): its round and the batons in
		togo = self.togo and { round = self.togo.round, A = self.togo.acts.A, B = self.togo.acts.B } or nil,
	}
end

function Session:snapshot()
	return json.encode(self:snapshotTable())
end

function Session:hash()
	return fnv(self:snapshot())
end

-- opts (since 0.13.4): { names = "check" } refuses, before anything is made, a snapshot
-- with a name (or any text) that session/namecheck does not allow: for a match that came
-- from someone else. Absent, every snapshot of this version restores as before (a
-- person's own kept match with typed names too).
function session.restore(text, control, opts)
	needTune()
	local d = type(text) == "string" and json.decode(text) or text
	assert(type(d) == "table" and d.v == session.snapshotVersion, "not a snapshot of this version")
	if opts and opts.names ~= nil then
		tw.web.namecheck.strict(opts.names, "restore", function() return tw.web.namecheck.snapshot(d) end)
	end
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
	-- the sides the computer plays (match.raisePolicy): not in the save, so from the options
	m.cpu = s.opts.cpu
	s.m = m
	s.byHand = s.opts.raising == "hand"
	s.ts = throw.new { surface = s.opts.surface, set = s.opts.set, meter = session.meterOf(s.opts) }
	setMem(s.ts, d.mem or {})
	s.side, s.lastThrower = d.side, d.lastThrower
	if d.settle then
		s.settle = { raised = I(d.settle.raised), placed = I(d.settle.placed), raiseTotal = I(d.settle.raiseTotal),
			punishTotal = I(d.settle.punishTotal) }
	end
	-- ts holds throw.new's layout until a throw is set up: until then the view draws the
	-- match's pitch (Session:pitchItems) in the frame a live session holds it in, the last
	-- throw's
	s.pitchFromMatch, s.frameSide = true, s.side
	if s.opts.togo and not m.game.firstBy then
		-- (1.4.0) the throw to go is undecided: its round and the batons already in
		local t = type(d.togo) == "table" and d.togo or {}
		s.togo = { round = I(t.round or 1), acts = { A = t.A, B = t.B } }
		s:togoBegin()
		if control then s:setControl(control) end
		return s
	end
	s:advance()
	if control then s:setControl(control) end
	return s
end

tw.web.session = session
