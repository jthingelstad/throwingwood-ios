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
-- The file is Planet Kubb Notation 2 in its canonical form (pk-kubb-score's
-- docs/notation-2.md, edition 2026.11; the grammar's CanonicalGame): one
-- spelling of each thing, [Notation "2"] first, the defined headers in their
-- order and the engine's own after them, a bare A for the advantage line.
--
-- Positions: lines of their own under a turn line, in the notation's frame
-- (notation.toPitch). The sheet keeps, in the engine's world frame (meters, x
-- across -2.5..2.5, y from Team A's baseline), where each kubb thrown in stood
-- as the batons began (t.inkastAt, per player) and where each kubb a baton's
-- token counts stood before it (a baton's `at`). From those the file writes,
-- for the half under attack, the pitch line @ when it can be whole and the
-- felled line * (notation.positionLines says when, and what is left out).
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

-- The ids the game file writes (since engine 0.7.1). The game keeps each
-- player's full id (assignIds) in its state, saves and history; only the file
-- is shorter. A throw by a team of one player carries no player prefix (the
-- team says who threw it). A team of more players writes each player's
-- initial, the first letter of their id; players whose prefixes are written
-- and share it get the shortest start of their id that tells them apart
-- (Kim and Karl: "ki", "ka"). An id made unique with assignIds' suffix,
-- "dana_b" beside "dana", keeps the suffix after its stem's prefix ("d",
-- "d_b"). The header names every player with the id the turn lines use: the
-- prefix, or for a one-player team its full id, which no prefix may equal.
-- Returns prefix, header: prefix[pid] is the string to write or false (no
-- prefix), header[pid] the id in [Team X Players] and [Throw Levels].
local function sharedStart(a, b)
	local n = 0
	while n < #a and n < #b and a:byte(n + 1) == b:byte(n + 1) do n = n + 1 end
	return n
end

function notation.fileIds(teams)
	local prefix, header = {}, {}
	local written, solo = {}, {}
	for _, side in ipairs { "A", "B" } do
		local ps = teams[side].players
		for _, p in ipairs(ps) do
			if #ps > 1 then written[#written + 1] = p.id; prefix[p.id] = true
			else solo[p.id] = true; prefix[p.id] = false; header[p.id] = p.id end
		end
	end
	-- each written id's stem and suffix: "dana_b" is "dana" + "_b" when "dana"
	-- is written too (assignIds' suffix); otherwise the id is its own stem
	local stemOf, suffixOf, stems, seen = {}, {}, {}, {}
	for _, id in ipairs(written) do
		local stem, suffix = id:match("^(.+)(_[a-z]+)$")
		if not (stem and prefix[stem] == true) then stem, suffix = id, "" end
		stemOf[id], suffixOf[id] = stem, suffix
		if not seen[stem] then seen[stem] = true; stems[#stems + 1] = stem end
	end
	local short = {}
	for _, s in ipairs(stems) do
		local n = 1
		for _, t in ipairs(stems) do
			if t ~= s then n = math.max(n, sharedStart(s, t) + 1) end
		end
		if n > #s then n = #s end
		while n < #s and s:sub(n, n) == "_" do n = n + 1 end
		short[s] = s:sub(1, n)
	end
	local cand = {}
	for _, id in ipairs(written) do cand[id] = short[stemOf[id]] .. suffixOf[id] end
	-- A prefix that a one-player team's full id, or another player's prefix,
	-- already says gives way to the player's full id, which is unique in the
	-- game. A full id taken up this way can meet another prefix in turn ("d"
	-- alone against "d_b_b" and "d_b"), so repeat until nothing changes: each
	-- pass only moves players to their full ids, and those never collide.
	local changed
	repeat
		changed = false
		local count = {}
		for id in pairs(solo) do count[id] = (count[id] or 0) + 1 end
		for _, id in ipairs(written) do count[cand[id]] = (count[cand[id]] or 0) + 1 end
		for _, id in ipairs(written) do
			if count[cand[id]] > 1 and cand[id] ~= id then cand[id] = id; changed = true end
		end
	until not changed
	for _, id in ipairs(written) do prefix[id], header[id] = cand[id], cand[id] end
	return prefix, header
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

-- Inkast token body from { I, R, P, Q, N, E }: "5I2R", "2IRP", "3IQ", "4IE"; "0I"
-- for none (the canonical form's only zero).
function notation.inkastBody(k)
	local n = k.N or 0
	if n > 5 then n = 5 end
	local s = count(k.I or 0, "I") .. count(k.R or 0, "R") .. count(k.P or 0, "P")
		.. count(k.Q or 0, "Q") .. count(n, "N")
	if s == "" then s = "0I" end
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

-- ---------- positions (Notation 2, "The pitch frame") ----------

-- The notation's frame from the engine's, in this one place. The origin is the
-- centre-line stake on Team A's left as Team A stands on its own baseline facing
-- the king; across runs from it along the centre line, 0 to 5 (the king at 2.5);
-- depth runs from the centre line toward a baseline, 0 to 4, the same in both
-- halves; the half (a or b) says which. The engine's x runs across with the
-- sidelines at -2.5 and 2.5, +x on the right of someone on Team A's baseline
-- facing Team B (core/camera: a positive swivel aims toward +x), and its y runs
-- from Team A's baseline (0) to Team B's (8), the centre line at 4. So across is
-- x + 2.5 and depth is 4 - y in half a, y - 4 in half b. `half` is "A" or "B":
-- the half a piece is in play for, which on the centre line is not y's to say.
function notation.toPitch(x, y, half)
	local across = x + 2.5
	local depth = half == "A" and (4 - y) or (y - 4)
	return across, depth
end

-- And back: the engine's x, y of a notation point in `half`.
function notation.fromPitch(across, depth, half)
	return across - 2.5, half == "A" and (4 - depth) or (4 + depth)
end

-- A number of metres with two decimals, rounded to the nearest centimetre with a
-- value exactly half way going to the even one (%.2f on the double's exact value,
-- which every platform's C library rounds that way), never "-0.00"; nil when it
-- is below 0.00 or above `most` once rounded.
local function metres(v, most)
	local s = fmt("%.2f", v)
	if s == "-0.00" then s = "0.00" end
	local c = tonumber((s:gsub("%.", "")))
	if c < 0 or c > most * 100 then return nil end
	return s, c
end

-- A point of the engine's frame as the notation writes it ("4.48,0.11") and its
-- across and depth in whole centimetres (for the canonical order), or nil when
-- the point is not in `half` (an earlier baton can leave a kubb over the centre
-- line, II.B.7, and a pitch or felled line has no minus sign).
function notation.point(x, y, half)
	local across, depth = notation.toPitch(x, y, half)
	local a, ac = metres(across, 5)
	local d, dc = metres(depth, 4)
	if not (a and d) then return nil end
	return a .. "," .. d, ac, dc
end

-- How many field and base kubbs a baton token counts: "2FB" 2, 1; "FE" 1, 0;
-- "K", "-", "=" 0, 0.
local function batonParts(token)
	local f = token:match("^(%d*)F")
	local b = token:match("(%d*)BE?$")
	f = f and (f == "" and 1 or tonumber(f)) or 0
	b = b and (b == "" and 1 or tonumber(b)) or 0
	return f, b
end
notation.batonParts = batonParts

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

-- One turn's line, without the trailing newline and without its position
-- lines (notation.positionLines). ids (optional, the prefix table of
-- notation.fileIds) says what each player's throws are written with; without
-- it every throw carries the player's full id. The advantage line is a bare A
-- (the canonical form): the sheet keeps its whole metres (t.advantage), which
-- Notation 2 says only through the pitch line of the thrower's own half.
local function written(pid, token, ids)
	if not pid then return token end
	local w = pid
	if ids then w = ids[pid]; if w == nil then w = pid end end
	if not w then return token end
	return w .. ":" .. token
end

function notation.turnLine(t, ids)
	local parts = { t.n .. "." }
	local notes = {}
	for _, pid in ipairs(t.inkastOrder) do
		local k = t.inkast[pid]
		if (k.N or 0) > 5 then notes[#notes + 1] = k.N .. " kubbs came to rest on another (N is capped at 5)" end
		parts[#parts + 1] = written(pid, notation.inkastBody(k), ids)
	end
	if t.advantage then parts[#parts + 1] = "A" end
	for _, b in ipairs(t.batons) do
		parts[#parts + 1] = written(b.player, b.token, ids)
	end
	for _, n in ipairs(t.notes) do notes[#notes + 1] = n end
	local line = concat(parts, " ")
	if #notes > 0 then
		local note = concat(notes, "; "):gsub("[\r\n#]", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if note ~= "" then line = line .. " # " .. note end
	end
	return line
end

-- ---------- position lines ----------

-- The inkast counts of a turn, every player's together.
local function turnCounts(t)
	local c = { I = 0, R = 0, P = 0, Q = 0, N = 0 }
	for _, pid in ipairs(t.inkastOrder) do
		local k = t.inkast[pid]
		for code in pairs(c) do c[code] = c[code] + (k[code] or 0) end
	end
	return c
end

local function byPlace(a, b)
	if a.ac ~= b.ac then return a.ac < b.ac end
	return a.dc < b.dc
end

local function placed(list, half)
	local out = {}
	for i, p in ipairs(list) do
		local text, ac, dc = notation.point(p.x, p.y, half)
		if not text then return nil end
		out[i] = { text = text, ac = ac, dc = dc }
	end
	return out
end

-- The position lines of turn t, a list of strings in the canonical order, for
-- the half under attack (the defender's, which the kubbs are thrown into).
-- `left` is how many field kubbs stood in that half from earlier turns as the
-- turn began (notation.render counts them as kubb.js does).
--
--   @  the pitch line, in points, every entry unmarked: written only when it can
--      be the whole half, that is when every field kubb standing there as the
--      first baton is thrown was thrown in this turn (none left from earlier
--      turns, `left` less the rescues is 0), no punishment kubb was placed (the
--      sheet does not say which of its kubbs is the P), and the sheet has a place
--      for every kubb thrown in. Otherwise there is none (the notation: "It is
--      the whole half or it is left out").
--   *  the felled line, a word a baton: where each kubb its token counts stood
--      before it, field kubbs then base kubbs, each group by across and then
--      depth; "-" for a baton that felled none, one the sheet has no places for,
--      one whose kubb stood outside the half, and one whose field kubb is not
--      where the pitch line has it (an earlier baton moved it), since a reader
--      finds a felled field kubb on the pitch line. No line when every word is -.
--
-- Not written, for the sheet does not keep them: the thrower's own half (its
-- kubbs are marked s), the lay line ~ (where each kubb lay before it was
-- raised) and the stance line ^ (where each baton was thrown from).
function notation.positionLines(t, left)
	local def = t.side == "A" and "B" or "A"
	local h = def:lower()
	local out = {}
	local c = turnCounts(t)
	local pitch
	-- (t.placed: a Kid game's kubbs out twice the engine stood at the fair spot, core/rules
	-- Game:_placeFair; such a kubb does not stand where it was thrown, so no line either)
	if t.inkastAt and c.I > 0 and c.P == 0 and (t.placed or 0) == 0 and (left or 0) - c.Q == 0 then
		local all = {}
		for _, pid in ipairs(t.inkastOrder) do
			for _, p in ipairs(t.inkastAt[pid] or {}) do all[#all + 1] = p end
		end
		if #all == c.I then pitch = placed(all, def) end
	end
	local onPitch
	if pitch then
		table.sort(pitch, byPlace)
		local words = {}
		onPitch = {}
		for i, e in ipairs(pitch) do
			words[i] = e.text
			onPitch[e.text] = (onPitch[e.text] or 0) + 1
		end
		out[#out + 1] = "@" .. h .. " " .. concat(words, " ")
	end
	local words, any = {}, false
	for i, b in ipairs(t.batons) do
		local f, nb = batonParts(b.token)
		local word = "-"
		local at = (f + nb > 0 and b.at and #b.at == f + nb) and placed(b.at, def) or nil
		if at then
			local field, base = {}, {}
			for j, e in ipairs(at) do
				if j <= f then field[#field + 1] = e else base[#base + 1] = e end
			end
			local ok = true
			if onPitch then
				local need = {}
				for _, e in ipairs(field) do need[e.text] = (need[e.text] or 0) + 1 end
				for text, n in pairs(need) do
					if (onPitch[text] or 0) < n then ok = false end
				end
				if ok then
					for text, n in pairs(need) do onPitch[text] = onPitch[text] - n end
				end
			end
			if ok then
				table.sort(field, byPlace)
				table.sort(base, byPlace)
				local parts = {}
				for _, e in ipairs(field) do parts[#parts + 1] = e.text end
				for _, e in ipairs(base) do parts[#parts + 1] = e.text end
				word, any = concat(parts, "+"), true
			end
		end
		words[i] = word
	end
	if any then out[#out + 1] = "*" .. h .. " " .. concat(words, " ") end
	return out
end

local function teamLabel(side) return "Team " .. side end

-- The game file: Planet Kubb Notation 2 in the canonical form. `game` is a
-- rules game (tw.rules); meta is { start, finish (time tables), version, mode,
-- event, location, levels }. levels: { "kim pro", "sam club", ... } (player id
-- and throw level), written as [Throw Levels "..."], each id as the header names
-- it (notation.fileIds: "k pro, s club"); none (nil or empty), no header. Since
-- 0.13.2 the match gives the computer's players only (match.fileLevels). The headers the notation defines come
-- in its order; the engine's own ([Mode], [Throw Levels]) after them, by code
-- point. Each turn line is followed by its position lines.
function notation.render(game, meta)
	meta = meta or {}
	local prefix, header = notation.fileIds(game.teams)
	local lines = {}
	local function h(k, v) lines[#lines + 1] = fmt('[%s "%s"]', k, v) end
	h("Notation", "2")
	h("Event", notation.cleanName(meta.event or notation.event))
	h("Location", notation.cleanName(meta.location or notation.location))
	if meta.start then h("Start", notation.formatTime(meta.start)) end
	if meta.finish then h("End", notation.formatTime(meta.finish)) end
	if meta.start and meta.finish then h("Duration", notation.minutesBetween(meta.start, meta.finish) .. "m") end
	h("Surface", game.surface)
	local six = game.opening == "six"
	if game.rules == "kid" then
		-- the Kid rules (core/rules rules.kid, 0.15.0): the notation has a header for the
		-- base kubbs and none for the rest, so the Rules header says it in words
		h("Rules", "Kid rules, " .. (six and "six from the start" or "2-4-6")
			.. ": three base kubbs; kubbs and batons from 2 m in front of the baseline;"
			.. " an early king stood back up; no punishment kubbs; helicopters count")
		h("Base kubbs", tostring(#tw.rules.baseXFor("kid")))
	else
		h("Rules", six and "U.S. Championship 4.0, six from the start" or "U.S. Championship 4.0, 2-4-6")
		h("Base kubbs", "5")
	end
	h("Batons", "6")
	h("Opening", six and "6" or "2-4-6")
	for _, side in ipairs { "A", "B" } do
		local team = game.teams[side]
		h("Team " .. side, notation.cleanName(team.name))
		local ps = {}
		for _, p in ipairs(team.players) do
			ps[#ps + 1] = notation.cleanName(p.name, true) .. " (" .. (header[p.id] or p.id) .. ")"
		end
		h("Team " .. side .. " Players", concat(ps, ", "))
	end
	h("First", teamLabel(game.first))
	if game.winner then h("Win", teamLabel(game.winner)) end
	h("Scored by", notation.scorer .. " " .. (meta.version or "0.0.0"))
	if meta.mode then h("Mode", meta.mode) end
	-- the throw levels given (docs/PLAYERS.md decision 7; the computer's players
	-- since 0.13.2, match.fileLevels): "kim pro, sam club"
	if meta.levels and #meta.levels > 0 then
		local ls = {}
		for i, l in ipairs(meta.levels) do
			local id, level = l:match("^(%S+)%s+(.*)$")
			ls[i] = (id and header[id]) and (header[id] .. " " .. level) or l
		end
		h("Throw Levels", concat(ls, ", "))
	end
	if #game.sheet.turns > 0 then lines[#lines + 1] = "" end
	-- field kubbs standing in each half, counted as kubb.js counts them: a turn's
	-- kubbs thrown in join the defender's half (less its rescues), each F felled
	-- leaves it
	local field = { A = 0, B = 0 }
	for i = 1, #game.sheet.turns do
		local t = game.sheet.turns[i]
		local def = t.side == "A" and "B" or "A"
		local c = turnCounts(t)
		field[def] = math.max(0, field[def] - c.Q) + c.I
		lines[#lines + 1] = notation.turnLine(t, prefix)
		for _, l in ipairs(notation.positionLines(t, field[def] - c.I + c.Q)) do lines[#lines + 1] = l end
		for _, b in ipairs(t.batons) do
			local f = batonParts(b.token)
			field[def] = math.max(0, field[def] - f)
		end
	end
	return concat(lines, "\n") .. "\n"
end

tw.notation = notation
