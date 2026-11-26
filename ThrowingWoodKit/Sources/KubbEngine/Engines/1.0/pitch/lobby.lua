-- A shared pitch's document and its reducers (docs/PITCH.md). It began as the web's
-- src/net/lobby.js in Lua; since engine 0.3 that file is a thin wrapper over these calls,
-- so this is the one implementation and every client (the web, the iPhone app) writes the
-- pitch's document the same way. Pure: no clock, no randomness (the host passes its seed and start time in).
--
-- Each reducer takes the pitch's current document (json.decode(text, true)) and returns
-- the whole new document, or nil to change nothing (the pitch client then writes nothing).
-- The functions keep the JavaScript names and decide exactly as the JavaScript did on the
-- same JSON (tests/pitch/vectors/), with these differences, each deliberate (docs/PITCH.md "Differences"):
--   * lobbyOf keeps top-level keys it does not know, so a newer client's fields survive
--     an older client's write (the JavaScript drops them);
--   * startMatch writes match.engine, this engine's major.minor, and refuses while a
--     player's engine (their `me.engine`) differs from the host's (startCheck);
--   * replayOf carries match.engine when the match has one;
--   * cleanName never leaves half a character: where the JavaScript's 16-unit cut
--     splits a character beyond U+FFFF, the whole character goes.
--   * the engine's own options (computer, scene) live in a top-level `settings`, which an
--     older engine's lobbyOf keeps; setOptions sets them and optionsOf reads all options;
--   * a scene decides (since 0.14, core/scenes): in a document that names a scene,
--     setOptions, optionsOf and matchOptions hold the surface and the set to the scene's.
--     A document that names none (every one the JavaScript or an engine before 0.14
--     wrote) keeps its surface and set as written.
--   * computer seats (since 0.17): a team's list may hold a computer player's seat id
--     ("cpu:1"), its level and name in a top-level `computers`; the host adds, moves,
--     re-levels and removes them (addComputer, moveComputer, setComputerLevel,
--     removeComputer). A document without one (every one before 0.17) has no
--     `computers` and reads, cleans and writes exactly as before.
import "core/tw"
import "version"
import "session/json"
import "pitch/js"
import "core/scenes"
import "core/namegen"
import "core/throwplan"

local json, js, scenes, namegen = tw.web.json, tw.shared.js, tw.scenes, tw.namegen
local NULL, object = json.null, json.object
local truthy, same, get, includes = js.truthy, js.same, js.get, js.includes

local lobby = {}

lobby.DOC_VERSION = 1
lobby.TEAM_MAX = 6
-- An open game's places, as the home page's list shows them: both teams full.
lobby.SEATS = 2 * lobby.TEAM_MAX
lobby.SIDES = { "A", "B" }
lobby.NAME_MAX = 16
-- (kid since 0.15.0: the Kid computer, which makes the match a Kid match; docs/notes/kid-mode.md)
lobby.LEVELS = { "kid", "beginner", "club", "pro" }
-- The most the document may grow to while it carries a replay's log (the pitch's limit is
-- 256 KB): about 600 actions.
lobby.LOG_BUDGET = 248 * 1024
lobby.REPLAY_VERSION = 1

local OPTION_KEYS = { "surface", "opening", "raising", "wind", "set" }
lobby.OPTION_DEFAULTS = { surface = "grass", opening = "2-4-6", raising = "hand", wind = "off", set = "classic",
	computer = "club", scene = "day" }

-- The engine's own options (docs/PITCH.md "Differences"), which the JavaScript does not
-- know. They live in the document's top-level `settings` ({ computer?, scene? }), not
-- in `options`: an older engine's lobbyOf rebuilds `options` from the five keys it
-- knows but keeps a top-level key it does not know, so a 0.8 client's joinTeam or
-- setAccess leaves them as the host set them (docs/VERSIONING.md: the document grows by
-- new top-level keys only). Each is there only when a host set it to a value it takes,
-- and `settings` only when one is, so a document without them (every one an older
-- client wrote) reads, cleans and writes exactly as before; an absent one is its
-- default. Each key's test of a value:
local OWN_KEYS = { "computer", "scene" }

