-- The names in a match that came from outside (docs/SESSION.md "Names", docs/NAMES.md
-- section 6): kubbCall("names.check", { snap | replay | document }) and the strict
-- restore and replayLoad (names = "check"). Pure like the core; it reads what it is given
-- and changes nothing: no session is made, restored or touched.
--
-- A client should not have to know which fields of a snapshot reach the screen, so the
-- engine answers. A snapshot is walked whole: every string in it, at every depth, is held
-- to what the engine writes at that place, and a string at a place the engine never
-- writes one is refused. So nothing a restored match can show (the rail, the teams, the
-- thrower, the score sheet and its file name, the winner card, the ruling line) can come
-- from a field this does not look at. What each place is, and the code that shows it:
--
--   opts.teams.<side>.name, .players[i].name   the names a match is made from (setupOf,
--       checkStart, renameStart; a replay from its setup): team / player
--   save.game.teams.<side>.name                the rail (Session:railName), need.teams,
--       the winner card (core/cards.winner, match.howText), the ruling line ("<team>
--       resigned: <team> wins", "king down: <team> wins"), the sheet's [Team A] header and
--       its file name (notation.render, notation.filename): team, or on a side of one
--       player, that player's name
--   save.game.teams.<side>.players[i].name     the rail on a side of several, the thrower
--       (need.setup.thrower, candidates), the pass and hand-off cards (core/cards), the
--       winner card's players, [Team A Players]: player
--   save.game.teams.<side>.players[i].id       made from the name (notation.assignIds);
--       the sheet writes it (header, turn lines, [Throw Levels]): must be the id the
--       engine makes from the names
--   every other player id (sheet turns, order, lineup, kubbs' inkBy, lastThrower): one
--       of those ids (a turn line writes an id it does not know as it is)
--   save.text                                  the ruling line (need.last): the engine's
--       own words with the match's team names in their places
--   save.game.how                              the winner card's line (match.howText
--       gives an unknown one as it is)
--   save.game.sheet.turns[].notes[]            the turn line's "# ..." note
--   save.game.sheet.turns[].batons[].token     the turn line's tokens
--   save.mode, opts.mode                       the sheet's [Mode]
--   save.game.surface, .first, .winner         the sheet's headers
--   save.lineup.<side>[].level, opts levels    [Throw Levels] (cpu.levelName writes it)
--   save.lineup.<side>[].throw, opts players' throw   a person's throw level (1.3.0):
--       easy, standard or hard; [Throw Levels] writes easy and hard
--   opts.set, opts.scene                       a set and a scene core/scenes lists
--   the rest (sides, phases, kubb and piece ids, keys)  never shown, held to the values
--       the engine writes so a string cannot hide in them
--
-- Results (every `from` is a path a person can read, JSON indices from 0):
--   { what, allowed, names = [{ text, from, kind, as?, ok, default }],
--     ids = [{ text, from, name, ok }], lines = [{ text, from, kind, ok }],
--     refused = [{ text, from, kind, why }], mismatches = [{ from, other, text, otherText }] }
-- allowed: no name, id, line or other text is refused and nothing disagrees.
import "core/tw"
import "core/namegen"
import "core/notation"
import "core/wind"
import "core/throwplan"
import "core/raising"
import "core/scenes"
import "session/json"
import "pitch/lobby"

local namegen, notation, wind, plan, raising = tw.namegen, tw.notation, tw.wind, tw.plan, tw.raising
local json, lobby = tw.web.json, tw.shared.lobby
local NULL = json.null

local nc = {}

-- How deep a document may nest before it is refused (an honest snapshot is under 10).
nc.DEPTH = 24

-- ---------- the vocabulary: what the engine writes ----------

local function set(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

local SIDE = set { "A", "B" }
local MODES = set { "Vs Computer", "Pass and Play", "Computer vs Computer" }
local HOWS = set { "king", "resigned", "king toppled by a thrown kubb", "king toppled early" }
local PHASES = set { "toss", "rethrow", "raise", "punish", "batons", "over" }
local WHERE = set { "pitch", "hand", "out", "punish" }
-- the surfaces and the sets: every one core/scenes lists (sweden and wisconsin are in no
-- scene, but a match from before 0.14 may carry them)
local SURFACE_KEYS, SURFACES = set(tw.scenes.SURFACES), {}
for _, k in ipairs(tw.scenes.SURFACES) do SURFACES[tw.scenes.surfaceName[k]] = true end
local OPENINGS = set { "2-4-6", "six" }
local SETS = set(tw.scenes.SETS)

local function isKubb(v) return v:match("^[ab]%d%d?$") ~= nil end
local function isPiece(v)
	return isKubb(v) or v == "king" or v:match("^baton%d%d?$") ~= nil or v:match("^stake%d%d?$") ~= nil
end

-- A baton token (core/rules, notation.hitToken): a few capitals, digits and signs only.
local TOKENS = set { "-", "=", "Z", "K", "G", "X" }
local function isToken(v)
	if TOKENS[v] then return true end
	return v ~= "" and #v <= 8 and v:match("^%d*F?%d*B?E?$") ~= nil
end

-- The sheet's notes (core/rules: sheet:note), whole.
local NOTES = set {
	"king toppled by a thrown kubb",
	"a kubb hit a field kubb in the thrower's own half (II.C.4b)",
	"resigned during the inkast",
	-- the Kid rules (0.15.0, core/rules rules.kid)
	"a kubb thrown in knocked the king down; stood back up (kid rules)",
	"a kubb out twice was stood at the fair spot, no punishment kubb (kid rules)",
}
local NOTE_PATTERNS = {
	"^b%d+ illegal throw toppled the king early$",
	"^b%d+ baton hit its own half and toppled the king early$",
	"^b%d+ toppled the king early$",
	"^b%d+ hit a field kubb in the thrower's own half; all put back %(II%.B%.11%)$",
	"^b%d+ toppled a base kubb early; raised %(II%.B%.4a%)$",
	"^b%d+ toppled %d+ base kubbs early; raised %(II%.B%.4a%)$",
	"^b%d+ pushed a kubb out without toppling; put back %(II%.B%.7%)$",
	"^b%d+ pushed %d+ kubbs out without toppling; put back %(II%.B%.7%)$",
	"^b%d+ knocked the king down early; stood back up %(kid rules%)$",
	"^b%d+ helicopter; counted %(kid rules%)$",
}
local function isNote(v)
	if NOTES[v] then return true end
	for _, p in ipairs(NOTE_PATTERNS) do if v:match(p) then return true end end
	return false
end

-- The ruling line (core/match: resolve, batonText, resign): parts joined by "; ", each the
-- engine's words, a team name only where the engine puts one.
local RULING = set {
	"missed the king", "own-half kubb hit: all put back", "helicopter: illegal", "missed",
	"base kubb early: raised", "pushed out: put back", "own half hit: kubb out", "kubb out for now",
	"kubb in for now", "own half hit", "kubb in", "all in", "kubb out: rethrown",
	"out twice: punishment kubb", "on a kubb: lowered", "rescue",
	-- the Kid rules (0.15.0)
	"king down: stood back up", "king down early: stood back up", "helicopter: counted",
	"out twice: stood at the fair spot",
}
local RULING_PATTERNS = { "^%d+ out: rethrown$", "^%d+ punishment kubbs$", "^%d+ rescues$",
	"^%d+ out twice: stood at the fair spot$" }
local function isDown(v)
	local inner = v:match("^(.+) down$")
	if not inner then return false end
	local f, b = inner:match("^(.-) and (.+)$")
	local function field(x) return x == "field kubb" or x:match("^%d+ field kubbs$") ~= nil end
	local function base(x) return x == "base kubb" or x:match("^%d+ base kubbs$") ~= nil end
	if f then return field(f) and base(b) end
	return field(inner) or base(inner)
end
local function isRuling(v, teams)
	-- (by side, not by name: two sides may share a name, as two unnamed players are both
	-- "Player 1", and then the engine writes "Player 1 resigned: Player 1 wins")
	for i, t in ipairs(teams) do
		for j, u in ipairs(teams) do
			if i ~= j and v == t .. " resigned: " .. u .. " wins" then return true end
		end
	end
	for part in (v .. "; "):gmatch("(.-); ") do
		local ok = RULING[part] or isDown(part)
		for _, p in ipairs(RULING_PATTERNS) do ok = ok or part:match(p) ~= nil end
		for _, t in ipairs(teams) do
			ok = ok or part == "king down: " .. t .. " wins" or part == "king down early: " .. t .. " wins"
				or part == "resigned: " .. t .. " wins"
		end
		if not ok then return false end
	end
	return true
end

-- ---------- a report ----------

local function report(what)
	return { what = what, allowed = true, names = {}, ids = {}, lines = {}, refused = {}, mismatches = {} }
end

local function textOf(v)
	if type(v) == "string" then return v end
	if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
	return NULL
end

-- A place fit to show. `from` is a path through what was sent, and a forged snapshot
-- chooses its own keys, so a path can carry submitted text ("Anything Typed"). `place` is
-- the same path with every component the engine does not itself name (VOCAB, built below
-- from the rules) replaced by "?": the only form an error or a client may show.
local VOCAB = {}
function nc.place(from)
	return (tostring(from):gsub("[^%.%[%]]+", function(w)
		if VOCAB[w] or w:match("^%d+$") then return w end
		return "?"
	end))
end

local function refuse(rep, from, text, kind, why)
	rep.refused[#rep.refused + 1] = { text = textOf(text), from = from, place = nc.place(from), kind = kind, why = why }
end

-- The names the engine itself gives when there is no name: the computer's side and its
-- player, a side with no name ("Team A"), a player with none ("Player n", n up to the
-- pitch's TEAM_MAX). Not generated, but made by the engine and never typed. Held here,
-- not in session/names (which imports this file), so the strict restore and replayLoad
-- work for a Lua caller that never loaded session/api.
local DEFAULTS = { "Computer", "Team A", "Team B" }
for i = 1, tw.shared.lobby.TEAM_MAX do DEFAULTS[#DEFAULTS + 1] = "Player " .. i end
local IS_DEFAULT = {}
for _, s in ipairs(DEFAULTS) do IS_DEFAULT[s] = true end
nc.DEFAULTS = DEFAULTS
function nc.isDefault(s) return type(s) == "string" and IS_DEFAULT[s] == true end

-- names.valid's answer: ok (a generated name of the kind), default (the engine's own).
local function judge(kind, text)
	if type(text) ~= "string" then return false, false end
	return namegen.parse(kind, text) ~= nil, nc.isDefault(text)
end
nc.judge = judge

-- A name at `from`. A team's name on a side of one player is that player's name (the
-- pitch's matchOptions, renameStart), so it passes as either: `as` says "player" then.
local function name(rep, from, text, kind, solo)
	local ok, def = judge(kind, text)
	local as = nil
	if kind == "team" and solo and not (ok or def) then
		local pok, pdef = judge("player", text)
		if pok or pdef then ok, def, as = pok, pdef, "player" end
	end
	rep.names[#rep.names + 1] = { text = textOf(text), from = from, kind = kind, as = as, ok = ok, default = def }
	if not (ok or def) then
		refuse(rep, from, text, kind, type(text) == "string" and "not a generated name" or "not text")
	end
end

local function line(rep, from, text, kind, ok)
	rep.lines[#rep.lines + 1] = { text = textOf(text), from = from, kind = kind, ok = ok }
	if not ok then refuse(rep, from, text, kind, "not the engine's words") end
end

local function mismatch(rep, from, other, a, b)
	rep.mismatches[#rep.mismatches + 1] = { from = from, place = nc.place(from), other = other,
		otherPlace = nc.place(other), text = textOf(a), otherText = textOf(b) }
end

-- ---------- the walk ----------

-- What may be at each place of a snapshot, by its path with list indices as [] and map
-- keys as {} (KEYS says what a map's keys are). A rule is a function(v, ctx, rep, from)
-- -> ok, why, or a table { name = kind, side = side, part = "opts" | "save" } for a name.
local RULES, KEYS = {}, {}

local function enum(s, why) return function(v) return s[v] == true, why end end
local function pid(v, ctx) return ctx.pids[v] == true, "not a player of this match" end
local function level(v) return plan.levels[v] ~= nil, "not a throw level" end
local function key(v) return #v <= 64, "a key longer than 64" end
local function throwLevel(v) return plan.isThrowLevel(v), "not a person's throw level" end

for _, side in ipairs { "A", "B" } do
	RULES[".opts.teams." .. side .. ".name"] = { name = "team", side = side, part = "opts" }
	RULES[".opts.teams." .. side .. ".players[].name"] = { name = "player", side = side, part = "opts" }
	RULES[".opts.teams." .. side .. ".players[].key"] = key
	RULES[".opts.teams." .. side .. ".players[].level"] = level
	RULES[".opts.teams." .. side .. ".players[].throw"] = throwLevel
	RULES[".save.game.teams." .. side .. ".name"] = { name = "team", side = side, part = "save" }
	RULES[".save.game.teams." .. side .. ".players[].name"] = { name = "player", side = side, part = "save" }
	RULES[".save.game.teams." .. side .. ".players[].id"] = pid
	RULES[".save.lineup." .. side .. "[].id"] = pid
	RULES[".save.lineup." .. side .. "[].key"] = key
	RULES[".save.lineup." .. side .. "[].level"] = level
	RULES[".save.lineup." .. side .. "[].throw"] = throwLevel
	RULES[".save.order." .. side .. ".ids[]"] = pid
end
local kubb = function(v) return isKubb(v), "not a kubb" end
local piece = function(v) return isPiece(v), "not a piece" end
local side = enum(SIDE, "not a side")
for _, s in ipairs { "A", "B" } do RULES[".save.game.hand." .. s .. "[]"] = kubb end

RULES[".side"] = side
RULES[".lastThrower"] = pid
RULES[".resignPending"] = side
RULES[".mem.markerOnId"] = piece
RULES[".mem.markerSide"] = side
RULES[".mem.stanceSide"] = side
RULES[".mem.stanceKind"] = enum(set { "baton", "kubb" }, "not a projectile")
RULES[".opts.computer"] = level
RULES[".opts.rules"] = enum(set { "kid" }, "not a rule set")
RULES[".opts.cpu[]"] = side
RULES[".opts.first"] = side
RULES[".opts.opening"] = enum(OPENINGS, "not an opening")
RULES[".opts.raising"] = enum(set { "auto", "hand" }, "not a raising")
RULES[".opts.scene"] = function(v) return tw.scenes.known(v), "not a scene the engine lists" end
RULES[".opts.set"] = enum(SETS, "not a kubb set the engine lists")
RULES[".opts.surface"] = enum(SURFACE_KEYS, "not a surface")
RULES[".opts.wind"] = function(v) return wind.levels[v] ~= nil, "not a wind" end
RULES[".opts.mode"] = { line = "mode" }
RULES[".save.debris.kind"] = enum(set { "baton", "toss" }, "not a throw kind")
RULES[".save.debris.list[].id"] = piece
RULES[".save.debris.list[].kind"] = enum(set { "baton", "kubb" }, "not a piece kind")
RULES[".save.game.attacker"] = side
RULES[".save.game.defender"] = side
RULES[".save.game.first"] = side
RULES[".save.game.winner"] = side
RULES[".save.game.current"] = kubb
RULES[".save.game.firstQueue[]"] = kubb
RULES[".save.game.rethrowQueue[]"] = kubb
RULES[".save.game.punishQueue[]"] = kubb
RULES[".save.game.ids[]"] = kubb
RULES[".save.game.how"] = { line = "how" }
RULES[".save.game.king.id"] = enum(set { "king" }, "not the king")
RULES[".save.game.kubbs.{}.half"] = side
RULES[".save.game.kubbs.{}.id"] = kubb
RULES[".save.game.kubbs.{}.inkBy"] = pid
RULES[".save.game.kubbs.{}.kind"] = enum(set { "base", "field" }, "not a kubb kind")
RULES[".save.game.kubbs.{}.where"] = enum(WHERE, "not a place")
RULES[".save.game.lastTosser"] = pid
RULES[".save.game.opening"] = enum(OPENINGS, "not an opening")
RULES[".save.game.phase"] = enum(PHASES, "not a phase")
RULES[".save.game.rules"] = enum(set { "kid" }, "not a rule set")
RULES[".save.game.raisePolicy"] = function(v) return raising.policies[v] ~= nil, "not a raising policy" end
RULES[".save.game.surface"] = enum(SURFACES, "not a surface")
RULES[".save.game.sheet.turns[].batons[].player"] = pid
RULES[".save.game.sheet.turns[].batons[].token"] = function(v) return isToken(v), "not a baton token" end
RULES[".save.game.sheet.turns[].inkastOrder[]"] = pid
RULES[".save.game.sheet.turns[].notes[]"] = { line = "note" }
RULES[".save.game.sheet.turns[].side"] = side
RULES[".save.mode"] = { line = "mode" }
RULES[".save.order.deal[]"] = pid
RULES[".save.order.inkaster"] = pid
RULES[".save.order.side"] = side
RULES[".save.text"] = { line = "ruling" }
-- the throw to go (1.4.0): how first was decided (core/togo togo.text, kept as
-- game.firstBy), and a baton to go already in while the other is owed (Session:applyTogo
-- keeps only these strings of it)
RULES[".save.game.firstBy"] = { line = "togo" }
for _, s in ipairs { "A", "B" } do
	RULES[".togo." .. s .. ".type"] = enum(set { "togo" }, "not a baton to go")
	RULES[".togo." .. s .. ".side"] = side
	RULES[".togo." .. s .. ".how"] = enum(set { "baton" }, "not a baton's throw")
	RULES[".togo." .. s .. ".input"] = enum(set { "pointer", "touch" }, "not an input")
	RULES[".togo." .. s .. ".target.on"] = piece
end

KEYS[".save.game.kubbs"] = kubb
KEYS[".save.game.sheet.turns[].inkast"] = pid
KEYS[".save.game.sheet.turns[].inkastAt"] = pid

-- The words a place may be shown with (nc.place): every field the rules above name, and
-- the fixed ones of a replay and a pitch document.
for _, t in ipairs { RULES, KEYS } do
	for path in pairs(t) do
		for w in path:gmatch("[%a_][%w_]*") do VOCAB[w] = true end
	end
end
for _, w in ipairs { "opts", "save", "game", "teams", "players", "name", "id", "A", "B", "setup", "start", "snap",
	"log", "a", "teamNames", "match", "members", "me", "computers" } do VOCAB[w] = true end

-- togo.text's words: "throw to go: Team A 0.42 m, Team B king down" and, after rounds
-- thrown again, "; 2 rounds".
local function togoPart(p, side)
	if p == "Team " .. side .. " king down" then return true end
	return p:match("^Team " .. side .. " %d+%.%d%d m$") ~= nil
end
function nc.isTogoText(v)
	if type(v) ~= "string" or #v > 120 then return false end
	local body, rounds = v:match("^throw to go: (.-); (%d+) rounds$")
	if body then
		if tonumber(rounds) < 2 then return false end
	else
		body = v:match("^throw to go: (.*)$")
	end
	if not body then return false end
	local a, b = body:match("^(.-), (Team B .*)$")
	return a ~= nil and togoPart(a, "A") and togoPart(b, "B")
end

local function lineOk(kind, v, ctx)
	if kind == "mode" then return MODES[v] == true end
	if kind == "how" then return HOWS[v] == true end
	if kind == "note" then return isNote(v) end
	if kind == "togo" then return nc.isTogoText(v) end
	return isRuling(v, ctx.teams)
end

local function walk(rep, v, from, norm, ctx, depth)
	if depth > nc.DEPTH then
		refuse(rep, from, nil, "text", "nested too deep")
		return
	end
	local t = type(v)
	-- a place the engine writes a name or a sentence holds a text: a number, a boolean or
	-- a table there is refused before anything can skip it (a number as a team's name
	-- would otherwise pass, agree with its other copy, and reach need.teams and the sheet)
	local held = RULES[norm]
	if t ~= "string" and held ~= nil and not rawequal(v, NULL)
		and ((type(held) == "table" and (held.name or held.line)) or (type(held) == "function" and t ~= "table")) then
		-- (a place with a rule of its own, an id or a level, is a text too: a number there
		-- would be written into the sheet as it is)
		refuse(rep, from, v, "text", "not a text where the engine writes one")
		return
	end
	if t == "string" then
		local rule = RULES[norm]
		if type(rule) == "table" and rule.name then
			name(rep, from, v, rule.name, rule.name == "team" and ctx.solo[rule.part][rule.side])
		elseif type(rule) == "table" and rule.line then
			line(rep, from, v, rule.line, lineOk(rule.line, v, ctx))
		elseif rule then
			local ok, why = rule(v, ctx)
			if not ok then refuse(rep, from, v, "text", why) end
		else
			refuse(rep, from, v, "text", "a text the engine never writes here")
		end
		return
	end
	if t ~= "table" or rawequal(v, NULL) then return end
	local keyRule = KEYS[norm]
	-- a stable order, so the same snapshot gives the same report
	local ks = {}
	for k in pairs(v) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		if type(a) == type(b) then return a < b end
		return type(a) == "number"
	end)
	local dot = (from == "") and "" or "."
	for _, k in ipairs(ks) do
		local x = v[k]
		if type(k) == "number" then
			walk(rep, x, from .. "[" .. tostring(math.tointeger(k) and (k - 1) or k) .. "]", norm .. "[]", ctx, depth + 1)
		elseif keyRule then
			local ok, why = keyRule(k, ctx)
			if not ok then refuse(rep, from .. dot .. k, k, "text", why) end
			walk(rep, x, from .. dot .. k, norm .. ".{}", ctx, depth + 1)
		else
			walk(rep, x, from .. dot .. k, norm .. "." .. k, ctx, depth + 1)
		end
	end
end

local function list(v) return type(v) == "table" and not rawequal(v, NULL) and v or {} end

-- The ids the engine makes from a teams table's names (rules.new: notation.assignIds),
-- by side and place, and as a set. A name that is not text makes none.
local function derive(teams)
	local copy, byPlace, pids = { A = { players = {} }, B = { players = {} } }, { A = {}, B = {} }, {}
	for _, s in ipairs { "A", "B" } do
		for i, p in ipairs(list(list(list(teams)[s]).players)) do
			local n = type(p) == "table" and p.name or p
			copy[s].players[i] = { name = type(n) == "string" and n or "" }
		end
	end
	notation.assignIds(copy)
	for _, s in ipairs { "A", "B" } do
		for i, p in ipairs(copy[s].players) do byPlace[s][i] = p.id; pids[p.id] = true end
	end
	return byPlace, pids
end

local function sideCounts(teams)
	local out = {}
	for _, s in ipairs { "A", "B" } do out[s] = #list(list(list(teams)[s]).players) == 1 end
	return out
end

local function finish(rep)
	rep.allowed = #rep.refused == 0 and #rep.mismatches == 0
	return rep
end

-- The match options (a snapshot's opts, or a replay's setup made into them) and the
-- match's save, under `from`. Adds to rep; returns the match's player ids.
local function checkSnapshot(rep, d, from)
	local session = tw.web.session
	if type(d) == "string" then
		local ok, x = pcall(json.decode, d)
		d = ok and x or nil
	end
	if type(d) ~= "table" or d.v ~= session.snapshotVersion or type(d.opts) ~= "table"
		or type(d.save) ~= "table" or type(d.save.game) ~= "table" then
		refuse(rep, from, nil, "snapshot", "not a snapshot of this version")
		return {}
	end
	local opts, game = d.opts, d.save.game
	local gteams = list(game.teams)
	local byPlace = derive(gteams)
	-- the ids the save gives its players: what every other id in it must be one of (each
	-- held to the id its name makes below, so a forged name is refused once, not at
	-- every throw it made)
	local pids = {}
	for _, s in ipairs { "A", "B" } do
		for _, p in ipairs(list(list(gteams[s]).players)) do
			local id = list(p).id
			if type(id) == "string" then pids[id] = true end
		end
	end
	local ctx = {
		pids = pids,
		solo = { opts = sideCounts(opts.teams), save = sideCounts(gteams) },
		teams = {},
	}
	for _, s in ipairs { "A", "B" } do
		local n = list(gteams[s]).name
		if type(n) == "string" then ctx.teams[#ctx.teams + 1] = n end
	end
	walk(rep, d, from, "", ctx, 0)
	-- the ids against the names they come from, and the two copies of each name
	local prefix = (from == "" and "" or (from .. "."))
	for _, s in ipairs { "A", "B" } do
		local gt, ot = list(gteams[s]), list(list(opts.teams)[s])
		local gp, op = list(gt.players), list(ot.players)
		if gt.name ~= ot.name then
			mismatch(rep, prefix .. "save.game.teams." .. s .. ".name", prefix .. "opts.teams." .. s .. ".name", gt.name, ot.name)
		end
		if #gp ~= #op then
			mismatch(rep, prefix .. "save.game.teams." .. s .. ".players", prefix .. "opts.teams." .. s .. ".players",
				#gp .. " players", #op .. " players")
		end
		for i, p in ipairs(gp) do
			local at = prefix .. "save.game.teams." .. s .. ".players[" .. (i - 1) .. "]"
			local pn = list(p).name
			local o = list(op[i]).name
			if op[i] ~= nil and pn ~= o then
				mismatch(rep, at .. ".name", prefix .. "opts.teams." .. s .. ".players[" .. (i - 1) .. "].name", pn, o)
			end
			local id = list(p).id
			local ok = id == byPlace[s][i]
			rep.ids[#rep.ids + 1] = { text = textOf(id), from = at .. ".id", name = textOf(pn), ok = ok }
			if not ok then refuse(rep, at .. ".id", id, "id", "not the id the engine makes from the name") end
		end
	end
	-- the mode the sheet writes: the options' own, or the engine's for who plays
	local want = opts.mode
	if want == nil then want = session.modeOf(opts) end
	if d.save.mode ~= want then mismatch(rep, prefix .. "save.mode", prefix .. "opts.mode", d.save.mode, want) end
	return pids
end

-- A replay or a pitch's match header: { setup | start, log, snap?, players?, ... }.
local function checkReplay(rep, r, from)
	local prefix = (from == "" and "" or (from .. "."))
	if type(r) == "string" then
		local ok, x = pcall(json.decode, r)
		r = ok and x or nil
	end
	if type(r) ~= "table" or rawequal(r, NULL) then
		refuse(rep, from, nil, "replay", "not a replay")
		return
	end
	local pids = {}
	if type(r.setup) == "table" and not rawequal(r.setup, NULL) then
		-- the options the session makes from it (session.matchOptions, on a copy): names it
		-- leaves out become the engine's defaults, and those are what a replay shows
		local function copy(v)
			if type(v) ~= "table" then return v end
			local out = {}
			for k, x in pairs(v) do out[k] = copy(x) end
			return out
		end
		local ok, o = pcall(tw.web.session.matchOptions, copy(r.setup))
		if not ok then
			refuse(rep, prefix .. "setup", nil, "setup", "not a match's options")
		else
			local _, ps = derive(o.teams)
			pids = ps
			local ctx = { pids = ps, solo = { opts = sideCounts(o.teams) }, teams = {} }
			walk(rep, o, prefix .. "setup", ".opts", ctx, 0)
		end
	end
	if r.start ~= nil then pids = checkSnapshot(rep, r.start, prefix .. "start") end
	if r.setup == nil and r.start == nil and r.snap == nil then
		refuse(rep, from, nil, "replay", "neither a setup nor a start")
	end
	if r.snap ~= nil and not rawequal(r.snap, NULL) then
		local ps = checkSnapshot(rep, r.snap, prefix .. "snap")
		if next(pids) == nil then pids = ps end
	end
	-- the pitch's players at START ({ A = [{ id, name }], B = ... }): the names a lobby,
	-- a pitch card and a kept match's list show
	local players = r.players
	if type(players) == "table" and not rawequal(players, NULL) then
		for _, s in ipairs { "A", "B" } do
			for i, p in ipairs(list(players[s])) do
				name(rep, prefix .. "players." .. s .. "[" .. (i - 1) .. "].name", list(p).name, "player", false)
			end
		end
	end
	-- a thrower action names a player of the match by id
	for i, e in ipairs(list(r.log)) do
		local a = list(list(e).a)
		if a.type == "thrower" and not pids[a.id] then
			refuse(rep, prefix .. "log[" .. (i - 1) .. "].a.id", a.id, "id", "not a player of this match")
		end
	end
end

function nc.snapshot(d)
	local rep = report("snapshot")
	checkSnapshot(rep, d, "")
	return finish(rep)
end

function nc.replay(r)
	local rep = report("replay")
	checkReplay(rep, r, "")
	return finish(rep)
end

-- A pitch's document (docs/PITCH.md) and, when given, the pitch's members ([{ id, me }]):
-- the host's team names (the web's top-level teamNames), the match's header (its setup,
-- its snapshot, its players, its log) and each member's name (lobby.lineup makes the
-- match's names from them; "" there becomes "Player n").
function nc.document(doc, members)
	local rep = report("document")
	if type(doc) == "string" then
		local ok, x = pcall(json.decode, doc)
		doc = ok and x or nil
	end
	if type(doc) ~= "table" or rawequal(doc, NULL) then
		refuse(rep, "", nil, "document", "not a document")
		return finish(rep)
	end
	local teams = list(doc.teams)
	local tn = doc.teamNames
	if type(tn) == "table" and not rawequal(tn, NULL) then
		for _, s in ipairs { "A", "B" } do
			if tn[s] ~= nil and not rawequal(tn[s], NULL) then
				name(rep, "teamNames." .. s, tn[s], "team", #list(teams[s]) == 1)
			end
		end
	end
	-- the computer seats' names (0.17.0, pitch/lobby): player names, in team order
	local comps = doc.computers
	if type(comps) == "table" and not rawequal(comps, NULL) then
		for _, s in ipairs { "A", "B" } do
			for _, id in ipairs(list(teams[s])) do
				local r = type(id) == "string" and comps[id] or nil
				if type(r) == "table" and r.name ~= nil and not rawequal(r.name, NULL) then
					name(rep, "computers." .. id .. ".name", r.name, "player", false)
				end
			end
		end
	end
	local m = doc.match
	if type(m) == "table" and not rawequal(m, NULL) then checkReplay(rep, m, "match") end
	for i, mem in ipairs(list(members)) do
		local n = list(list(mem).me).name
		if n ~= nil and n ~= "" then name(rep, "members[" .. (i - 1) .. "].me.name", n, "player", false) end
	end
	return finish(rep)
end

-- The strict door's refusal: the places, never the text (an error may be shown).
function nc.why(rep)
	local at = {}
	for _, r in ipairs(rep.refused) do at[#at + 1] = nc.place(r.from) end
	for _, m in ipairs(rep.mismatches) do
		at[#at + 1] = nc.place(m.from) .. " (differs from " .. nc.place(m.other) .. ")"
	end
	local n = #at
	if n > 6 then
		for i = n, 7, -1 do at[i] = nil end
		at[#at + 1] = "and " .. (n - 6) .. " more"
	end
	return "names not allowed: " .. table.concat(at, ", ")
end

-- names = "check" on restore or replayLoad: nil (no check), or an error when it is not
-- "check"; then the check, refused with nc.why.
function nc.strict(names, what, rep)
	if names == nil or rawequal(names, NULL) then return end
	if names ~= "check" then error(what .. ": names is \"check\" or absent", 0) end
	rep = rep()
	if not rep.allowed then error(what .. ": " .. nc.why(rep), 0) end
end

tw.web.namecheck = nc
