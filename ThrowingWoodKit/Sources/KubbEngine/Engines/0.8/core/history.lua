-- A saved player's history (docs/PLAYERS.md section 2): totals on the
-- roster record (core/roster), and in the player's own file (datastore
-- "player-<key>", source/players.lua) the recent games, the drill records
-- and the level changes. Pure Lua: no playdate.*. Folded in once at the end
-- of a match or a drill run; never read back from game files.
--
-- A history file is plain data:
--   { v = 1,
--     games = { { d, f, team, side, res, vs, b, h, k, lv }, ... }   newest last,
--             d = "YYYY-MM-DD HH:MM", f = the game file name, team and vs =
--             the team names, res = "won" | "lost" | "resigned", b and h =
--             batons and hits, k = kubbs thrown in, lv = the level played at
--     drills = { [drill id] = core/drills record }
--     levels = { { d, from, to }, ... } }                           newest last
import "core/tw"
import "core/roster"
import "core/drills"

local roster, drills = tw.roster, tw.drills

local history = {}

history.version = 1

history.tune = {
	games = 20,     -- recent games kept per player
	levels = 10,    -- level changes kept
}

function history.new()
	return { v = history.version, games = {}, drills = {}, levels = {} }
end

-- A history file read back, cleaned (anything else: an empty history).
function history.valid(d)
	local h = history.new()
	if type(d) ~= "table" then return h end
	if type(d.games) == "table" then
		for _, e in ipairs(d.games) do
			if type(e) == "table" and type(e.d) == "string" then h.games[#h.games + 1] = e end
		end
	end
	if type(d.drills) == "table" then
		for id, rec in pairs(d.drills) do
			if type(id) == "string" and type(rec) == "table" and type(rec.best) == "number" then
				if type(rec.last) ~= "table" then rec.last = {} end
				h.drills[id] = rec
			end
		end
	end
	if type(d.levels) == "table" then
		for _, e in ipairs(d.levels) do
			if type(e) == "table" and type(e.to) == "string" then h.levels[#h.levels + 1] = e end
		end
	end
	return h
end

local function trim(list, n)
	while #list > n do table.remove(list, 1) end
end

-- "2FB" -> field 2, base 1; "K" a king; "=" a king missed; "Z" illegal.
local function batonCounts(token)
	local f, b = 0, 0
	local fs = token:match("^(%d*)F")
	if fs then f = fs == "" and 1 or tonumber(fs) end
	local bs = token:match("(%d*)BE?$")
	if bs then b = bs == "" and 1 or tonumber(bs) end
	return f, b
end

-- What each player of game g did, by player id:
--   { side, batons, hits, field, base, kings, kingMisses, illegal, I, R, P, Q }
-- Batons are throws (X and G are not); a hit toppled a kubb or, on a king
-- shot, the king.
function history.gameStats(g)
	local out = {}
	for _, side in ipairs { "A", "B" } do
		for _, p in ipairs(g.teams[side].players) do
			local s = { side = side }
			for _, k in ipairs(roster.TOTALS) do s[k] = 0 end
			out[p.id] = s
		end
	end
	for _, t in ipairs(g.sheet.turns) do
		for pid, k in pairs(t.inkast) do
			local s = out[pid]
			if s then
				s.I, s.R, s.P, s.Q = s.I + k.I, s.R + k.R, s.P + k.P, s.Q + k.Q
			end
		end
		for _, b in ipairs(t.batons) do
			local s = b.player and out[b.player]
			local tok = b.token
			if s and tok ~= "X" and tok ~= "G" then
				s.batons = s.batons + 1
				if tok == "K" then
					s.kings, s.hits = s.kings + 1, s.hits + 1
				elseif tok == "=" then
					s.kingMisses = s.kingMisses + 1
				elseif tok == "Z" then
					s.illegal = s.illegal + 1
				else
					-- a throw that also toppled the king early (E) is not a hit (kubb.js)
					local f, bb = batonCounts(tok)
					s.field, s.base = s.field + f, s.base + bb
					if f + bb > 0 and tok:sub(-1) ~= "E" then s.hits = s.hits + 1 end
				end
			end
		end
	end
	return out
end

-- Fold a finished game into the players in it. `r` the roster, `hs` the
-- histories by key (an entry is made for a key that has none), g the
-- engine game (over), meta:
--   keys     { [player id] = roster key }: the saved players in it (guests
--            and the Playdate have none and are left out)
--   levels   { [player id] = level played at } (optional)
--   date     "YYYY-MM-DD HH:MM", the game's end
--   file     the game file name
-- Returns the keys folded.
function history.foldGame(r, hs, g, meta)
	local stats = history.gameStats(g)
	local day = meta.date and meta.date:sub(1, 10)
	local done = {}
	for pid, key in pairs(meta.keys or {}) do
		local p, s = roster.find(r, key), stats[pid]
		if p and s then
			local t = p.totals
			for _, k in ipairs(roster.TOTALS) do
				if s[k] then t[k] = t[k] + s[k] end
			end
			local won = g.winner == s.side
			local res = won and "won" or ((g.how == "resigned") and "resigned" or "lost")
			t.games = t.games + 1
			if won then t.wins = t.wins + 1 end
			if res == "resigned" then t.resigned = t.resigned + 1 end
			if day then p.last = day end
			local h = hs[key] or history.new()
			hs[key] = h
			local other = s.side == "A" and "B" or "A"
			h.games[#h.games + 1] = { d = meta.date, f = meta.file, team = g.teams[s.side].name, side = s.side,
				res = res, vs = g.teams[other].name, b = s.batons, h = s.hits, k = s.I,
				lv = meta.levels and meta.levels[pid] or p.level }
			trim(h.games, history.tune.games)
			done[#done + 1] = key
		end
	end
	table.sort(done)
	return done
end

-- Fold a finished drill run (core/drills) into a player's records; returns
-- the drill's record and whether it is a new best (drills.record).
function history.foldDrill(r, h, key, d, run, date)
	local p = roster.find(r, key)
	if p and date then p.last = date:sub(1, 10) end
	return drills.record(h.drills, d, run)
end

-- Set a player's level and log the change in their history; returns true
-- when it changed.
function history.setLevel(r, h, key, level, date)
	local was = roster.setLevel(r, key, level)
	if not was then return false end
	h.levels[#h.levels + 1] = { d = date, from = was, to = level }
	trim(h.levels, history.tune.levels)
	return true
end

-- Hits and batons of the last n games (newest last), for the bars of a
-- player screen: { { h, b }, ... }.
function history.lastGames(h, n)
	local out = {}
	local from = #h.games - n + 1
	if from < 1 then from = 1 end
	for i = from, #h.games do
		local e = h.games[i]
		out[#out + 1] = { h = e.h or 0, b = e.b or 0, res = e.res }
	end
	return out
end

tw.history = history