-- A scene (Jamie, 2026-11-20: scenes and effects are new settings; since 0.14 a scene
-- decides the surfaces and the kubb sets a match may have, core/scenes). The engine
-- lists the scenes (core/scenes, the Scene row of MATCH_OPTIONS); setOptions takes only
-- those. A document keeps any well formed id (lowercase letters, digits and hyphens, 1
-- to 24 characters), so one a newer engine wrote survives this one's writes, and reads
-- it as "day" (Park), the look a client draws for an id it does not know.
function lobby.isScene(v)
	return type(v) == "string" and #v >= 1 and #v <= 24 and v:match("^[a-z0-9%-]+$") ~= nil
end

-- kept in a document
local OWN_OK = {
	-- the computer's level, a game setting (Jamie, 2026-11-20: "yes this should be a real
	-- per game setting"); absent: club, as before
	computer = function(v) return includes(lobby.LEVELS, v) end,
	scene = lobby.isScene,
}
-- taken from setOptions
local OWN_SET = {
	computer = OWN_OK.computer,
	scene = scenes.known,
}

-- The match options the host sets: { key, label, { { value, label }, ... } }, as on the
-- web's solo options card. (Each player's throw level is their own; the computer's is the
-- match's, since 0.9.)
-- Every value each option takes; a client's card is lobby.optionRows(scene), which shows
-- only what the scene leaves to the player. The Scene row (since 0.14) is core/scenes'
-- list; the surface and set rows hold every value the engine takes (sweden and wisconsin
-- are in no scene but still load), so a document written before 0.14 reads as it did.
local sceneChoices, surfaceChoices = {}, {}
for i, e in ipairs(scenes.list) do sceneChoices[i] = { e.id, e.name } end
for i, k in ipairs(scenes.SURFACES) do surfaceChoices[i] = { k, scenes.surfaceName[k] } end
lobby.MATCH_OPTIONS = {
	{ "scene", "Scene", sceneChoices },
	{ "surface", "Surface", surfaceChoices },
	{ "opening", "Opening", { { "2-4-6", "2-4-6" }, { "six", "Six batons" } } },
	{ "raising", "Raising", { { "hand", "By hand" }, { "auto", "Automatic" } } },
	{ "wind", "Wind", { { "off", "Off" }, { "light", "Light" }, { "strong", "Strong" } } },
	{ "set", "Kubbs", { { "classic", "Classic" }, { "usa", "USA" }, { "sweden", "Sweden" },
		{ "minnesota", "Minnesota" }, { "wisconsin", "Wisconsin" } } },
	{ "computer", "Computer", { { "kid", "Kid" }, { "beginner", "Beginner" }, { "club", "Club" }, { "pro", "Pro" } } },
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
-- the pitch's [{ id, me }]. Returns { ok, engine, differ = [ids], unknown = [ids] }.
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
				-- a computer player has no engine of its own: the host's throws for it (a seat
				-- id counts as one even when an entry has lost its `cpu`, 1.0)
				if get(p, "cpu") == true or lobby.isSeat(id) then
				elseif not same(id, host) then
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
	local out = object { ok = #differ == 0 and (lenient and true or #unknown == 0), engine = lobby.ENGINE,
		differ = differ, unknown = unknown }
	-- the lineup itself (since 0.17), as the session would take it: refused with `why` and
	-- `text`, which a client can show; fields there only on such a refusal
	local why, text = lobby.lineupProblem(players)
	if why then out.ok, out.why, out.text = false, why, text end
	return out
end

