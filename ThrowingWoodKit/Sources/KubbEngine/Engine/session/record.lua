-- Record mode behind the session's door (since 1.1.0; docs/RECORD.md): kubbCall("record.<name>",
-- argsJson) -> resultJson, for Kubb: Pitchside, which scores real games. The game itself is
-- core/record; this file holds one recorded game per Lua state (apart from any match the
-- session runs: record calls never touch it) and its event log.
--
--   record.options {}                          -> { format, surfaces, openings, winds, switches, events }
--   record.new     { game, want? }             -> result (a new game, an empty log)
--   record.add     { event, want? }            -> result + added = { index, warnings }
--   record.rebuild { events, game?, want? }    -> result (the log replaced, the game rebuilt)
--   record.undo    { want? }                   -> result (the last event dropped, rebuilt)
--   record.view    { want? }                   -> result
--   record.events  {}                          -> { events }
--   record.build   { game, events, want? }     -> result, touching nothing held
--
-- result = { state, warnings, notation? = { text, name }, sheet? = { rows } }; want =
-- { notation = true, sheet = true } asks for the file and the score sheet's rows. A setup
-- that cannot be a game is an error ({"error": "record: ..."}); an event never is: what
-- does not fit the rules or the game so far comes back as a warning.
import "core/tw"
import "core/record"
import "session/json"

local record, json = tw.record, tw.web.json
local NULL = json.null

local M = {}
local held = nil      -- { game = setup, events = { ... }, r = the built game }

-- JSON's null as Lua's nil, all the way down, so an event or a setup reads the same
-- whichever way a host leaves a field out.
local function plain(v)
	if rawequal(v, NULL) then return nil end
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = plain(x) end
	return out
end

-- An event as the log keeps it: a JSON null (or nothing) is kept as false, so the log
-- keeps its place, record.apply skips it with a warning as it did when added, and a
-- rebuild gives the same indexes.
local function event(v)
	if v == nil or rawequal(v, NULL) then return false end
	return plain(v)
end

-- The door decodes keeping nulls (door.call), so a null is json.null here; the list
-- still runs to its highest index, for a caller in Lua that leaves holes.
local function eventList(list)
	local out = {}
	if type(list) ~= "table" then return out end
	local n = 0
	for k in pairs(list) do
		if math.type(k) == "integer" and k > n then n = k end
	end
	for i = 1, n do out[i] = event(list[i]) end
	return out
end

local function result(r, want)
	local out = { state = record.state(r), warnings = r.warnings }
	want = want or {}
	if want.notation then
		local text, name = record.render(r)
		out.notation = { text = text, name = name }
	end
	if want.sheet then out.sheet = { rows = record.rows(r) } end
	return out
end

local function need()
	if not held then error("record: no game; call record.new first", 0) end
	return held
end

function M.options()
	return { format = record.FORMAT, surfaces = record.SURFACES, openings = record.OPENINGS,
		winds = record.WINDS, switches = record.SWITCHES, events = record.EVENTS }
end

function M.new(a)
	local game = plain(a and a.game)
	local r = record.new(game)
	held = { game = game, events = {}, r = r }
	return result(r, a and a.want)
end

function M.add(a)
	local h = need()
	local e = event(a and a.event)
	h.events[#h.events + 1] = e
	h.r.added = {}
	record.apply(h.r, e)
	local added = h.r.added
	h.r.added = nil
	local out = result(h.r, a and a.want)
	out.added = { index = #h.events - 1, warnings = added }
	return out
end

function M.rebuild(a)
	local game = a and a.game
	if game == nil then game = need().game end
	local events = eventList(a and a.events)
	local r = record.build(game, events)
	held = { game = game, events = events, r = r }
	return result(r, a and a.want)
end

function M.undo(a)
	local h = need()
	local events = {}
	for i = 1, #h.events - 1 do events[i] = h.events[i] end
	h.r = record.build(h.game, events)
	h.events = events
	return result(h.r, a and a.want)
end

function M.view(a) return result(need().r, a and a.want) end

function M.events() return { events = need().events } end

function M.build(a)
	return result(record.build(plain(a and a.game), eventList(a and a.events)), a and a.want)
end

local door = {}

function door.call(name, arg)
	local f = M[name]
	if not f then error("unknown call record." .. tostring(name), 0) end
	-- decoded keeping nulls, so a null in an event list keeps its place (the plain
	-- decode drops a trailing one); every argument but the list is then plain
	local a = nil
	if arg and arg ~= "" then
		local raw = json.decode(arg, true)
		if type(raw) == "table" and not rawequal(raw, NULL) then
			a = {}
			for k, v in pairs(raw) do a[k] = k == "events" and v or plain(v) end
		end
	end
	local r = f(a)
	if r == nil then r = json.object() end
	return json.encode(r)
end

tw.web.record = door
