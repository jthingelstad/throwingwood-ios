-- Several engines in one pitch (docs/PITCH.md "Engines in one match"): which engine a
-- pitch's next match runs on, worked out from what each member carries, and what a
-- client that carries several engines announces so that clients carrying one (every
-- release before 0.8.1) still agree with it.
--
-- A member's presence (`me`) names its engine in `engine`, as every client since 0.3
-- does. A client that carries several also sends `engines`, every major.minor it
-- carries, and writes its `engine` as the pitch's engine followed by MARK ("0.7+engines").
-- The pitch server merges `me` field by field, so an older client rejoining under the
-- same member id overwrites `engine` but leaves a stale `engines` behind: `engines` is
-- believed only while `engine` carries MARK. An older client reads `engine` through
-- majorMinor, which ignores what follows the minor, so it sees "0.7".
--
-- Pure: nothing here changes what startCheck, startMatch or mayPlay decide.
import "core/tw"
import "session/json"
import "pitch/js"
import "pitch/lobby"

local json, js, lobby = tw.web.json, tw.shared.js, tw.shared.lobby
local NULL, object = json.null, json.object
local get, same = js.get, js.same

local E = {}

-- What follows the major.minor in the `engine` of a client that announces `engines`.
E.MARK = "+engines"
-- The most engines one member is believed to carry.
E.MAX = 16

-- The two numbers of a major.minor, or nil.
local function parts(mm)
	if type(mm) ~= "string" then return nil end
	local a, b = mm:match("^(%d+)%.(%d+)$")
	if not a then return nil end
	return tonumber(a), tonumber(b)
end

-- Which of two major.minors is newer: -1 when a is older, 0 when equal, 1 when newer;
-- nil when either is not a major.minor.
function E.compare(a, b)
	local a1, a2 = parts(a)
	local b1, b2 = parts(b)
	if not a1 or not b1 then return nil end
	if a1 ~= b1 then return a1 < b1 and -1 or 1 end
	if a2 ~= b2 then return a2 < b2 and -1 or 1 end
	return 0
end

