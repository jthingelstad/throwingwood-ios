-- A shared pitch's document and its reducers (docs/ROOM.md): the web's src/net/lobby.js
-- in Lua, so every client (the web, the iPhone app) writes the room's document the same
-- way. Pure: no clock, no randomness (the host passes its seed and start time in).
--
-- Each reducer takes the room's current document (json.decode(text, true)) and returns
-- the whole new document, or nil to change nothing (the room client then writes nothing).
-- The functions keep the JavaScript names and decide exactly as the JavaScript does on the
-- same JSON, with these differences, each deliberate (docs/ROOM.md "Differences"):
--   * lobbyOf keeps top-level keys it does not know, so a newer client's fields survive
--     an older client's write (the JavaScript drops them);
--   * startMatch writes match.engine, this engine's major.minor, and refuses while a
--     player's engine (their `me.engine`) differs from the host's (startCheck);
--   * replayOf carries match.engine when the match has one;
--   * cleanName never leaves half a character: where the JavaScript's 16-unit cut
--     splits a character beyond U+FFFF, the whole character goes.
import "core/tw"
import "version"
import "session/json"
import "room/js"

local json, js = tw.web.json, tw.room.js
local NULL, object = json.null, json.object
local truthy, same, get, includes = js.truthy, js.same, js.get, js.includes

local lobby = {}

lobby.DOC_VERSION = 1
lobby.TEAM_MAX = 6
-- An open game's places, as the home page's list shows them: both teams full.
lobby.SEATS = 2 * lobby.TEAM_MAX
lobby.SIDES = { "A", "B" }
lobby.NAME_MAX = 16
lobby.LEVELS = { "beginner", "club", "pro" }
-- The most the document may grow to while it carries a replay's log (the room's limit is
-- 256 KB): about 600 actions.
lobby.LOG_BUDGET = 248 * 1024
lobby.REPLAY_VERSION = 1

local OPTION_KEYS = { "surface", "opening", "raising", "wind", "set" }
lobby.OPTION_DEFAULTS = { surface = "grass", opening = "2-4-6", raising = "hand", wind = "off", set = "classic" }

-- The match options the host sets: { key, label, { { value, label }, ... } }, as on the
-- web's solo options card. (Each player's throw level is their own.)
lobby.MATCH_OPTIONS = {
	{ "surface", "Surface", { { "grass", "Grass" }, { "sand", "Sand" }, { "snow", "Snow" } } },
	{ "opening", "Opening", { { "2-4-6", "2-4-6" }, { "six", "Six batons" } } },
	{ "raising", "Raising", { { "hand", "By hand" }, { "auto", "Automatic" } } },
	{ "wind", "Wind", { { "off", "Off" }, { "light", "Light" }, { "strong", "Strong" } } },
	{ "set", "Kubbs", { { "classic", "Classic" }, { "usa", "USA" }, { "sweden", "Sweden" },
		{ "minnesota", "Minnesota" }, { "wisconsin", "Wisconsin" } } },
}

local OPTION_VALUES = {}
for _, row in ipairs(lobby.MATCH_OPTIONS) do
	local vs = {}
	for i, c in ipairs(row[3]) do vs[i] = c[1] end
	OPTION_VALUES[row[1]] = vs
end

-- ---------- the engine's version ----------

-- "major.minor" of a version string ("0.3.1", "0.3", "0.3.1+web"), or nil.
function lobby.majorMinor(v)
	if type(v) ~= "string" then return nil end
	local a, b = v:match("^(%d+)%.(%d+)")
	if not a then return nil end
	return (math.tointeger(tonumber(a)) or a) .. "." .. (math.tointeger(tonumber(b)) or b)
end

-- This engine's major.minor: what START writes as match.engine (docs/VERSIONING.md
-- "Playing together": peers share a match only when these are equal).
lobby.ENGINE = lobby.majorMinor(tw.engine.version)

