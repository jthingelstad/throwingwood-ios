-- Saved players (docs/PLAYERS.md section 2): who plays on this Playdate,
-- each with a name, a throw level and all-time totals. Pure Lua: no
-- playdate.*; source/players.lua reads and writes it (datastore "players").
-- Each player's recent games, drill records and level changes are their own
-- file (core/history).
--
-- A roster is plain data (playdate.datastore writes JSON):
--   { v = 1, nextKey = n, players = { record, ... } }
-- and a record:
--   { key = "p7"      permanent, never reused (history and saves point at it)
--     name = "Kim"    as typed (core/names rules: letters, spaces, - and ')
--     id = "kim"      notation.baseId(name): the game file id, unique here
--     level = "club"  the throw level (tw.plan.LEVELS)
--     made, last      "YYYY-MM-DD": added, last played (match or drill)
--     totals = { games, wins, resigned, batons, hits, field, base, kings,
--                kingMisses, illegal, I, R, P, Q } }
--
-- Names are unique by id, not only by spelling ("Jo" and "jo-" are both
-- jo), so a player's id is the same in every game file and two saved
-- players never share one in a game.
import "core/tw"
import "core/names"
import "core/notation"
import "core/throwplan"

local cnames, notation, plan = tw.names, tw.notation, tw.plan

local roster = {}

roster.version = 1

roster.tune = {
	max = 40,          -- saved players at most (Jamie, 2026-11-15)
}

roster.TOTALS = { "games", "wins", "resigned", "batons", "hits", "field", "base", "kings", "kingMisses",
	"illegal", "I", "R", "P", "Q" }

local function blankTotals()
	local t = {}
	for _, k in ipairs(roster.TOTALS) do t[k] = 0 end
	return t
end
roster.blankTotals = blankTotals

function roster.new()
	return { v = roster.version, nextKey = 1, players = {} }
end

-- The default throw level, and whether `l` is one.
function roster.defaultLevel() return plan.tune.defaultLevel end
function roster.isLevel(l)
	for _, x in ipairs(plan.LEVELS) do
		if x == l then return true end
	end
	return false
end

local function isDate(s) return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end

-- A roster read back from the datastore, cleaned: a record without a name
-- that keeps a letter, a second record with a taken id or key, or records
-- past the cap are dropped; a bad level is the default, missing totals are
-- zero. Anything that is not a roster gives an empty one (never an error:
-- this runs at launch).
function roster.valid(d)
	local r = roster.new()
	if type(d) ~= "table" or type(d.players) ~= "table" then return r end
	local ids, keys, top = {}, {}, 0
	for _, p in ipairs(d.players) do
		if #r.players >= roster.tune.max then break end
		local name = type(p) == "table" and type(p.name) == "string" and cnames.finish(p.name) or nil
		local key = type(p) == "table" and p.key
		local n = type(key) == "string" and tonumber(key:match("^p(%d+)$")) or nil
		if name and n then
			local id = notation.baseId(name)
			if not ids[id] and not keys[key] then
				ids[id], keys[key] = true, true
				if n > top then top = n end
				local totals = blankTotals()
				if type(p.totals) == "table" then
					for _, k in ipairs(roster.TOTALS) do
						local v = p.totals[k]
						if type(v) == "number" and v >= 0 then totals[k] = math.floor(v) end
					end
				end
				r.players[#r.players + 1] = {
					key = key, name = name, id = id,
					level = roster.isLevel(p.level) and p.level or roster.defaultLevel(),
					made = isDate(p.made) and p.made or nil, last = isDate(p.last) and p.last or nil,
					totals = totals,
				}
			end
		end
	end
	local nk = type(d.nextKey) == "number" and math.floor(d.nextKey) or 1
	r.nextKey = nk > top and nk or top + 1
	return r
end

function roster.find(r, key)
	for i, p in ipairs(r.players) do
		if p.key == key then return p, i end
	end
	return nil
end

function roster.byId(r, id)
	for _, p in ipairs(r.players) do
		if p.id == id then return p end
	end
	return nil
end

-- Whether `name` (as typed) can be a player's name, the player with key
-- `except` aside (a rename). Returns the finished name, or nil and why:
-- "empty" (no letter), "taken" (another player has its id), "full".
function roster.canName(r, name, except)
	local n = cnames.finish(name or "")
	if not n then return nil, "empty" end
	local other = roster.byId(r, notation.baseId(n))
	if other and other.key ~= except then return nil, "taken" end
	if not except and #r.players >= roster.tune.max then return nil, "full" end
	return n
end

-- Add a player; returns the record, or nil and why (roster.canName).
function roster.add(r, name, level, today)
	local n, why = roster.canName(r, name)
	if not n then return nil, why end
	local p = { key = "p" .. r.nextKey, name = n, id = notation.baseId(n),
		level = roster.isLevel(level) and level or roster.defaultLevel(),
		made = today, last = nil, totals = blankTotals() }
	r.nextKey = r.nextKey + 1
	r.players[#r.players + 1] = p
	return p
end

-- Rename; returns ok, why.
function roster.rename(r, key, name)
	local p = roster.find(r, key)
	if not p then return false, "gone" end
	local n, why = roster.canName(r, name, key)
	if not n then return false, why end
	p.name, p.id = n, notation.baseId(n)
	return true
end

-- Set the level; returns the level it had (nil when nothing changed).
function roster.setLevel(r, key, level)
	local p = roster.find(r, key)
	if not p or not roster.isLevel(level) or p.level == level then return nil end
	local was = p.level
	p.level = level
	return was
end

function roster.remove(r, key)
	local _, i = roster.find(r, key)
	if not i then return false end
	table.remove(r.players, i)
	return true
end

-- The players most recently played first (never played last, newest made
-- first among them), then by name. A new list.
function roster.sorted(r)
	local out = {}
	for i, p in ipairs(r.players) do out[i] = p end
	table.sort(out, function(a, b)
		local la, lb = a.last or "", b.last or ""
		if la ~= lb then return la > lb end
		local ma, mb = a.made or "", b.made or ""
		if ma ~= mb then return ma > mb end
		return a.name < b.name
	end)
	return out
end

-- Hit rate in whole percent, or nil before any baton.
function roster.hitRate(p)
	local t = p.totals
	if not t or t.batons == 0 then return nil end
	return math.floor(100 * t.hits / t.batons + 0.5)
end

-- The first launch with saved players: the names typed for matches before
-- (datastore "names": { match = { A, B }, vs = { A } }) become players at
-- the default level, the defaults ("Team A", "Team B", "You") aside, unless
-- one with that id exists. Returns the players added, in order.
function roster.migrateNames(r, names, today)
	local added = {}
	if type(names) ~= "table" then return added end
	local skip = { [cnames.defaults.A] = true, [cnames.defaults.B] = true, [cnames.defaults.you] = true }
	for _, mode in ipairs { "match", "vs" } do
		local m = names[mode]
		if type(m) == "table" then
			for _, side in ipairs { "A", "B" } do
				local n = m[side]
				if type(n) == "string" and not skip[n] then
					local p = roster.add(r, n, nil, today)
					if p then added[#added + 1] = p end
				end
			end
		end
	end
	return added
end

tw.roster = roster