-- What is wrong with a lineup's players ({ A: [...], B: [...] }) for START, or nil:
--   "size"    a team holds more than TEAM_MAX players, people and computers together
--   "level"   a computer player's level is not Beginner, Club or Pro
--   "person"  no person plays: a match needs at least one (a team of computers only is
--             fine, with people on the other team)
-- and the sentence to show.
function lobby.lineupProblem(players)
	local people = 0
	for _, s in ipairs(lobby.SIDES) do
		local list = get(players, s)
		if js.isTable(list) then
			if #list > lobby.TEAM_MAX then
				return "size", "Team " .. s .. " has more than " .. lobby.TEAM_MAX .. " players."
			end
			for _, p in ipairs(list) do
				if get(p, "cpu") == true then
					if not includes(lobby.SEAT_LEVELS, get(p, "level")) then
						return "level", "A computer player's level is Beginner, Club or Pro."
					end
				else
					people = people + 1
				end
			end
		end
	end
	if people == 0 then return "person", "A match needs at least one person." end
	return nil
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

-- The engine's own settings kept: an object of the valid ones, or nil when there are none.
local function cleanSettings(st)
	local out, any = object {}, false
	for _, k in ipairs(OWN_KEYS) do
		local v = get(st, k)
		if v ~= nil and OWN_OK[k](v) then out[k], any = v, true end
	end
	return any and out or nil
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

local KNOWN = { v = true, teams = true, options = true, open = true, started = true, n = true, match = true,
	settings = true, computers = true }

-- ---------- computer seats (since 0.17) ----------
--
-- A computer player sits in a team's list like a member, by a seat id no member can
-- have: "cpu:" and a number (the pitch server's member ids are letters, digits, "_" and
-- "-"). Its record is in the document's top-level `computers`, by seat id:
--   computers: { "cpu:1": { level: "pro", name: "Bold Birch" }, ... }
-- `level` is Beginner, Club or Pro (Kid is the match's: the Computer option, which makes
-- every computer of a Kid match the Kid computer); `name` a generated player name, absent
-- when none is kept (shown as "Computer"). A seat id in a team with no good record, or
-- a record no team holds, is dropped by lobbyOf, so a document never half-holds one.
lobby.SEAT_LEVELS = { "beginner", "club", "pro" }
lobby.SEAT_MAX = 99

function lobby.isSeat(id)
	if type(id) ~= "string" then return false end
	local k = id:match("^cpu:([1-9]%d?)$")
	return k ~= nil
end

local function cleanComputer(r)
	if not js.isObject(r) or not includes(lobby.SEAT_LEVELS, get(r, "level")) then return nil end
	local out = object { level = get(r, "level") }
	local name = get(r, "name")
	if type(name) == "string" and namegen.valid("player", name) then out.name = name end
	return out
end