-- May a member whose engine is `engine` (their me.engine) play `match` (its
-- match.engine)? Major.minor equal. When either is unknown (a web client from before
-- the engine was named, or a match such a client started) it may only when `lenient`.
-- Returns { ok, why = nil | "unknown" | "differs", engine, match }.
function lobby.mayPlay(engine, match, lenient)
	local mine = lobby.majorMinor(engine)
	local theirs = lobby.majorMinor(get(match, "engine"))
	local why = nil
	if engine == nil or rawequal(engine, NULL) or get(match, "engine") == nil or js.isNull(get(match, "engine")) then
		why = (not lenient) and "unknown" or nil
	elseif not mine or not theirs or mine ~= theirs then
		why = "differs"
	end
	return object { ok = why == nil, why = why or NULL, engine = mine or NULL, match = theirs or NULL }
end

-- The lobby-level rule for START: every player but the host (who runs this engine) must
-- name an engine (me.engine) whose major.minor is this engine's. A player without one
-- (an older web client) passes only when `lenient`. `players` is the lineup's, `members`
-- the room's [{ id, me }]. Returns { ok, engine, differ = [ids], unknown = [ids] }.
function lobby.startCheck(players, members, host, lenient)
	local byId = {}
	if js.isTable(members) then
		for _, m in ipairs(members) do
			local id = get(m, "id")
			if id ~= nil then byId[id] = m end
		end
	end
	local differ, unknown = {}, {}
	for _, s in ipairs(lobby.SIDES) do
		local list = get(players, s)
		if js.isTable(list) then
			for _, p in ipairs(list) do
				local id = get(p, "id")
				if not same(id, host) then
					local e = get(get(byId[id], "me"), "engine")
					if e == nil or js.isNull(e) then
						unknown[#unknown + 1] = id
					elseif lobby.majorMinor(e) ~= lobby.ENGINE then
						differ[#differ + 1] = id
					end
				end
			end
		end
	end
	return object { ok = #differ == 0 and (lenient and true or #unknown == 0), engine = lobby.ENGINE,
		differ = differ, unknown = unknown }
end

-- ---------- options and names ----------

-- Only known keys with known values; the rest take the defaults.
function lobby.cleanOptions(o)
	local out = object {}
	for _, k in ipairs(OPTION_KEYS) do
		local v = get(o, k)
		out[k] = includes(OPTION_VALUES[k], v) and v or lobby.OPTION_DEFAULTS[k]
	end
	return out
end

function lobby.optionLabel(key, value)
	for _, row in ipairs(lobby.MATCH_OPTIONS) do
		if same(row[1], key) then
			for _, c in ipairs(row[3]) do if same(c[1], value) then return c[2] end end
		end
	end
	if value == nil then return "undefined" end
	if js.isNull(value) then return "null" end
	if type(value) == "number" then return js.number(value) end
	if type(value) == "boolean" then return tostring(value) end
	if type(value) == "string" then return value end
	return js.text(value)
end

-- JavaScript's \s (and so String.prototype.trim's set).
local SPACE = { [0x09] = true, [0x0a] = true, [0x0b] = true, [0x0c] = true, [0x0d] = true, [0x20] = true,
	[0xa0] = true, [0x1680] = true, [0x2028] = true, [0x2029] = true, [0x202f] = true, [0x205f] = true,
	[0x3000] = true, [0xfeff] = true }
for cp = 0x2000, 0x200a do SPACE[cp] = true end

-- A member's name: runs of white space made one space, trimmed, at most NAME_MAX UTF-16
-- units (JavaScript's slice) without splitting a character. "" for anything but a string.
function lobby.cleanName(name)
	if type(name) ~= "string" then return "" end
	local cps = {}
	local inSpace = false
	for _, cp in utf8.codes(name, true) do
		if SPACE[cp] then
			if not inSpace then cps[#cps + 1] = 0x20 end
			inSpace = true
		else
			cps[#cps + 1] = cp
			inSpace = false
		end
	end
	local i, j = 1, #cps
	while i <= j and cps[i] == 0x20 do i = i + 1 end
	while j >= i and cps[j] == 0x20 do j = j - 1 end
	local out, units = {}, 0
	for k = i, j do
		local u = (cps[k] > 0xffff) and 2 or 1
		if units + u > lobby.NAME_MAX then break end
		units = units + u
		out[#out + 1] = utf8.char(cps[k])
	end
	return table.concat(out)
end

-- ---------- the document ----------

local KNOWN = { v = true, teams = true, options = true, open = true, started = true, n = true, match = true }

-- The document as it stands, or a fresh lobby (a room's document is null until someone
-- writes it; an expired room comes back empty too). Unlike the JavaScript, top-level keys
-- it does not know are kept as they are.
function lobby.lobbyOf(doc)
	local d = js.isTable(doc) and doc or {}
	local l = object {}
	if js.isObject(d) then
		for k, v in pairs(d) do
			if type(k) == "string" and not KNOWN[k] then l[k] = v end
		end
	end
	local teams = object { A = {}, B = {} }
	local dt = get(d, "teams")
	for _, s in ipairs(lobby.SIDES) do
		local t = get(dt, s)
		if js.isArray(t) then
			local keep = {}
			for _, x in ipairs(t) do if type(x) == "string" then keep[#keep + 1] = x end end
			teams[s] = keep
		end
	end
	l.v = lobby.DOC_VERSION
	l.teams = teams
	l.options = lobby.cleanOptions(get(d, "options"))
	l.open = get(d, "open") == true
	l.started = truthy(get(d, "started"))
	local n = get(d, "n")
	l.n = js.isInteger(n) and js.int(n) or 0
	local m = get(d, "match")
	l.match = (truthy(m) and js.isTable(m)) and m or NULL
	return l
end

-- Which side a member is on in the lobby, or nil (watching).
function lobby.sideOf(doc, id)
	local l = lobby.lobbyOf(doc)
	for _, s in ipairs(lobby.SIDES) do if includes(l.teams[s], id) then return s end end
	return nil
end

local function without(list, id)
	local out = {}
	for _, x in ipairs(list) do if not same(x, id) then out[#out + 1] = x end end
	return out
end

-- Put member `id` on `side` ("A" | "B"), or take them off both (json.null: sit out and
-- watch). Only between matches; a full side refuses. A missing side (nil) refuses, as
-- the JavaScript's undefined does.
function lobby.joinTeam(doc, id, side)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	if not js.isNull(side) and not includes(lobby.SIDES, side) then return nil end
	local on = truthy(side)
	if on and includes(l.teams[side], id) then return nil end
	if on and #l.teams[side] >= lobby.TEAM_MAX then return nil end
	local was = includes(l.teams.A, id) or includes(l.teams.B, id)
	if not on and not was then return nil end
	for _, s in ipairs(lobby.SIDES) do l.teams[s] = without(l.teams[s], id) end
	if on then l.teams[side][#l.teams[side] + 1] = id end
	return l
end

-- The host's match options (merged; unknown values ignored).
function lobby.setOptions(doc, options)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	local next, changed = object {}, false
	for _, k in ipairs(OPTION_KEYS) do
		local v = get(options, k)
		if truthy(options) and includes(OPTION_VALUES[k], v) then next[k] = v else next[k] = l.options[k] end
		if next[k] ~= l.options[k] then changed = true end
	end
	if truthy(doc) and not changed then return nil end
	l.options = next
	return l
end

-- The host's choice: open (anyone may join from the home page's list) or invite only.
-- Between matches or during one.
function lobby.setAccess(doc, open)
	local l = lobby.lobbyOf(doc)
	if truthy(doc) and l.open == truthy(open) then return nil end
	l.open = truthy(open)
	return l
end

-- What the host tells the room server about an open pitch, for the home page's list, or
-- nil while it is invite only. `members`: the room's members; `over`: the match on
-- screen has ended.
function lobby.openListing(doc, members, over)
	local l = lobby.lobbyOf(doc)
	if not l.open then return nil end
	local here = 0
	for _, m in ipairs(members or {}) do if get(m, "connected") ~= false then here = here + 1 end end
	return object {
		players = math.min(here, lobby.SEATS),
		seats = lobby.SEATS,
		state = (not l.started) and "waiting" or (truthy(over) and "over" or "playing"),
	}
end

-- Forget members who left the room for good (`present`: the ids still in it). Between
-- matches only; the match keeps its own players.
function lobby.pruneTeams(doc, present)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	local changed = false
	for _, s in ipairs(lobby.SIDES) do
		local t = {}
		for _, x in ipairs(l.teams[s]) do if includes(present, x) then t[#t + 1] = x end end
		if #t ~= #l.teams[s] then changed = true end
		l.teams[s] = t
	end
	return changed and l or nil
end

-- Who plays: the lobby's teams with each member's name, the computer on an empty side.
-- `members`: the room's [{ id, me }]; members no longer in the room are left out.
-- Returns { players, cpu } or nil when nobody is on a team.
function lobby.lineup(doc, members)
	local l = lobby.lobbyOf(doc)
	local byId = {}
	for _, m in ipairs(members or {}) do
		-- a Map keyed by id: the last member with an id wins
		local id = get(m, "id")
		if id ~= nil then byId[id] = m end
	end
	local players = object { A = {}, B = {} }
	for _, s in ipairs(lobby.SIDES) do
		for _, id in ipairs(l.teams[s]) do
			local m = byId[id]
			if m then
				local me = get(m, "me")
				local name = lobby.cleanName(get(me, "name"))
				if name == "" then name = "Player " .. (#players[s] + 1) end
				players[s][#players[s] + 1] = object { id = id, name = name, level = get(me, "level") }
			end
		end
	end
	if #players.A == 0 and #players.B == 0 then return nil end
	local cpu = (#players.A == 0) and "A" or ((#players.B == 0) and "B" or NULL)
	return object { players = players, cpu = cpu }
end

-- The engine's newMatch options for a lineup: teams with each player's key = the member
-- id, so a throw maps back to a member. `seed` and `start` are the host's (a random seed,
-- its local time): this module has no clock and no randomness.
function lobby.matchOptions(doc, lu, seed, start)
	local l = lobby.lobbyOf(doc)
	local players, cpu = get(lu, "players"), get(lu, "cpu")
	local function team(s)
		if same(s, cpu) then
			return object { name = "Computer", players = { object { name = "Computer" } } }
		end
		local ps = get(players, s)
		local list = {}
		for i, p in ipairs(ps) do
			local level = get(p, "level")
			list[i] = object { name = get(p, "name"), key = get(p, "id"),
				level = includes(lobby.LEVELS, level) and level or "club" }
		end
		return object { name = (#ps == 1) and get(ps[1], "name") or ("Team " .. s), players = list }
	end
	local o = object {
		seed = seed,
		start = start,
		teams = object { A = team("A"), B = team("B") },
		cpu = truthy(cpu) and cpu or {},
		first = "A",
	}
	for _, k in ipairs(OPTION_KEYS) do o[k] = l.options[k] end
	return o
end

-- START: the match begins with the host's first snapshot. `setup` (the newMatch options)
-- starts the replay's log. Writes match.engine (this engine's major.minor) and refuses
-- (nil) unless startCheck(players, members, host, lenient) passes.
function lobby.startMatch(doc, a)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	if not lobby.startCheck(a.players, a.members, a.host, a.lenient).ok then return nil end
	local n = l.n + 1
	l.started = true
	l.n = n
	local function strip(list)
		local out = {}
		for i, p in ipairs(list) do out[i] = object { id = get(p, "id"), name = get(p, "name") } end
		return out
	end
	local m = object {
		n = n,
		seq = 0,
		snap = a.snap,
		hash = a.hash,
		players = object { A = strip(get(a.players, "A")), B = strip(get(a.players, "B")) },
		cpu = truthy(a.cpu) and a.cpu or NULL,
		host = a.host,
		engine = lobby.ENGINE,
	}
	if truthy(a.setup) and js.isTable(a.setup) then
		m.setup, m.h0, m.log = a.setup, a.hash, {}
	end
	l.match = m
	return l
end

local function copy(t)
	local o = object {}
	for k, v in pairs(t) do o[k] = v end
	return o
end

-- An action committed: the snapshot after it, as action number `seq` of match `n`.
-- Refused (nil) unless it follows the document's own last action: the compare-and-set's
-- loser drops its action and adopts. `action` goes on the replay's log with the hash after
-- it; `over` when it ended the match. A log that cannot stay whole (no action, a gap, or
-- the document past LOG_BUDGET) is dropped: that match has no replay.
function lobby.commitAction(doc, a)
	local l = lobby.lobbyOf(doc)
	local m = l.match
	if not l.started or not truthy(m) or not same(get(m, "n"), a.n) or not same(get(m, "seq"), js.minus1(a.seq)) then
		return nil
	end
	local nm = copy(m)
	nm.seq, nm.snap, nm.hash = a.seq, a.snap, a.hash
	local log = get(m, "log")
	if js.isArray(log) then
		if truthy(a.action) and #log == js.minus1(a.seq) then
			local nl = {}
			for i, e in ipairs(log) do nl[i] = e end
			nl[#nl + 1] = object { a = a.action, h = a.hash }
			nm.log = nl
		else
			nm.log = NULL
		end
	end
	if truthy(a.over) then nm.over = true end
	l.match = nm
	if truthy(nm.log) and js.asciiSize(l) > lobby.LOG_BUDGET then nm.log = NULL end
	return l
end

-- A match's replay, when it has one: it has ended and its log is whole. { v, n, setup,
-- h0, log, snap, hash, players, cpu } (and engine, when the match names one), or nil.
function lobby.replayOf(match)
	local m = match
	if not js.isTable(m) or get(m, "over") ~= true then return nil end
	if not truthy(m.setup) or not js.isTable(m.setup) or type(m.snap) ~= "string" then return nil end
	if not js.isArray(m.log) or not same(#m.log, m.seq) then return nil end
	local h0, cpu = m.h0, m.cpu
	if h0 == nil then h0 = NULL end
	if cpu == nil then cpu = NULL end
	return object {
		v = lobby.REPLAY_VERSION, n = m.n, setup = m.setup, h0 = h0, log = m.log, snap = m.snap,
		hash = m.hash, players = m.players, cpu = cpu, engine = m.engine,
	}
end

-- The same check for a replay that came from elsewhere (the room's kept copy).
function lobby.isReplay(r)
	if not truthy(r) or not js.isTable(r) then return false end
	if not same(get(r, "v"), lobby.REPLAY_VERSION) then return false end
	local setup = get(r, "setup")
	if not ((truthy(setup) and js.isTable(setup)) or type(get(r, "start")) == "string") then return false end
	local log = get(r, "log")
	if not js.isArray(log) then return false end
	for _, e in ipairs(log) do
		if not truthy(e) then return false end
		local x = get(e, "a")
		if not (js.isTable(x) and truthy(x)) then return false end
	end
	return type(get(r, "snap")) == "string"
end

-- REMATCH: back to the lobby with the same teams (the old match is dropped from the
-- document; its replay was kept by the room when it ended).
function lobby.backToLobby(doc, n)
	local l = lobby.lobbyOf(doc)
	if not l.started or (n ~= nil and not js.isNull(n) and not same(l.n, n)) then return nil end
	l.started = false
	l.match = NULL
	return l
end

tw.room = tw.room or {}
tw.room.lobby = lobby
