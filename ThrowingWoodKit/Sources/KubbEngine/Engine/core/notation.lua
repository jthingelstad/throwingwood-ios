-- Planet Kubb Notation: the score sheet the rules engine fills in as a game
-- runs, and the game file text (DESIGN.md section 7). Pure Lua: no
-- playdate.*, no os.time: times are passed in as tables
-- { year, month, day, hour, min }.
--
-- Counting, chosen so kubb.js (pk-kubb-score) replays every file with no
-- warnings:
--   I  every first throw of a kubb this turn, rescued kubbs included, so
--      I = kubbs knocked down last turn + Q (kubb.js checks I + Y = that).
--   R  every rethrow made (a kubb's second throw).
--   P  every punishment kubb (a kubb out after two throws; it is in R too).
--   Q  every established field kubb a toss knocked out of bounds (II.C.5a).
--   N  every kubb that came to rest on top of another (II.D.6), at most 5
--      per token (the grammar's limit).
--   Y  never written: a failed rescue attempt is intent the game cannot see.
--
-- Positions (optional in the notation, written by the game since
-- 2026-11-16): a comment that starts with @ straight after an inkast token
-- or a baton token, "j:2I (@ 1.32,5.87 1.40,6.02)". The sheet keeps them as
-- data beside the token in the engine's world frame (meters, x across
-- -2.5..2.5, y from Team A's baseline); turnLine converts them with
-- notation.pitchXY and never writes more than the token counts.
import "core/tw"

local floor, concat, fmt = math.floor, table.concat, string.format

local notation = {}

notation.event = "Throwing Wood"
notation.location = "Playdate"
notation.scorer = "Throwing Wood"

-- ---------- player ids ----------

-- The id of a name: lowercased, spaces and hyphens become "_", anything else
-- that is not a letter is dropped, underscores are not doubled or left at
-- the ends. "p" if nothing is left.
function notation.baseId(name)
	local s = (name or ""):lower():gsub("[%s%-]+", "_"):gsub("[^a-z_]", "")
	s = s:gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
	if s == "" then s = "p" end
	return s
end

-- Ids for every player of both teams, unique across the game. A name whose
-- id is taken gets "_b", "_c", ... (letters only, so the grammar accepts it).
-- teams = { A = { players = { { name = } } }, B = ... }; sets players[i].id
-- unless one is given (a given id is cleaned the same way).
function notation.assignIds(teams)
	local taken = {}
	local letters = "bcdefghijklmnopqrstuvwxyz"
	for _, side in ipairs { "A", "B" } do
		for _, p in ipairs(teams[side].players) do
			local base = notation.baseId(p.id or p.name)
			local id = base
			local i = 1
			while taken[id] do
				local suffix = ""
				local n = i
				repeat
					local k = (n - 1) % #letters + 1
					suffix = letters:sub(k, k) .. suffix
					n = (n - 1) // #letters
				until n == 0
				id = base .. "_" .. suffix
				i = i + 1
			end
			taken[id] = true
			p.id = id
		end
	end
end

-- Names inside header values: no quotes, backslashes or line breaks; player
-- names also lose commas and parentheses (kubb.js splits on them).
function notation.cleanName(s, forPlayers)
	s = (s or ""):gsub("[\"\\\r\n%]%[]", "")
	if forPlayers then s = s:gsub("[,()]", "") end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

-- ---------- times ----------

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
local function daysFromCivil(y, m, d)
	if m <= 2 then y = y - 1 end
	local era = floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z)
	z = z + 719468
	local era = floor(z / 146097)
	local doe = z - era * 146097
	local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
	local mp = floor((5 * doy + 2) / 153)
	local d = doy - floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	if m <= 2 then y = y + 1 end
	return y, m, d
end

local function toMinutes(t)
	return daysFromCivil(t.year, t.month, t.day) * 1440 + (t.hour or 0) * 60 + (t.min or 0)
end

function notation.minutesBetween(a, b)
	return toMinutes(b) - toMinutes(a)
end

function notation.addMinutes(t, minutes)
	local total = toMinutes(t) + minutes
	local days = floor(total / 1440)
	local rest = total - days * 1440
	local y, m, d = civilFromDays(days)
	return { year = y, month = m, day = d, hour = rest // 60, min = rest % 60 }
end

function notation.formatTime(t)
	return fmt("%04d-%02d-%02d %02d:%02d", t.year, t.month, t.day, t.hour or 0, t.min or 0)
end

local function slug(s)
	s = (s or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if s == "" then s = "team" end
	return s
end
notation.slug = slug

-- YYYY-MM-DD-HHMM-<team-a>-v-<team-b>.txt
function notation.filename(start, teamA, teamB)
	return fmt("%04d-%02d-%02d-%02d%02d-%s-v-%s.txt", start.year, start.month, start.day,
		start.hour or 0, start.min or 0, slug(teamA), slug(teamB))
end

-- ---------- tokens ----------

local function count(n, code)
	if n == 0 then return "" end
	if n == 1 then return code end
	return n .. code
end

-- Inkast token body from { I, R, P, Q, N, E }: "5I2R", "2IRP", "3IQ", "4IE".
function notation.inkastBody(k)
	local n = k.N or 0
	if n > 5 then n = 5 end
	local s = count(k.I or 0, "I") .. count(k.R or 0, "R") .. count(k.P or 0, "P")
		.. count(k.Q or 0, "Q") .. count(n, "N")
	if s == "" then s = "0" end
	if k.E then s = s .. "E" end
	return s
end

-- Baton token from field and base counts and an early-king flag:
-- "-", "F", "2F", "B", "2FB", "2FE", "E".
function notation.hitToken(f, b, e)
	local s = count(f, "F") .. count(b, "B")
	if e then return s .. "E" end
	if s == "" then return "-" end
	return s
end

-- ---------- positions ----------

-- The notation's frame from the engine's: the pitch seen from Team A's
-- baseline in every turn, x meters across from the left sideline (0 to 5),
-- y meters up from Team A's baseline (0 to 8). The engine's x runs across
-- with the sidelines at -2.5 and 2.5, +x on the right of someone on Team A's
-- baseline facing Team B (core/camera: a positive swivel aims toward +x, to
-- the right), and its y is already up from Team A's baseline (y = 0). So it
-- is a shift of x by half the width. Clamped to the pitch (a piece's centre
-- on a line is in; the grammar has no minus sign).
function notation.pitchXY(x, y)
	local nx, ny = x + 2.5, y
	if nx <= 0 then nx = 0 elseif nx > 5 then nx = 5 end
	if ny <= 0 then ny = 0 elseif ny > 8 then ny = 8 end
	return nx, ny
end

-- " (@ 1.32,5.87 1.40,6.02)" for at most `most` world-frame points
-- { x, y } of list `at`; "" when there are none.
function notation.positions(at, most)
	if not at or #at == 0 or (most or 0) <= 0 then return "" end
	local ps = {}
	for i = 1, math.min(#at, most) do
		local nx, ny = notation.pitchXY(at[i].x, at[i].y)
		ps[i] = fmt("%.2f,%.2f", nx, ny)
	end
	return " (@ " .. concat(ps, " ") .. ")"
end

-- How many kubbs a token counts, as kubb.js reads it (its cap on positions):
-- an inkast's I + R + P + Q + N, a baton's F + B.
local function inkastCount(k)
	local n = k.N or 0
	if n > 5 then n = 5 end
	return (k.I or 0) + (k.R or 0) + (k.P or 0) + (k.Q or 0) + n
end

local function batonCount(token)
	local f = token:match("^(%d*)F")
	local b = token:match("(%d*)BE?$")
	local c = 0
	if f then c = c + (f == "" and 1 or tonumber(f)) end
	if b then c = c + (b == "" and 1 or tonumber(b)) end
	return c
end
notation.batonCount = batonCount

-- ---------- the score sheet ----------

local Sheet = {}
Sheet.__index = Sheet
notation.Sheet = Sheet   -- (core/save restores a saved sheet with it)

function notation.sheet()
	return setmetatable({ turns = {} }, Sheet)
end

function Sheet:beginTurn(n, side)
	local t = { n = n, side = side, inkast = {}, inkastOrder = {}, advantage = nil,
		batons = {}, notes = {} }
	self.turns[n] = t
	self.current = t
	return t
end

-- Add `by` (default 1) to inkast code `code` for player `pid`.
function Sheet:ink(pid, code, by)
	local t = self.current
	local k = t.inkast[pid]
	if not k then
		k = { I = 0, R = 0, P = 0, Q = 0, N = 0, E = false }
		t.inkast[pid] = k
		t.inkastOrder[#t.inkastOrder + 1] = pid
	end
	if code == "E" then k.E = true else k[code] = k[code] + (by or 1) end
end

function Sheet:advantage(meters)
	self.current.advantage = meters
end

-- at: optional world-frame points { x, y } of the kubbs it knocked down,
-- each where it stood before the throw (the token's F kubbs, then its B).
function Sheet:baton(pid, token, at)
	local b = self.current.batons
	b[#b + 1] = { player = pid, token = token, at = (at and #at > 0) and at or nil }
end

-- Where a kubb player `pid` threw in this turn stood once raised (or
-- placed), in world meters. Kept per player in t.inkastAt (absent in turns
-- saved before positions).
function Sheet:inkAt(pid, x, y)
	local t = self.current
	local at = t.inkastAt
	if not at then at = {}; t.inkastAt = at end
	local l = at[pid]
	if not l then l = {}; at[pid] = l end
	l[#l + 1] = { x = x, y = y }
end

function Sheet:note(text)
	local n = self.current.notes
	n[#n + 1] = text
end

-- One turn's line, without the trailing newline.
function notation.turnLine(t)
	local parts = { t.n .. "." }
	local notes = {}
	for _, pid in ipairs(t.inkastOrder) do
		local k = t.inkast[pid]
		if (k.N or 0) > 5 then notes[#notes + 1] = k.N .. " kubbs came to rest on another (N is capped at 5)" end
		parts[#parts + 1] = pid .. ":" .. notation.inkastBody(k)
			.. notation.positions(t.inkastAt and t.inkastAt[pid], inkastCount(k))
	end
	if t.advantage then parts[#parts + 1] = t.advantage .. "A" end
	for _, b in ipairs(t.batons) do
		parts[#parts + 1] = (b.player and (b.player .. ":" .. b.token) or b.token)
			.. notation.positions(b.at, batonCount(b.token))
	end
	for _, n in ipairs(t.notes) do notes[#notes + 1] = n end
	local line = concat(parts, " ")
	if #notes > 0 then
		line = line .. " # " .. concat(notes, "; "):gsub("[\r\n#]", " ")
	end
	return line
end

local function teamLabel(side) return "Team " .. side end

-- The game file. `game` is a rules game (tw.rules) that has ended; meta is
-- { start, finish (time tables), version, mode, event, location, levels }.
-- levels: { "kim pro", "sam club", ... } (player id and throw level), written
-- as [Throw Levels "..."] after [Mode] when given.
function notation.render(game, meta)
	meta = meta or {}
	local lines = {}
	local function h(k, v) lines[#lines + 1] = fmt('[%s "%s"]', k, v) end
	h("Event", notation.cleanName(meta.event or notation.event))
	h("Location", notation.cleanName(meta.location or notation.location))
	if meta.start then h("Start", notation.formatTime(meta.start)) end
	if meta.finish then h("End", notation.formatTime(meta.finish)) end
	if meta.start and meta.finish then h("Duration", notation.minutesBetween(meta.start, meta.finish) .. "m") end
	h("Surface", game.surface)
	for _, side in ipairs { "A", "B" } do
		local team = game.teams[side]
		h("Team " .. side, notation.cleanName(team.name))
		local ps = {}
		for _, p in ipairs(team.players) do
			ps[#ps + 1] = notation.cleanName(p.name, true) .. " (" .. p.id .. ")"
		end
		h("Team " .. side .. " Players", concat(ps, ", "))
	end
	h("First", teamLabel(game.first))
	if game.winner then h("Win", teamLabel(game.winner)) end
	h("Scored by", notation.scorer .. " " .. (meta.version or "0.0.0"))
	if meta.mode then h("Mode", meta.mode) end
	-- each player's throw level (docs/PLAYERS.md decision 7): "kim pro, sam club"
	if meta.levels and #meta.levels > 0 then h("Throw Levels", concat(meta.levels, ", ")) end
	h("Rules", game.opening == "six" and "U.S. Championship 4.0, six from the start"
		or "U.S. Championship 4.0, 2-4-6")
	lines[#lines + 1] = ""
	for i = 1, #game.sheet.turns do
		lines[#lines + 1] = notation.turnLine(game.sheet.turns[i])
	end
	return concat(lines, "\n") .. "\n"
end

tw.notation = notation