-- A list of versions as major.minors, each once, newest first, at most MAX (one
-- member's list; `whole` keeps every entry, for the engines of everyone in a pitch).
-- Anything that is not a version is left out; a non-list is an empty list.
function E.list(v, whole)
	local out, seen = {}, {}
	if not json.isArray(v) then return out end
	for _, x in ipairs(v) do
		local mm = lobby.majorMinor(x)
		if mm and not seen[mm] then
			seen[mm] = true
			out[#out + 1] = mm
		end
	end
	table.sort(out, function(a, b) return E.compare(a, b) > 0 end)
	if not whole then
		while #out > E.MAX do out[#out] = nil end
	end
	return out
end

local function marked(engine)
	return type(engine) == "string" and #engine > #E.MARK and engine:sub(-#E.MARK) == E.MARK
end

-- The engines a member's presence (`me`) says it carries, newest first: its `engines`
-- when its `engine` carries MARK and is among them, else its lone `engine`, else none.
function E.carried(me)
	local engine = get(me, "engine")
	local one = lobby.majorMinor(engine)
	if marked(engine) then
		local list = E.list(get(me, "engines"))
		for _, mm in ipairs(list) do
			if mm == one then return list end
		end
	end
	return one and { one } or {}
end

-- The presence fields a client that carries `carries` sends while the pitch's engine is
-- `engine`: { engine = "<engine>+engines", engines = [...] }. Without an `engine`, or
-- with one it does not carry, its newest. Nil when it carries nothing.
function E.announce(carries, engine)
	local list = E.list(carries)
	if #list == 0 then return nil end
	local mm = lobby.majorMinor(engine)
	local pick = list[1]
	for _, x in ipairs(list) do
		if x == mm then pick = x end
	end
	return object { engine = pick .. E.MARK, engines = list }
end

-- The engine the pitch's next match runs on: the newest major.minor that the host and
-- every player in the lineup (lobby.lineup: the teams' members still in the pitch) carry,
-- and `me` too when given (a member asking what to announce before it takes a seat).
-- `carries`, when given, is what `me` carries (its own presence may not have come back
-- from the pitch yet). Watchers do not count: START checks only players. Computer seats
-- (`cpu:<n>`, 0.17) do not count either: a seat is played by the host's client, so it
-- carries whatever engine the pitch runs on (until 1.0 each seat was a player who carried
-- none, so a pitch with a seat never found an engine).
--
-- Returns { engine, missing = [ids], unknown = [ids] }. `engine` is null when no engine
-- is carried by all; then `missing` names those who do not carry the engine the most of
-- them share (the host's first, then the newest), and `unknown` those who name no engine
-- at all (an older client, or the host not in `members`).
function E.engineFor(doc, members, host, me, carries)
	local byId = {}
	if js.isTable(members) then
		for _, m in ipairs(members) do
			local id = get(m, "id")
			if id ~= nil then byId[id] = m end
		end
	end
	local ids = {}
	local function add(id)
		if id == nil or js.isNull(id) then return end
		for _, x in ipairs(ids) do
			if same(x, id) then return end
		end
		ids[#ids + 1] = id
	end
	add(host)
	local lu = lobby.lineup(doc, js.isTable(members) and members or {})
	if lu then
		for _, s in ipairs(lobby.SIDES) do
			for _, p in ipairs(lu.players[s]) do
				-- a computer seat (0.17) carries whatever engine the pitch runs on: the host's
				-- client throws for it, so it is never a player with no engine (1.0)
				if get(p, "cpu") ~= true and not lobby.isSeat(get(p, "id")) then add(get(p, "id")) end
			end
		end
	end
	if not lobby.isSeat(me) then add(me) end

	local lists = {}
	for i, id in ipairs(ids) do
		if me ~= nil and same(id, me) and carries ~= nil then
			lists[i] = E.list(carries)
		else
			lists[i] = E.carried(get(byId[id], "me"))
		end
	end
	local function carry(list, mm)
		for _, x in ipairs(list) do
			if x == mm then return true end
		end
		return false
	end

	-- Every engine anyone here carries, newest first.
	local all = {}
	for _, list in ipairs(lists) do
		for _, mm in ipairs(list) do all[#all + 1] = mm end
	end
	all = E.list(all, true) -- MAX is each member's limit, not the pitch's

	local hasHost = host ~= nil and not js.isNull(host)
	local hostList = hasHost and lists[1] or {}
	local best, bestCount, bestHost = nil, -1, false
	for _, mm in ipairs(all) do
		local count = 0
		for _, list in ipairs(lists) do
			if carry(list, mm) then count = count + 1 end
		end
		if count == #ids then
			return object { engine = mm, missing = {}, unknown = {} }
		end
		local h = carry(hostList, mm)
		if count > bestCount or (count == bestCount and h and not bestHost) then
			best, bestCount, bestHost = mm, count, h
		end
	end
	local missing, unknown = {}, {}
	for i, id in ipairs(ids) do
		if #lists[i] == 0 then unknown[#unknown + 1] = id end
		if not (best and carry(lists[i], best)) then missing[#missing + 1] = id end
	end
	return object { engine = NULL, missing = missing, unknown = unknown }
end

-- The members as a host that runs START on `engine` passes them to that engine's
-- startMatch: each member that carries `engine` (E.carried) with its `me.engine` set to
-- it, the rest as they were. A member whose new announcement has not reached the pitch
-- yet is then not refused for it. Nothing else changes; the list keeps its order.
function E.speakAs(members, engine)
	local mm = lobby.majorMinor(engine)
	local out = {}
	if not js.isTable(members) then return out end
	for i, m in ipairs(members) do
		local me = get(m, "me")
		local carries = false
		for _, x in ipairs(E.carried(me)) do
			if x == mm then carries = true end
		end
		if carries and json.isObject(m) then
			local m2 = object {}
			for k, v in pairs(m) do m2[k] = v end
			local me2 = object {}
			for k, v in pairs(me) do me2[k] = v end
			me2.engine = mm
			m2.me = me2
			out[i] = m2
		else
			out[i] = m
		end
	end
	return out
end

tw.shared = tw.shared or {}
tw.shared.engines = E
