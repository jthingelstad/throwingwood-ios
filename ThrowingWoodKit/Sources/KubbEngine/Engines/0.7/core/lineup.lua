-- The two teams before a match (docs/PLAYERS.md section 4): which saved
-- players and guests are on each side, in throwing order, and the team
-- names. Pure Lua: no playdate.*; scenes/teams is the screen.
--
--   local L = lineup.new(vs)                -- vs: Team B is the Playdate
--   lineup.add(L, "A", lineup.entry(rec))   -- a saved player (core/roster record)
--   lineup.add(L, "B", lineup.guest("Ray", "club"))
--   lineup.ready(L), lineup.teams(L)        -- core/match's teams
--
-- An entry is { key, name, level, guest }: key is the roster key (nil for a
-- guest, who is not saved). A side holds lineup.tune.size (6); a player is on
-- one side at most. Against the Playdate (vs) Team B is the Playdate's own
-- team and takes nobody.
import "core/tw"
import "core/names"
import "core/notation"
import "core/roster"

local cnames, notation, roster = tw.names, tw.notation, tw.roster

local lineup = {}

lineup.tune = {
	size = 6,           -- players a side at most
}

lineup.PLAYDATE = "Playdate"   -- the computer's team and player name (VS PLAYDATE)

function lineup.new(vs)
	return { vs = vs and true or false, A = {}, B = {}, names = {} }
end

function lineup.entry(rec)
	return { key = rec.key, name = rec.name, level = rec.level }
end

function lineup.guest(name, level)
	return { key = nil, name = name, level = roster.isLevel(level) and level or roster.defaultLevel(), guest = true }
end

-- Which side an entry with this key (or, for a guest, this name's id) is
-- on, and where; nil when on neither.
function lineup.find(L, e)
	for _, side in ipairs { "A", "B" } do
		for i, x in ipairs(L[side]) do
			if (e.key and x.key == e.key) or (not e.key and not x.key and notation.baseId(x.name) == notation.baseId(e.name)) then
				return side, i
			end
		end
	end
	return nil
end

-- Put entry e at the end of `side`; returns ok, why ("full", "vs": Team B
-- is the Playdate, "taken": already on a team).
function lineup.add(L, side, e)
	if L.vs and side == "B" then return false, "vs" end
	if lineup.find(L, e) then return false, "taken" end
	if #L[side] >= lineup.tune.size then return false, "full" end
	L[side][#L[side] + 1] = e
	return true
end

-- A player just made on the teams screen (+ PLAYER or + GUEST) takes an
-- empty team's place at once, so a first match needs no trip through the
-- bench (the RC review of 2026-11-15): Team A when it is empty, else Team B
-- when it is empty and not the Playdate's. Returns the side, or nil when both
-- teams have players already (the player waits on the bench as before).
function lineup.seatNew(L, e)
	for _, side in ipairs { "A", "B" } do
		if #L[side] == 0 and not (L.vs and side == "B") then
			if lineup.add(L, side, e) then return side end
			return nil
		end
	end
	return nil
end

-- Take player i off `side` (back to the bench); returns the entry.
function lineup.remove(L, side, i)
	return table.remove(L[side], i)
end

-- Move player i of `side` one place up (dir -1) or down (+1) the order;
-- returns its new place.
function lineup.move(L, side, i, dir)
	local t = L[side]
	local j = i + dir
	if j < 1 or j > #t then return i end
	t[i], t[j] = t[j], t[i]
	return j
end

-- A team's name: the one given (L.names[side]), else the player's own
-- name for a team of one, else "Team <first player>"; "Playdate" for the
-- computer; "Team A" / "Team B" while empty.
function lineup.teamName(L, side)
	if L.vs and side == "B" then return lineup.PLAYDATE end
	if L.names[side] then return L.names[side] end
	local t = L[side]
	if #t == 1 then return t[1].name end
	if #t > 1 then return "Team " .. t[1].name end
	return "Team " .. side
end

-- Give a team a name (nil: back to the default). Returns the name kept.
function lineup.setName(L, side, name)
	L.names[side] = name and cnames.finish(name) or nil
	return L.names[side]
end

function lineup.ready(L)
	return #L.A > 0 and (L.vs or #L.B > 0)
end

-- core/match's teams: { A = { name, players = { { name, key, level, guest } } }, B }.
-- Against the Playdate, Team B is "Playdate" with one player, "Playdate".
function lineup.teams(L)
	local out = {}
	for _, side in ipairs { "A", "B" } do
		local ps = {}
		if L.vs and side == "B" then
			ps[1] = { name = lineup.PLAYDATE }
		else
			for i, e in ipairs(L[side]) do
				ps[i] = { name = e.name, key = e.key, level = e.level, guest = e.guest }
			end
		end
		out[side] = { name = lineup.teamName(L, side), players = ps }
	end
	return out
end

-- What the datastore keeps to offer the lineup again: the saved players'
-- keys in order and the names given (guests are not kept).
function lineup.pack(L)
	local d = { A = {}, B = {}, names = { A = L.names.A, B = L.names.B } }
	for _, side in ipairs { "A", "B" } do
		for _, e in ipairs(L[side]) do
			if e.key then d[side][#d[side] + 1] = e.key end
		end
	end
	return d
end

-- A kept lineup back against roster r (players removed since are left
-- out; anything unreadable gives an empty lineup).
function lineup.unpack(d, r, vs)
	local L = lineup.new(vs)
	if type(d) ~= "table" then return L end
	for _, side in ipairs { "A", "B" } do
		if type(d[side]) == "table" then
			for _, key in ipairs(d[side]) do
				local rec = roster.find(r, key)
				if rec then lineup.add(L, side, lineup.entry(rec)) end
			end
		end
		local n = type(d.names) == "table" and d.names[side]
		if type(n) == "string" and not (vs and side == "B") then lineup.setName(L, side, n) end
	end
	return L
end

tw.lineup = lineup
