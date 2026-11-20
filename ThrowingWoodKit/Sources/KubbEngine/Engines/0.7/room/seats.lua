-- Who acts in a shared match (docs/ROOM.md "Who acts"): the web's src/net/seats.js in
-- Lua. Pure.
--
-- ctx = {
--   players:   { A: [{ id, name }], B: [...] }   the match's players (doc.match.players)
--   cpu:       "A" | "B" | null                  the computer's side
--   host:      memberId                          the room's host now
--   connected: [memberId, ...]                   the members connected now (a Set in JS)
-- }
--
-- - A throw is for the member whose player the engine names (need.setup.thrower.key). If
--   they are not connected, the first connected member of that team in throwing order
--   takes it (it is still that player's throw on the sheet); failing that, the host.
-- - A raise or a punishment kubb is for any connected member of the defending team
--   (need.side), else the host. The room's compare-and-set settles two at once.
-- - The computer's throws are the host's client's (cpu: true), and only its.
import "core/tw"
import "session/json"
import "room/js"

local json, js = tw.web.json, tw.room.js
local object = json.object
local truthy, same, get, includes = js.truthy, js.same, js.get, js.includes

local seats = {}

local function isConnected(ctx, id)
	return truthy(id) and includes(get(ctx, "connected"), id)
end

function seats.teamIds(ctx, side)
	local list = get(get(ctx, "players"), side)
	if not truthy(list) then list = {} end
	local out = {}
	for i, p in ipairs(list) do out[i] = get(p, "id") end
	return out
end

local function hostOnly(ctx)
	local h = get(ctx, "host")
	return truthy(h) and { h } or {}
end

-- The members who may act for `need` now (a list; empty for nobody).
function seats.actorsFor(need, ctx)
	if not truthy(need) or same(get(need, "kind"), "over") or truthy(get(need, "practice")) then return {} end
	local side, kind = get(need, "side"), get(need, "kind")
	if same(kind, "throw") then
		if truthy(get(need, "cpu")) or same(side, get(ctx, "cpu")) then return hostOnly(ctx) end
		local owner = get(get(get(need, "setup"), "thrower"), "key")
		if isConnected(ctx, owner) then return { owner } end
		for _, id in ipairs(seats.teamIds(ctx, side)) do
			if isConnected(ctx, id) then return { id } end
		end
		return hostOnly(ctx)
	end
	if same(kind, "raise") or same(kind, "punish") then
		local mates = {}
		for _, id in ipairs(seats.teamIds(ctx, side)) do
			if isConnected(ctx, id) then mates[#mates + 1] = id end
		end
		if #mates > 0 then return mates end
		return hostOnly(ctx)
	end
	return {}
end

-- May member `me` act for `need`? Never for the computer's throw: the engine throws it
-- by itself in the client with control.cpu.
function seats.mayAct(need, ctx, me)
	if not truthy(need) or truthy(get(need, "cpu")) then return false end
	return includes(seats.actorsFor(need, ctx), me)
end

-- The member shown as the one acting (the first who may), or "cpu", or nil.
function seats.shownActor(need, ctx)
	if not truthy(need) then return nil end
	if same(get(need, "kind"), "throw") and (truthy(get(need, "cpu")) or same(get(need, "side"), get(ctx, "cpu"))) then
		return "cpu"
	end
	local first = seats.actorsFor(need, ctx)[1]
	return truthy(first) and first or nil
end

-- The engine's control for this client (setControl): the human sides it may ever act
-- for (its own team's, and every human side when it is the host, who stands in for
-- anyone), and the computer when it is the host. mayAct decides need by need.
function seats.controlFor(ctx, me)
	local sides = {}
	local host = get(ctx, "host")
	for _, s in ipairs { "A", "B" } do
		if not same(s, get(ctx, "cpu")) then
			if same(me, host) or includes(seats.teamIds(ctx, s), me) then sides[#sides + 1] = s end
		end
	end
	return object { sides = sides, cpu = same(me, host) }
end

function seats.sameControl(a, b)
	if not truthy(a) or not truthy(b) then return false end
	if not same(get(a, "cpu"), get(b, "cpu")) then return false end
	local sa, sb = get(a, "sides"), get(b, "sides")
	if not js.isTable(sa) or not js.isTable(sb) or #sa ~= #sb then return false end
	for i = 1, #sa do if not same(sa[i], sb[i]) then return false end end
	return true
end

-- The side member `me` plays for in this match, or nil (watching).
function seats.playingSide(ctx, me)
	for _, s in ipairs { "A", "B" } do
		if includes(seats.teamIds(ctx, s), me) then return s end
	end
	return nil
end

-- The next host when the host has gone: the room lets only the earliest-joined connected
-- member claim (the web's docs/ROOMS.md 2.4), so that is who tries. members: the room's
-- list in joined order. nil while the host is here.
function seats.nextHost(members, host)
	local h
	for _, m in ipairs(members or {}) do
		if same(get(m, "id"), host) then h = m; break end
	end
	if truthy(h) and truthy(get(h, "connected")) then return nil end
	for _, m in ipairs(members or {}) do
		if truthy(get(m, "connected")) and not same(get(m, "id"), host) then return get(m, "id") end
	end
	return nil
end

tw.room = tw.room or {}
tw.room.seats = seats