-- The document as it stands, or a fresh lobby (a pitch's document is null until someone
-- writes it; an expired pitch comes back empty too). Unlike the JavaScript, top-level keys
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
	local dc = get(d, "computers")
	local computers, anySeat = object {}, false
	for _, s in ipairs(lobby.SIDES) do
		local t = get(dt, s)
		if js.isArray(t) then
			local keep = {}
			for _, x in ipairs(t) do
				if type(x) == "string" then
					if lobby.isSeat(x) then
						-- a computer seat: kept with its record, once, on one team
						local r = js.isObject(dc) and cleanComputer(get(dc, x)) or nil
						if r and computers[x] == nil then
							computers[x], anySeat = r, true
							keep[#keep + 1] = x
						end
					else
						keep[#keep + 1] = x
					end
				end
			end
			teams[s] = keep
		end
	end
	l.v = lobby.DOC_VERSION
	l.teams = teams
	l.computers = anySeat and computers or nil
	l.options = lobby.cleanOptions(get(d, "options"))
	l.settings = cleanSettings(get(d, "settings"))
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
	-- a computer seat moves by moveComputer, never as a member (since 0.17)
	if lobby.isSeat(id) then return nil end
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
	end
	-- the engine's own go to `settings`, in the same call
	local had = l.settings or {}
	local st = object {}
	for _, k in ipairs(OWN_KEYS) do
		local v = get(options, k)
		if truthy(options) and v ~= nil and OWN_SET[k](v) then st[k] = v else st[k] = had[k] end
		if st[k] ~= had[k] then changed = true end
	end
	-- a scene decides: the surface and the set held to the scene's (0.14)
	if st.scene ~= nil then
		local _, surface, set = scenes.resolve(st.scene, next.surface, next.set)
		next.surface, next.set = surface, set
	end
	for _, k in ipairs(OPTION_KEYS) do
		if next[k] ~= l.options[k] then changed = true end
	end
	if truthy(doc) and not changed then return nil end
	l.options = next
	l.settings = cleanSettings(st)
	return l
end

-- Every match option the pitch holds, defaults filled in: `options`' five and the
-- engine's own from `settings` (computer "club", scene "day" when absent). The one place
-- a client reads them all.
function lobby.optionsOf(doc)
	local l = lobby.lobbyOf(doc)
	local out = object {}
	for k, v in pairs(l.options) do out[k] = v end
	local st = l.settings or {}
	for _, k in ipairs(OWN_KEYS) do
		if st[k] ~= nil then out[k] = st[k] else out[k] = lobby.OPTION_DEFAULTS[k] end
	end
	-- a scene named decides (an id this engine does not list is Park's); none, as written
	if st.scene ~= nil then out.scene, out.surface, out.set = scenes.resolve(st.scene, out.surface, out.set) end
	return out
end

-- The options card for a scene (since 0.14): the rows a client shows, in MATCH_OPTIONS'
-- form, the Scene row first; a Surface row (or a Kubbs row) only where the scene allows
-- more than one, with only the values it allows. { scene, rows, defaults = { surface,
-- set } }: the scene as the engine reads it (an id it does not list is "day") and its
-- defaults, for a card that changes scene.
function lobby.optionRows(scene)
	local e = scenes.get(scene)
	local allowed = { surface = e.surfaces, set = e.sets }
	local rows = {}
	for _, row in ipairs(lobby.MATCH_OPTIONS) do
		local key, keep = row[1], true
		local only = allowed[key]
		if only then keep = #only > 1 end
		if keep then
			local choices = {}
			for _, c in ipairs(row[3]) do
				if not only or includes(only, c[1]) then choices[#choices + 1] = { c[1], c[2] } end
			end
			rows[#rows + 1] = { key, row[2], choices }
		end
	end
	return object { scene = e.id, rows = rows, defaults = object { surface = e.surface, set = e.set } }
end

-- The host's choice: open (anyone may join from the home page's list) or invite only.
-- Between matches or during one.
function lobby.setAccess(doc, open)
	local l = lobby.lobbyOf(doc)
	if truthy(doc) and l.open == truthy(open) then return nil end
	l.open = truthy(open)
	return l
end

-- What the host tells the pitch server about an open pitch, for the home page's list, or
-- nil while it is invite only. `members`: the pitch's members; `over`: the match on
-- screen has ended.
function lobby.openListing(doc, members, over)
	local l = lobby.lobbyOf(doc)
	if not l.open then return nil end
	local here = 0
	for _, m in ipairs(members or {}) do if get(m, "connected") ~= false then here = here + 1 end end
	-- (since 0.17) a computer seat is a place no one can take
	local seats = lobby.SEATS
	for _ in pairs(l.computers or {}) do seats = seats - 1 end
	return object {
		players = math.min(here, seats),
		seats = seats,
		state = (not l.started) and "waiting" or (truthy(over) and "over" or "playing"),
	}
end

-- Forget members who left the pitch for good (`present`: the ids still in it). Between
-- matches only; the match keeps its own players.
function lobby.pruneTeams(doc, present)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	local changed = false
	for _, s in ipairs(lobby.SIDES) do
		local t = {}
		for _, x in ipairs(l.teams[s]) do if lobby.isSeat(x) or includes(present, x) then t[#t + 1] = x end end
		if #t ~= #l.teams[s] then changed = true end
		l.teams[s] = t
	end
	return changed and l or nil
end

-- ---------- the host's computer seats (since 0.17) ----------
--
-- Each takes the document and returns the new one, or nil to change nothing: while a
-- match runs, for a seat the document does not hold, a side that is not "A" or "B", a
-- level that is not Beginner, Club or Pro, a full side (six players, people and
-- computers together), or when nothing would change. The host's client calls them, as
-- it calls setOptions.

local function seatCount(l)
	local n = 0
	for _ in pairs(l.computers or {}) do n = n + 1 end
	return n
end

-- A computer player on `side` at `level`, at the end of the team's throwing order (move
-- it with moveComputer). Its name: `name` when it is a generated player name, else one
-- rolled from `seed` (a whole number, the host's own random draw; core/namegen through
-- plan.rng, as names.roll), never one another computer seat holds. Its seat id is the
-- lowest "cpu:<n>" free.
function lobby.addComputer(doc, side, level, seed, name)
	local l = lobby.lobbyOf(doc)
	if l.started then return nil end
	if not includes(lobby.SIDES, side) or not includes(lobby.SEAT_LEVELS, level) then return nil end
	if #l.teams[side] >= lobby.TEAM_MAX then return nil end
	local held = {}
	for _, r in pairs(l.computers or {}) do if r.name then held[r.name] = true end end
	if not (type(name) == "string" and namegen.valid("player", name)) then
		if not (type(seed) == "number" and seed == math.floor(seed) and math.abs(seed) < 2 ^ 53) then return nil end
		local r = tw.plan.rng(seed)
		local function rand(n)
			local k = math.floor(r.next() * n) + 1
			if k > n then k = n end
			return k
		end
		name = nil
		for _ = 1, 50 do
			local text = namegen.roll("player", rand)
			if text and not held[text] then name = text break end
		end
		if not name then return nil end
	end
	local id
	for k = 1, lobby.SEAT_MAX do
		local c = "cpu:" .. k
		if not (l.computers and l.computers[c]) then id = c break end
	end
	if not id then return nil end
	l.computers = l.computers or object {}
	l.computers[id] = object { level = level, name = name }
	l.teams[side][#l.teams[side] + 1] = id
	return l
end

-- A computer seat's level.
function lobby.setComputerLevel(doc, id, level)
	local l = lobby.lobbyOf(doc)
	if l.started or not lobby.isSeat(id) or not (l.computers and l.computers[id]) then return nil end
	if not includes(lobby.SEAT_LEVELS, level) or l.computers[id].level == level then return nil end
	l.computers[id].level = level
	return l
end

-- A computer seat to `side` at place `index` in its throwing order (0 first; absent,
-- null or past the end: last). The same side reorders it.
function lobby.moveComputer(doc, id, side, index)
	local l = lobby.lobbyOf(doc)
	if l.started or not lobby.isSeat(id) or not (l.computers and l.computers[id]) then return nil end
	if not includes(lobby.SIDES, side) then return nil end
	local from, at
	for _, s in ipairs(lobby.SIDES) do
		for i, x in ipairs(l.teams[s]) do if x == id then from, at = s, i end end
	end
	if from ~= side and #l.teams[side] >= lobby.TEAM_MAX then return nil end
	table.remove(l.teams[from], at)
	local list = l.teams[side]
	local pos = #list + 1
	if js.isInteger(index) and js.int(index) >= 0 and js.int(index) < #list then pos = js.int(index) + 1 end
	table.insert(list, pos, id)
	if from == side and pos == at then return nil end
	return l
end

-- A computer seat taken off its team.
function lobby.removeComputer(doc, id)
	local l = lobby.lobbyOf(doc)
	if l.started or not lobby.isSeat(id) or not (l.computers and l.computers[id]) then return nil end
	for _, s in ipairs(lobby.SIDES) do l.teams[s] = without(l.teams[s], id) end
	l.computers[id] = nil
	if seatCount(l) == 0 then l.computers = nil end
	return l
end

-- Who plays: the lobby's teams with each member's name, the computer on an empty side.
-- `members`: the pitch's [{ id, me }]; members no longer in the pitch are left out.
-- Since 0.17 a team's computer seats are in it too, in their places, as { id, name,
-- level, cpu: true }; a side with only computers is not empty. Returns { players, cpu }
-- or nil when nobody is on a team.
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
			if lobby.isSeat(id) then
				-- a computer seat (since 0.17): its own name and level, cpu true
				local r = l.computers[id]
				players[s][#players[s] + 1] = object { id = id, name = r.name or "Computer", level = r.level, cpu = true }
			elseif m then
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
			-- a computer player (since 0.17): the session throws for it at its level
			if get(p, "cpu") == true then list[i].cpu = true end
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
	-- the engine's own: only when set, so a pitch without them starts the match it always did
	for _, k in ipairs(OWN_KEYS) do o[k] = l.settings and l.settings[k] or nil end
	-- a scene named decides (0.14): the match starts on the scene's surface and set
	if o.scene ~= nil then o.scene, o.surface, o.set = scenes.resolve(o.scene, o.surface, o.set) end
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
		for i, p in ipairs(list) do
			out[i] = object { id = get(p, "id"), name = get(p, "name") }
			-- a computer player keeps what says so (since 0.17), for who acts (pitch/seats)
			if get(p, "cpu") == true then out[i].cpu, out[i].level = true, get(p, "level") end
		end
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

-- js.asciiSize(l), the size the log budget is held to, for a document whose match
-- carries a log. Without `sizes` it is js.asciiSize(l) itself. With `sizes`, a table the
-- caller keeps for one document from commit to commit (session/replay.lua, which commits
-- a whole match in one pass), the log's entries are not encoded again on every action:
-- the document's text is the text with an empty log, "[]", with the entries put between
-- the brackets, a comma between each two. Every piece starts and ends on an ASCII
-- character, so asciiSize, counted character by character, is the sum of the pieces':
--   asciiSize(l) = asciiSize(l with log = []) + sum of asciiSize(entry) + (#log - 1)
-- An entry's size is kept the first time it is measured, keyed by the entry itself (the
-- same table, or the same value), so a log that is not the one measured before, past
-- the first entry that differs, is measured afresh. The entries are taken as unchanged
-- once committed, as they are in a replay.
function lobby.docSize(l, sizes)
	local m = get(l, "match")
	local log = get(m, "log")
	if not sizes or not js.isArray(log) then return js.asciiSize(l) end
	local entry, sum = sizes.entry, sizes.sum
	if not entry then
		entry, sum = {}, {}
		sizes.entry, sizes.sum, sizes.n = entry, sum, 0
	end
	local n, k = #log, 0
	local known = math.min(sizes.n, n)
	while k < known and rawequal(entry[k + 1], log[k + 1]) do k = k + 1 end
	for i = k + 1, n do
		entry[i] = log[i]
		sum[i] = (i > 1 and sum[i - 1] or 0) + js.asciiSize(log[i])
	end
	for i = n + 1, sizes.n do entry[i], sum[i] = nil, nil end
	sizes.n = n
	m.log = {}
	local ok, base = pcall(js.asciiSize, l)
	m.log = log
	if not ok then error(base, 0) end
	if n == 0 then return base end
	return base + sum[n] + (n - 1)
end

-- An action committed: the snapshot after it, as action number `seq` of match `n`.
-- Refused (nil) unless it follows the document's own last action: the compare-and-set's
-- loser drops its action and adopts. `action` goes on the replay's log with the hash after
-- it; `over` when it ended the match. A log that cannot stay whole (no action, a gap, or
-- the document past LOG_BUDGET) is dropped: that match has no replay. `sizes` (optional,
-- not part of the pitch's call): see docSize; the same size, so the same decision.
function lobby.commitAction(doc, a, sizes)
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
	if truthy(nm.log) and lobby.docSize(l, sizes) > lobby.LOG_BUDGET then nm.log = NULL end
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

-- The same check for a replay that came from elsewhere (the pitch's kept copy).
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
-- document; its replay was kept by the pitch when it ended).
function lobby.backToLobby(doc, n)
	local l = lobby.lobbyOf(doc)
	if not l.started or (n ~= nil and not js.isNull(n) and not same(l.n, n)) then return nil end
	l.started = false
	l.match = NULL
	return l
end

tw.shared = tw.shared or {}
tw.shared.lobby = lobby
