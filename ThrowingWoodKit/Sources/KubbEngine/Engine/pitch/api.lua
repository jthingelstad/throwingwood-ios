-- The pitch's calls behind the engine's one door (docs/PITCH.md "The calls"):
-- kubbCall("pitch.<name>", argsJson) -> '{"value": ...}'. "room.<name>" is the old
-- spelling (before 0.13) and reaches the same call. Every argument is a named field
-- of one JSON object; the result is always an object with one key, `value` (null where
-- the JavaScript returns undefined or null: a reducer's "change nothing"), so a document
-- that happens to hold a key named `error` is never mistaken for a failure. Arguments are
-- read with json.decode(text, true): nulls, empty objects and empty arrays come back as
-- they were sent, and the result is written by the engine's deterministic encoder.
-- Needs no session, tune or match: a client may call these before or without `new`.
import "core/tw"
import "version"
import "session/json"
import "pitch/js"
import "pitch/lobby"
import "pitch/seats"
import "pitch/sync"
import "pitch/engines"

local json, js, lobby, seats, sync = tw.web.json, tw.shared.js, tw.shared.lobby, tw.shared.seats, tw.shared.sync
local engines = tw.shared.engines
local object, NULL = json.object, json.null

local R = {}

-- Every constant a client needs, as the JavaScript exports them, and the engine's own.
function R.constants()
	local options = {}
	for i, row in ipairs(lobby.MATCH_OPTIONS) do
		local choices = {}
		for j, c in ipairs(row[3]) do choices[j] = { c[1], c[2] } end
		options[i] = { row[1], row[2], choices }
	end
	local defaults = object {}
	for k, v in pairs(lobby.OPTION_DEFAULTS) do defaults[k] = v end
	return object {
		DOC_VERSION = lobby.DOC_VERSION, TEAM_MAX = lobby.TEAM_MAX, SEATS = lobby.SEATS,
		SIDES = { "A", "B" }, NAME_MAX = lobby.NAME_MAX, OPTION_DEFAULTS = defaults,
		MATCH_OPTIONS = options, LEVELS = { table.unpack(lobby.LEVELS) }, LOG_BUDGET = lobby.LOG_BUDGET,
		REPLAY_VERSION = lobby.REPLAY_VERSION, CLIENT = sync.CLIENT, WITH_BYTES = sync.WITH_BYTES,
		ENGINE = lobby.ENGINE,
	}
end

-- lobby.js
function R.cleanOptions(a) return lobby.cleanOptions(a.options) end
function R.optionsOf(a) return lobby.optionsOf(a.doc) end
function R.optionLabel(a) return lobby.optionLabel(a.key, a.value) end
function R.optionRows(a) return lobby.optionRows(a.scene) end
function R.cleanName(a) return lobby.cleanName(a.name) end
function R.lobbyOf(a) return lobby.lobbyOf(a.doc) end
function R.sideOf(a) return lobby.sideOf(a.doc, a.id) end
function R.joinTeam(a) return lobby.joinTeam(a.doc, a.id, a.side) end
function R.setOptions(a) return lobby.setOptions(a.doc, a.options) end
function R.setAccess(a) return lobby.setAccess(a.doc, a.open) end
function R.openListing(a) return lobby.openListing(a.doc, a.members, a.over) end
function R.pruneTeams(a) return lobby.pruneTeams(a.doc, a.present) end
function R.lineup(a) return lobby.lineup(a.doc, a.members) end
function R.matchOptions(a) return lobby.matchOptions(a.doc, a.lineup, a.seed, a.start) end
function R.startCheck(a) return lobby.startCheck(a.players, a.members, a.host, js.truthy(a.lenient)) end
function R.startMatch(a)
	return lobby.startMatch(a.doc, { snap = a.snap, hash = a.hash, players = a.players, cpu = a.cpu, host = a.host,
		setup = a.setup, members = a.members, lenient = js.truthy(a.lenient) })
end
function R.commitAction(a)
	return lobby.commitAction(a.doc, { n = a.n, seq = a.seq, snap = a.snap, hash = a.hash, action = a.action,
		over = a.over })
end
function R.replayOf(a) return lobby.replayOf(a.match) end
function R.isReplay(a) return lobby.isReplay(a.replay) end
function R.backToLobby(a) return lobby.backToLobby(a.doc, a.n) end
function R.mayPlay(a) return lobby.mayPlay(a.engine, a.match, js.truthy(a.lenient)) end
-- several engines in one pitch (pitch/engines.lua, since 0.8.1)
function R.engineFor(a) return engines.engineFor(a.doc, a.members, a.host, a.me, a.carries) end
function R.carried(a) return engines.carried(a.me) end
function R.announce(a) return engines.announce(a.carries, a.engine) end
function R.speakAs(a) return engines.speakAs(a.members, a.engine) end
function R.compareEngines(a) return engines.compare(lobby.majorMinor(a.a), lobby.majorMinor(a.b)) end
-- seats.js
function R.teamIds(a) return seats.teamIds(a.ctx, a.side) end
function R.actorsFor(a) return seats.actorsFor(a.need, a.ctx) end
function R.mayAct(a) return seats.mayAct(a.need, a.ctx, a.me) end
function R.shownActor(a) return seats.shownActor(a.need, a.ctx) end
function R.controlFor(a) return seats.controlFor(a.ctx, a.me) end
function R.sameControl(a) return seats.sameControl(a.a, a.b) end
function R.playingSide(a) return seats.playingSide(a.ctx, a.me) end
function R.nextHost(a) return seats.nextHost(a.members, a.host) end
-- sync.js
function R.decide(a) return sync.decide(a["local"], a.doc, a.with, a.mine) end
function R.rider(a) return sync.rider(a.n, a.seq, a.action, a.bytes, a.client, a.engine) end
function R.asciiSize(a) return js.asciiSize(a.value) end

local pitch = {}
pitch.calls = R

-- One call: its name (without the prefix), its argument text and the prefix it was made
-- with ("pitch", or "room", the old spelling; errors name the call as it was made).
-- Returns the result text.
function pitch.call(name, argText, prefix)
	local said = (prefix or "pitch") .. "." .. tostring(name)
	local f = R[name]
	if not f then error("unknown call " .. said, 0) end
	local a = (argText and argText ~= "") and json.decode(argText, true) or object {}
	if not json.isObject(a) then
		if json.isArray(a) and next(a) == nil then a = object {} else error(said .. ": the argument is not an object", 0) end
	end
	local v = f(a)
	if v == nil then v = NULL end
	return json.encode(object { value = v })
end

tw.shared = tw.shared or {}
tw.shared.api = pitch
