-- Record mode (since 1.1.0): a real game of kubb scored throw by throw. The host says
-- what was observed (a kubb thrown in was in or out, what a baton felled, the king, a
-- resign, a game called), the engine keeps the state under the rules and writes the
-- Planet Kubb Notation 2 file. docs/RECORD.md is the reference; session/record.lua is
-- the door (kubbCall("record.<name>")).
--
-- It is not tw.rules. The rules engine judges poses the physics gives it; a scorer has
-- no poses, only verdicts, and records what happened rather than enforcing it. Record
-- mode counts kubbs the way pk-kubb-score's kubb.js counts them, so every file it writes
-- reads back with no warnings, and it says where the game broke a rule as a warning
-- instead of an error.
--
--   local r = tw.record.new(setup)          -- setup: docs/RECORD.md "The game"
--   tw.record.apply(r, event)               -- one event: docs/RECORD.md "Events"
--   local r = tw.record.build(setup, events) -- the whole log: a rebuild
--   tw.record.state(r), tw.record.render(r), tw.record.rows(r)
--
-- Events are plain data and nothing here keeps a reference to one, so a rebuild from the
-- same log gives the same game. Pure Lua like the rest of core/: no os.*, no io.*.
import "core/tw"
import "core/notation"
import "core/order"
import "core/rules"

local notation, order = tw.notation, tw.order
local floor, concat, fmt, sort = math.floor, table.concat, string.format, table.sort

local record = {}

-- The version of the event records and the state (docs/RECORD.md). It only grows.
record.FORMAT = 1

record.SCORER = "Kubb: Pitchside"
record.SURFACES = { "grass", "sand", "snow" }
record.OPENINGS = { "2-4-6", "six" }
record.WINDS = { "off", "light", "strong" }
-- What a game may capture besides the turn line, in the order the capture header names
-- them. `lay` is taken and kept but never written: the lay line needs its pitch line in
-- points, and record mode writes cells (docs/RECORD.md "What the file writes").
record.SWITCHES = { "players", "pitch", "lay", "stance" }
record.EVENTS = { "toss", "punish", "pitch", "advantage", "baton", "resign", "call", "capture", "note" }

local surfaceName = { grass = "Grass", sand = "Sand", snow = "Snow" }
local isOpening = { ["2-4-6"] = true, six = true }
local isWind = { off = true, light = true, strong = true }
local isSwitch = { players = true, pitch = true, lay = true, stance = true }

local function other(side) return side == "A" and "B" or "A" end

local function fail(why) error("record: " .. why, 0) end

-- A whole number from a JSON value (3 and 3.0 alike), or nil.
local function int(v)
	if type(v) ~= "number" then return nil end
	return math.tointeger(v)
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

-- ---------- the game ----------

local function checkTime(t, what)
	if t == nil then return nil end
	if type(t) ~= "table" or not (int(t.year) and int(t.month) and int(t.day)) then
		fail(what .. ": a time is { year, month, day, hour, min }")
	end
	return { year = int(t.year), month = int(t.month), day = int(t.day),
		hour = int(t.hour) or 0, min = int(t.min) or 0 }
end

local function text(v, what, most)
	if v == nil then return nil end
	if type(v) ~= "string" then fail(what .. " is text") end
	v = notation.cleanName(v)
	if v == "" then return nil end
	if #v > most then fail(what .. " is at most " .. most .. " bytes") end
	return v
end

-- setup: { teams = { A = { name, players = { { name, id? }, ... } }, B = ... }, first,
-- opening, surface, wind, rules, event, location, client, start, capture }.
-- A setup that cannot be a game is an error; nothing after it is.
function record.new(setup)
	if type(setup) ~= "table" then fail("new: a game setup table") end
	if setup.rules ~= nil and setup.rules ~= "standard" then
		if setup.rules == "kid" then fail("new: record mode has no Kid rules (rules = \"kid\")") end
		fail("new: rules is \"standard\" (U.S. Championship 4.0) or left out")
	end
	local opening = setup.opening or "2-4-6"
	if not isOpening[opening] then fail("new: opening is \"2-4-6\" or \"six\"") end
	local surface = setup.surface or "grass"
	if not surfaceName[surface] then fail("new: surface is \"grass\", \"sand\" or \"snow\"") end
	local wind = setup.wind or "off"
	if not isWind[wind] then fail("new: wind is \"off\", \"light\" or \"strong\"") end
	local first = setup.first or "A"
	if first ~= "A" and first ~= "B" then fail("new: first is \"A\" or \"B\"") end
	local client = setup.client
	if client ~= nil and not (type(client) == "string" and #client >= 1 and #client <= 40
		and client:match("^[%w%.%-%+ ()]+$") and not client:match("^ ") and not client:match(" $")) then
		fail("new: client is 1 to 40 letters, digits, spaces, dots, hyphens, pluses or parentheses, like \"1.0 (1.1.0)\"")
	end
	if type(setup.teams) ~= "table" then fail("new: teams = { A = { name, players }, B = ... }") end
	local teams = {}
	for _, side in ipairs { "A", "B" } do
		local t = setup.teams[side]
		if type(t) ~= "table" then fail("new: teams." .. side .. " = { name, players }") end
		local name = text(t.name, "teams." .. side .. ".name", 60) or ("Team " .. side)
		local ps = {}
		if type(t.players) ~= "table" or #t.players < 1 or #t.players > 6 then
			fail("new: teams." .. side .. ".players is 1 to 6 players")
		end
		for i, p in ipairs(t.players) do
			if type(p) == "string" then p = { name = p } end
			if type(p) ~= "table" then fail("new: teams." .. side .. ".players[" .. i .. "] = { name }") end
			local pname = notation.cleanName(type(p.name) == "string" and p.name or "", true)
			if pname == "" then pname = "Player " .. i end
			if #pname > 60 then fail("new: a player's name is at most 60 bytes") end
			ps[i] = { name = pname, id = type(p.id) == "string" and p.id or nil }
		end
		teams[side] = { name = name, players = ps }
	end
	notation.assignIds(teams)
	local r = {
		format = record.FORMAT,
		teams = teams, first = first, opening = opening, surface = surface, wind = wind,
		event = text(setup.event, "event", 120), location = text(setup.location, "location", 120),
		client = client, start = checkTime(setup.start, "new: start"),
		capture = { players = false, pitch = false, lay = false, stance = false },
		used = {},
		field = { A = 0, B = 0 }, base = { A = 5, B = 5 },
		pos = { A = {}, B = {} }, basePos = {}, baseKnown = { A = true, B = true },
		turns = {}, warnings = {}, events = 0,
		sideOf = {}, playerOf = {},
	}
	if type(setup.capture) == "table" then
		for k, v in pairs(setup.capture) do
			if isSwitch[k] then r.capture[k] = v == true end
		end
	end
	for _, side in ipairs { "A", "B" } do
		for _, p in ipairs(teams[side].players) do r.sideOf[p.id] = side; r.playerOf[p.id] = p end
		local cells = {}
		for i = 0, 4 do cells[#cells + 1] = { a = i, d = 3 } end
		r.basePos[side] = cells
	end
	record._beginTurn(r)
	return r
end

-- ---------- warnings ----------

local function warn(r, code, msg)
	local w = { event = r.at, code = code, text = msg, turn = r.cur and r.cur.n or nil }
	if r.atId ~= nil then w.id = r.atId end
	r.warnings[#r.warnings + 1] = w
	if r.added then r.added[#r.added + 1] = w end
end

-- ---------- positions ----------

-- A tap { across, depth } in the notation's frame (docs/notation-2.md "The pitch
-- frame": metres, across 0 to 5 along the centre line, depth 0 to 4 from it) as its
-- cell { a, d }; nil and a warning for anything else. The far edges belong to the last
-- cell, as the notation has it.
local function cellOf(r, p, what)
	if p == nil then return nil end
	local across = type(p) == "table" and (p.across or p[1]) or nil
	local depth = type(p) == "table" and (p.depth or p[2]) or nil
	if type(across) ~= "number" or type(depth) ~= "number" or across < 0 or across > 5
		or depth < 0 or depth > 4 then
		warn(r, "position", what .. ": a position is { across 0 to 5, depth 0 to 4 }; left out")
		return nil
	end
	local a, d = floor(across), floor(depth)
	if a > 4 then a = 4 end
	if d > 3 then d = 3 end
	return { a = a, d = d }
end

-- A stance { across, depth }: a point in the thrower's own half, depth 0 to 9.99 (a
-- thrower may stand behind the baseline at 4.00). The point's text, or nil.
local function stanceOf(r, p)
	if p == nil then return nil end
	local across = type(p) == "table" and (p.across or p[1]) or nil
	local depth = type(p) == "table" and (p.depth or p[2]) or nil
	local function m(v, most)
		if type(v) ~= "number" then return nil end
		local s = fmt("%.2f", v)
		if s == "-0.00" then s = "0.00" end
		local c = tonumber((s:gsub("%.", "")))
		if c < 0 or c > most * 100 then return nil end
		return s
	end
	local a, d = m(across, 5), m(depth, 9.99)
	if not (a and d) then
		warn(r, "position", "a stance is { across 0 to 5, depth 0 to 9.99 }; left out")
		return nil
	end
	return a .. "," .. d
end

-- Take the entry at cell c out of list; true if one was there.
local function takeCell(list, c)
	for i, e in ipairs(list) do
		if e.a == c.a and e.d == c.d then table.remove(list, i); return true end
	end
	return false
end

-- ---------- turns ----------

function record._beginTurn(r, side)
	local prev = r.turns[#r.turns]
	local n = #r.turns + 1
	side = side or (prev and other(prev.side) or r.first)
	local def = other(side)
	local due = prev and prev.felled or 0
	local t = {
		n = n, side = side, batonsTotal = tw.rules.batonsFor(r.opening, n),
		capture = copy(r.capture), fresh = true,
		due = due, dueStart = due, rethrows = 0, rescuable = r.field[def], tosses = 0,
		ink = {}, inkOrder = {}, P = 0, placedP = 0, thrownIn = 0,
		advantage = r.field[side] > 0, felled = 0, batons = {}, notes = {},
	}
	r.turns[n] = t
	r.cur = t
	r.phase = due > 0 and "inkast" or "batons"
	return t
end

-- The attacking side's player id `by` names, or nil (with a warning when it names
-- nobody on that team).
local function thrower(r, t, by)
	if by == nil then return nil end
	if r.sideOf[by] == t.side then return by end
	if r.sideOf[by] then
		warn(r, "thrower", "player " .. tostring(by) .. " is not on Team " .. t.side .. ", whose turn it is; written with no player")
	else
		warn(r, "thrower", "no player " .. tostring(by) .. "; written with no player")
	end
	return nil
end

local function ink(t, by, code, n)
	local key = by or ""
	local k = t.ink[key]
	if not k then
		k = { I = 0, R = 0, P = 0, Y = 0, Q = 0, N = 0, E = false }
		t.ink[key] = k
		t.inkOrder[#t.inkOrder + 1] = key
	end
	if code == "E" then k.E = true else k[code] = k[code] + (n or 1) end
end

-- An inkast the batons (or the game's end) cut short: every kubb still due counts as
-- thrown in, so the token says how many kubbs the turn had (kubb.js checks I + Y
-- against the kubbs felled last turn). With no toss recorded at all there is no token:
-- the notation reads a turn with none as "not recorded".
local function closeInkast(r, t, why)
	local left = t.due + t.rethrows
	if left == 0 then return end
	local def = other(t.side)
	if t.tosses == 0 then
		t.unrecorded = true
	else
		local key = t.lastBy
		if t.due > 0 then ink(t, key ~= "" and key or nil, "I", t.due) end
		if t.rethrows > 0 then ink(t, key ~= "" and key or nil, "R", t.rethrows) end
	end
	r.field[def] = r.field[def] + left
	t.thrownIn = t.thrownIn + t.due
	if why then warn(r, "inkast", left .. (left == 1 and " kubb" or " kubbs") .. " not recorded in the inkast; " .. why) end
	t.due, t.rethrows = 0, 0
end

local function finish(r, winner, how)
	local t = r.cur
	r.winner, r.how, r.phase = winner, how, "over"
	if t then
		for _ = #t.batons + 1, t.batonsTotal do t.batons[#t.batons + 1] = { token = "X" } end
	end
	if r.atTime then r.finish = r.atTime end
end

-- ---------- events ----------

local apply = {}

function apply.toss(r, e)
	local t = r.cur
	if r.phase ~= "inkast" then
		warn(r, "phase", r.phase == "batons" and "a kubb thrown in after the inkast was done; not recorded"
			or "a kubb thrown in when there are none to throw; not recorded")
		return
	end
	t.fresh = false
	local def = other(t.side)
	local by = t.capture.players and thrower(r, t, e.by) or nil
	t.tosses = t.tosses + 1
	t.lastBy = by or ""
	local rethrow = t.due == 0
	local rescued = int(e.rescued) or 0
	if rescued < 0 then rescued = 0 end
	if rescued > t.rescuable then
		warn(r, "count", "rescued " .. rescued .. ", but " .. t.rescuable .. " field "
			.. (t.rescuable == 1 and "kubb" or "kubbs") .. " stood from earlier turns; counted " .. t.rescuable)
		rescued = t.rescuable
	end
	if rethrow then
		t.rethrows = t.rethrows - 1
		ink(t, by, "R")
		if e.rescueAttempt and rescued == 0 then
			warn(r, "rescue", "a failed rescue (Y) is a first throw; this was a rethrow, written as R")
		end
	else
		t.due = t.due - 1
		t.thrownIn = t.thrownIn + 1
		-- a rescue that failed is Y in place of I (pk-kubb-score: "rescue attempts that
		-- failed"); one that rescued is an I with its Q
		ink(t, by, (e.rescueAttempt and rescued == 0) and "Y" or "I")
	end
	if rescued > 0 then
		ink(t, by, "Q", rescued)
		t.rescuable = t.rescuable - rescued
		r.field[def] = r.field[def] - rescued
		t.due = t.due + rescued
		local list = r.pos[def]
		local given = type(e.rescuedAt) == "table" and #e.rescuedAt == rescued
		local ok = given
		if given then
			for _, p in ipairs(e.rescuedAt) do
				local c = cellOf(r, p, "rescuedAt")
				if not (c and takeCell(list, c)) then ok = false end
			end
		end
		if not ok then r.pos[def] = {} end
	end
	if e.onTop then ink(t, by, "N") end
	if e.king then
		-- a kubb thrown in that knocks the king over loses (II.C, E)
		ink(t, by, "E")
		closeInkast(r, t)
		t.notes[#t.notes + 1] = "king toppled by a thrown kubb"
		finish(r, def, "king toppled by a thrown kubb")
		return
	end
	local inNow = e.result ~= "out"
	if e.result ~= "in" and e.result ~= "out" then
		warn(r, "result", "a toss's result is \"in\" or \"out\"; taken as in")
	end
	if inNow then
		r.field[def] = r.field[def] + 1
		local c = cellOf(r, e.at, "toss at")
		if c then
			c.turn = t.n
			r.pos[def][#r.pos[def] + 1] = c
		end
	elseif rethrow then
		-- out twice: a punishment kubb, placed by the defender (II.C.5c, II.D.11)
		ink(t, by, "P")
		t.P = t.P + 1
		r.field[def] = r.field[def] + 1
	else
		t.rethrows = t.rethrows + 1
	end
	if t.due == 0 and t.rethrows == 0 then r.phase = "batons" end
end

function apply.punish(r, e)
	local t = r.cur
	if r.phase == "over" or #t.batons > 0 then
		warn(r, "phase", "a punishment kubb placed after the batons began; not recorded")
		return
	end
	if t.placedP >= t.P then
		warn(r, "punish", "no punishment kubb is waiting to be placed; not recorded")
		return
	end
	local c = cellOf(r, e.at, "punish at")
	if not c then
		if e.at == nil then warn(r, "position", "a punishment kubb with no position; nothing recorded") end
		return
	end
	t.fresh = false
	t.placedP = t.placedP + 1
	c.turn, c.how = t.n, "p"
	local def = other(t.side)
	r.pos[def][#r.pos[def] + 1] = c
end

function apply.pitch(r, e)
	local t = r.cur
	if r.phase == "over" then warn(r, "phase", "the game is over; pitch not recorded"); return end
	local half = e.half
	if half ~= "A" and half ~= "B" then warn(r, "pitch", "a pitch event's half is \"A\" or \"B\"; not recorded"); return end
	local at = type(e.at) == "table" and e.at or {}
	if #at ~= r.field[half] then
		warn(r, "pitch", "the pitch event gives " .. #at .. " field kubbs for half " .. half .. ", where "
			.. r.field[half] .. " stand; not recorded")
		return
	end
	local list = {}
	for i, p in ipairs(at) do
		local c = cellOf(r, p, "pitch at")
		if not c then return end
		local mark = type(p) == "table" and p.mark or nil
		if half == t.side or mark == "s" then c.turn = 0
		else c.turn = t.n; if mark == "p" then c.how = "p" end end
		list[i] = c
	end
	r.pos[half] = list
end

function apply.advantage(r, e)
	local t = r.cur
	if r.phase == "over" then warn(r, "phase", "the game is over; advantage not recorded"); return end
	t.observed = e.applies == true
	t.meters = int(e.meters)
	if t.observed ~= t.advantage then
		local s = t.advantage and "field kubbs stand in Team " .. t.side .. "'s half, so its batons go from the advantage line"
			or "no field kubb stands in Team " .. t.side .. "'s half, so there is no advantage line"
		warn(r, "advantage", "the advantage line was observed " .. (t.observed and "in use" or "not in use")
			.. ", but " .. s .. "; the file follows the count")
		t.notes[#t.notes + 1] = "advantage line observed " .. (t.observed and "in use" or "not in use")
	end
end

-- The pitch lines as the first baton is thrown: each half whose field kubbs all have a
-- place, and whose places agree with the count (the canonical form and kubb.js check
-- both). { [half] = entries }.
local function snapshotPitch(r, t)
	if not t.capture.pitch then return end
	t.pitchAt = {}
	local def = other(t.side)
	for _, half in ipairs { "A", "B" } do
		local list = r.pos[half]
		if r.field[half] > 0 and #list == r.field[half] then
			local s, p = 0, 0
			for _, c in ipairs(list) do
				if c.turn < t.n then s = s + 1 elseif c.how == "p" then p = p + 1 end
			end
			local ok
			if half == def then
				ok = s == r.field[half] - t.thrownIn and p == t.P
			else
				ok = s == #list
			end
			if ok then
				local entries = {}
				for i, c in ipairs(list) do
					entries[i] = { a = c.a, d = c.d, mark = c.turn < t.n and "s" or c.how }
				end
				t.pitchAt[half] = entries
			end
		end
	end
	-- what a felled word may name: the pitch line of the half under attack, as kubb.js
	-- finds a felled field kubb on it
	if t.pitchAt[def] then
		t.left = {}
		for _, c in ipairs(t.pitchAt[def]) do
			local k = c.a .. "," .. c.d
			t.left[k] = (t.left[k] or 0) + 1
		end
	end
end

local function orderCheck(r, t)
	if not t.capture.players then return end
	local pids = {}
	for _, b in ipairs(t.batons) do
		if not b.by then return end
		pids[#pids + 1] = b.by
	end
	local n = #r.teams[t.side].players
	local ok, why = order.check(n, t.batonsTotal, pids)
	if not ok and not t.orderWarned then
		t.orderWarned = true
		if why == "cap" then
			warn(r, "order", "a player has thrown more than " .. order.cap(n, t.batonsTotal)
				.. " batons this turn (II.B.5); recorded as thrown")
		else
			warn(r, "order", "this turn's batons need " .. order.distinct(n, t.batonsTotal)
				.. " different players (II.A.4); recorded as thrown")
		end
	end
end

function apply.baton(r, e)
	local t = r.cur
	if r.phase == "over" then warn(r, "phase", "a baton after the game ended; not recorded"); return end
	if r.phase == "inkast" then closeInkast(r, t, "taken as in") end
	r.phase = "batons"
	t.fresh = false
	if #t.batons == 0 then snapshotPitch(r, t) end
	local def = other(t.side)
	local by = t.capture.players and thrower(r, t, e.by) or nil
	local n = #t.batons + 1
	local standingF, standingB = r.field[def], r.base[def]
	local kingShot = standingF + standingB == 0
	local f0, b0 = int(e.field) or 0, int(e.base) or 0
	if f0 < 0 then f0 = 0 end
	if b0 < 0 then b0 = 0 end
	local f, b = f0, b0
	local token, win, lose, notes = nil, false, false, t.notes
	if e.illegal then
		if e.king and not kingShot then token, lose = "E", true
		else token = "Z" end
		f, b = 0, 0
		if f0 + b0 > 0 then warn(r, "illegal", "an illegal throw counts nothing it felled (all put back); recorded as Z") end
	elseif kingShot then
		if f0 + b0 > 0 then warn(r, "count", "no kubb stands, so this baton is the king shot; its felled kubbs are left out") end
		f, b = 0, 0
		if e.king then token, win = "K", true else token = "=" end
	else
		if f > standingF then
			warn(r, "count", "baton " .. n .. " felled " .. f .. " field kubbs, but " .. standingF .. " stood; counted " .. standingF)
			f = standingF
		end
		if b > 0 and standingF - f > 0 then
			-- II.B.4a: a base kubb toppled while a field kubb still stands is stood back up
			warn(r, "rule", "baton " .. n .. " felled a base kubb with a field kubb still standing; it is stood back up (II.B.4a)")
			notes[#notes + 1] = "b" .. n .. " toppled a base kubb early; raised (II.B.4a)"
			b = 0
		end
		if b > standingB then
			warn(r, "count", "baton " .. n .. " felled " .. b .. " base kubbs, but " .. standingB .. " stood; counted " .. standingB)
			b = standingB
		end
		if e.king then
			token, lose = notation.hitToken(f, b, true), true
			warn(r, "rule", "the king fell with kubbs still standing: Team " .. t.side .. " loses")
		else
			token = notation.hitToken(f, b)
		end
	end
	r.field[def] = r.field[def] - f
	r.base[def] = r.base[def] - b
	t.felled = t.felled + f + b
	-- where the felled kubbs stood: the field kubbs' cells, then the base kubbs'
	local word
	local at = type(e.at) == "table" and e.at or nil
	local fieldCells, baseCells
	if at and #at == f0 + b0 and f == f0 and f0 + b0 > 0 then
		fieldCells, baseCells = {}, {}
		for i, p in ipairs(at) do
			local c = cellOf(r, p, "baton at")
			if not c then fieldCells = nil; break end
			if i <= f0 then fieldCells[#fieldCells + 1] = c else baseCells[#baseCells + 1] = c end
		end
	elseif at and #at > 0 then
		warn(r, "position", "baton " .. n .. " gives " .. #at .. " positions for " .. (f0 + b0) .. " felled kubbs; left out")
	end
	if f > 0 then
		local ok = fieldCells ~= nil
		if ok then
			for _, c in ipairs(fieldCells) do
				if not takeCell(r.pos[def], c) then ok = false end
			end
			if not ok then warn(r, "position", "baton " .. n .. " felled a field kubb where none was recorded; the half's positions are reset") end
		end
		if not ok then r.pos[def] = {} end
	end
	if r.field[def] == 0 then r.pos[def] = {} end
	if b > 0 then
		local ok = baseCells ~= nil and r.baseKnown[def]
		if ok then
			for _, c in ipairs(baseCells) do
				if not takeCell(r.basePos[def], c) then ok = false end
			end
		end
		if not ok then r.baseKnown[def] = false end
	end
	if r.base[def] == 0 then r.basePos[def] = {}; r.baseKnown[def] = true end
	if fieldCells and f + b > 0 then
		local fieldPart = {}
		for i = 1, f do fieldPart[i] = fieldCells[i] end
		local basePart = {}
		if b > 0 then for i = 1, b do basePart[i] = baseCells[i] end end
		-- a felled field kubb must be on the pitch line, when there is one (kubb.js)
		local fits = true
		if t.left then
			local need = {}
			for _, c in ipairs(fieldPart) do local k = c.a .. "," .. c.d; need[k] = (need[k] or 0) + 1 end
			for k, m in pairs(need) do if (t.left[k] or 0) < m then fits = false end end
			if fits then for k, m in pairs(need) do t.left[k] = t.left[k] - m end end
		end
		if fits then word = { field = fieldPart, base = basePart } end
	end
	t.batons[n] = { token = token, by = by, word = word, stance = stanceOf(r, e.stance) }
	orderCheck(r, t)
	if win then finish(r, t.side, "king"); return end
	if lose then finish(r, def, "king toppled early"); return end
	if n >= t.batonsTotal then record._beginTurn(r) end
end

-- The game ends with token `code` (G resigned, W called) on `side`'s turn line: the
-- current turn's if that side is throwing. If the other side is, and nothing has been
-- thrown in its turn yet, the token goes on `side`'s turn before it; otherwise the
-- current turn closes as it stands and `side` gets a line of its own after it (the
-- notation writes G and W for the throwing team only).
local function endOnLine(r, side, code, winner, how)
	local t = r.cur
	if side ~= t.side and t.tosses == 0 and #t.batons == 0 then
		local prev = r.turns[t.n - 1]
		if not prev then
			warn(r, "phase", "the game cannot end on Team " .. side .. "'s line before either team has thrown; not recorded")
			return
		end
		r.turns[t.n] = nil
		r.cur = prev
		t = prev
	else
		if r.phase == "inkast" then
			closeInkast(r, t)
			if t.tosses > 0 then t.notes[#t.notes + 1] = (code == "G" and "resigned" or "called") .. " during the inkast" end
		end
		if side ~= t.side then
			t = record._beginTurn(r, side)
			if t.due > 0 then closeInkast(r, t) end
		end
	end
	t.fresh = false
	t.batons[#t.batons + 1] = { token = code }
	finish(r, winner, how)
end

function apply.resign(r, e)
	if r.phase == "over" then warn(r, "phase", "the game is over; resign not recorded"); return end
	local side = e.side or r.cur.side
	if side ~= "A" and side ~= "B" then warn(r, "resign", "a resign's side is \"A\" or \"B\"; not recorded"); return end
	endOnLine(r, side, "G", other(side), "resigned")
end

function apply.call(r, e)
	if r.phase == "over" then warn(r, "phase", "the game is over; call not recorded"); return end
	local side = e.winner
	if side ~= "A" and side ~= "B" then warn(r, "call", "a call's winner is \"A\" or \"B\"; not recorded"); return end
	endOnLine(r, side, "W", side, "called")
end

function apply.capture(r, e)
	for _, k in ipairs(record.SWITCHES) do
		if e[k] ~= nil then r.capture[k] = e[k] == true end
	end
	if r.cur and r.cur.fresh and r.phase ~= "over" then r.cur.capture = copy(r.capture) end
end

function apply.note(r, e)
	if type(e.text) ~= "string" then return end
	local s = e.text:gsub("[\r\n#]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
	if s ~= "" and r.cur then r.cur.notes[#r.cur.notes + 1] = s end
end

-- One event. Warnings go on r.warnings (and r.added, when the caller set it); nothing an
-- event says is an error.
function record.apply(r, e)
	r.at = r.events
	r.events = r.events + 1
	if type(e) ~= "table" then
		r.atId = nil
		warn(r, "event", "an event is a table with a type; skipped")
		return r
	end
	r.atId = e.id
	r.atTime = nil
	if e.time ~= nil then
		local ok, tm = pcall(checkTime, e.time, "time")
		if ok then r.atTime = tm else warn(r, "time", "an event's time is { year, month, day, hour, min }; left out") end
	end
	if r.atTime then
		r.last = r.atTime
		if not r.start then r.start = r.atTime; r.startFromEvent = true end
	end
	local f = apply[e.type]
	if not f then
		warn(r, "event", "no event type " .. tostring(e.type) .. " in this engine; skipped")
		return r
	end
	f(r, e)
	return r
end

function record.build(setup, events)
	local r = record.new(setup)
	for _, e in ipairs(events or {}) do record.apply(r, e) end
	return r
end

-- ---------- the file ----------

local function cellText(c) return c.a .. "," .. c.d end

-- cells of one group, by across and then depth, a cell written once with its count
local function cellGroup(list, mark)
	local sorted = {}
	for i, c in ipairs(list) do sorted[i] = c end
	sort(sorted, function(x, y) if x.a ~= y.a then return x.a < y.a end return x.d < y.d end)
	local out, i = {}, 1
	while i <= #sorted do
		local c, m = sorted[i], 1
		while sorted[i + m] and sorted[i + m].a == c.a and sorted[i + m].d == c.d do m = m + 1 end
		out[#out + 1] = (m > 1 and (m .. "x") or "") .. cellText(c) .. (mark or "")
		i = i + m
	end
	return out
end

local function pitchLine(half, entries)
	local s, u, p = {}, {}, {}
	for _, c in ipairs(entries) do
		if c.mark == "s" then s[#s + 1] = c elseif c.mark == "p" then p[#p + 1] = c else u[#u + 1] = c end
	end
	local words = {}
	for _, w in ipairs(cellGroup(s, "s")) do words[#words + 1] = w end
	for _, w in ipairs(cellGroup(u)) do words[#words + 1] = w end
	for _, w in ipairs(cellGroup(p, "p")) do words[#words + 1] = w end
	return "@" .. half:lower() .. " " .. concat(words, " ")
end

-- The prefix each player's throws are written with (notation.fileIds), for this turn.
local function written(t, by, prefix, token)
	if not (t.capture.players and by and by ~= "") then return token end
	local w = prefix[by]
	if not w then return token end
	return w .. ":" .. token
end

-- A turn's line and its position lines.
local function turnText(r, t, prefix)
	local parts, notes = { t.n .. "." }, {}
	if not t.unrecorded and (t.dueStart > 0 or t.tosses > 0) then
		-- one token a player, in order of their first toss; with players off, one token
		local groups, gorder = {}, {}
		for _, key in ipairs(t.inkOrder) do
			local g = t.capture.players and key or ""
			if not groups[g] then
				groups[g] = { I = 0, R = 0, P = 0, Y = 0, Q = 0, N = 0, E = false }
				gorder[#gorder + 1] = g
			end
			local k = t.ink[key]
			for _, c in ipairs { "I", "R", "P", "Y", "Q", "N" } do groups[g][c] = groups[g][c] + k[c] end
			if k.E then groups[g].E = true end
		end
		for _, g in ipairs(gorder) do
			local k = groups[g]
			if k.N > 5 then notes[#notes + 1] = k.N .. " kubbs came to rest on another (N is capped at 5)" end
			parts[#parts + 1] = written(t, g, prefix, notation.inkastBody(k))
		end
	end
	if t.advantage then parts[#parts + 1] = "A" end
	for _, b in ipairs(t.batons) do parts[#parts + 1] = written(t, b.by, prefix, b.token) end
	for _, n in ipairs(t.notes) do notes[#notes + 1] = n end
	local line = concat(parts, " ")
	if #notes > 0 then
		local note = concat(notes, "; "):gsub("[\r\n#]", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if note ~= "" then line = line .. " # " .. note end
	end
	local lines = {}
	local def, att = other(t.side), t.side
	if t.capture.pitch and t.pitchAt then
		for _, half in ipairs { "A", "B" } do
			if t.pitchAt[half] then lines[#lines + 1] = pitchLine(half, t.pitchAt[half]) end
		end
	end
	if t.capture.stance then
		local words, any = {}, false
		for i, b in ipairs(t.batons) do
			words[i] = b.stance or "-"
			if b.stance then any = true end
		end
		if any then lines[#lines + 1] = "^" .. att:lower() .. " " .. concat(words, " ") end
	end
	if t.capture.pitch then
		local words, any = {}, false
		for i, b in ipairs(t.batons) do
			local w = "-"
			if b.word then
				local ws = cellGroup(b.word.field)
				for _, x in ipairs(cellGroup(b.word.base)) do ws[#ws + 1] = x end
				w, any = concat(ws, "+"), true
			end
			words[i] = w
		end
		if any then lines[#lines + 1] = "*" .. def:lower() .. " " .. concat(words, " ") end
	end
	return line, lines
end

-- What the capture header says: each switch on for any turn written, but lay, which the
-- file never writes (record.SWITCHES).
local function captured(r)
	local on = {}
	for _, t in ipairs(r.turns) do
		for _, k in ipairs(record.SWITCHES) do if t.capture[k] then on[k] = true end end
	end
	on.lay = nil
	local words = {}
	for _, k in ipairs(record.SWITCHES) do if on[k] then words[#words + 1] = k end end
	return #words > 0 and concat(words, " ") or "turns"
end

-- The turns the file writes: every turn with something in it (the turn waiting for its
-- first throw is left out).
local function writtenTurns(r)
	local out = {}
	for i, t in ipairs(r.turns) do
		local empty = #t.batons == 0 and t.tosses == 0 and not t.unrecorded
		if not (empty and i == #r.turns and r.phase ~= "over") then out[#out + 1] = t end
	end
	return out
end

-- The game file (Planet Kubb Notation 2, canonical form) and its file name.
function record.render(r)
	local prefix, header = notation.fileIds(r.teams)
	local lines = {}
	local function h(k, v) lines[#lines + 1] = fmt('[%s "%s"]', k, v) end
	h("Notation", "2")
	if r.event then h("Event", r.event) end
	if r.location then h("Location", r.location) end
	local finish = r.phase == "over" and r.finish or nil
	if r.start then h("Start", notation.formatTime(r.start)) end
	if finish then h("End", notation.formatTime(finish)) end
	if r.start and finish and notation.minutesBetween(r.start, finish) >= 0 then
		h("Duration", notation.minutesBetween(r.start, finish) .. "m")
	end
	h("Surface", surfaceName[r.surface])
	local six = r.opening == "six"
	h("Rules", six and "U.S. Championship 4.0, six from the start" or "U.S. Championship 4.0, 2-4-6")
	h("Base kubbs", "5")
	h("Batons", "6")
	h("Opening", six and "6" or "2-4-6")
	for _, side in ipairs { "A", "B" } do
		local team = r.teams[side]
		h("Team " .. side, notation.cleanName(team.name))
		local ps = {}
		for _, p in ipairs(team.players) do
			ps[#ps + 1] = notation.cleanName(p.name, true) .. " (" .. (header[p.id] or p.id) .. ")"
		end
		h("Team " .. side .. " Players", concat(ps, ", "))
	end
	h("First", "Team " .. r.first)
	if r.winner then h("Win", "Team " .. r.winner) end
	h("Scored by", record.SCORER .. (r.client and (" " .. r.client) or ""))
	-- the writer's own keys, by code point
	h("Pitchside:capture", captured(r))
	if r.wind ~= "off" then h("Pitchside:wind", r.wind) end
	local turns = writtenTurns(r)
	if #turns > 0 then lines[#lines + 1] = "" end
	for _, t in ipairs(turns) do
		local line, pos = turnText(r, t, prefix)
		lines[#lines + 1] = line
		for _, l in ipairs(pos) do lines[#lines + 1] = l end
	end
	local name = r.start and notation.filename(r.start, r.teams.A.name, r.teams.B.name) or "kubb-game.txt"
	return concat(lines, "\n") .. "\n", name
end

-- ---------- what a host reads ----------

local function cellsOut(list, n)
	local out = {}
	for i, c in ipairs(list) do
		out[i] = { across = c.a, depth = c.d, mark = c.turn and (c.turn < n and "s" or c.how) or nil }
	end
	return out
end

-- The score sheet's rows, a turn each (the turn waiting for its first throw left out).
function record.rows(r)
	local prefix = notation.fileIds(r.teams)
	local out = {}
	for i, t in ipairs(writtenTurns(r)) do
		local line, pos = turnText(r, t, prefix)
		local k = { I = 0, R = 0, P = 0, Y = 0, Q = 0, N = 0, E = false }
		for _, key in ipairs(t.inkOrder) do
			for c, v in pairs(t.ink[key]) do
				if c == "E" then k.E = k.E or v else k[c] = k[c] + v end
			end
		end
		local batons = {}
		for j, b in ipairs(t.batons) do batons[j] = { token = b.token, by = b.by, stance = b.stance } end
		out[i] = { turn = t.n, side = t.side, line = line, lines = pos, inkastRecorded = not t.unrecorded,
			inkast = k, advantage = t.advantage, batons = batons, notes = t.notes, capture = copy(t.capture) }
	end
	return out
end

-- The state a scorer's screen needs. docs/RECORD.md "State".
function record.state(r)
	local t = r.cur
	local s = {
		format = record.FORMAT, engine = tw.engine and tw.engine.version or nil,
		turn = t and t.n or #r.turns, phase = r.phase, over = r.phase == "over",
		winner = r.winner, how = r.how, events = r.events,
		capture = copy(r.capture), king = r.phase == "over" and (r.how == "king" or r.how == "king toppled early"
			or r.how == "king toppled by a thrown kubb") and "down" or "standing",
		sides = {},
	}
	for _, side in ipairs { "A", "B" } do
		local ps = {}
		local prefix, header = notation.fileIds(r.teams)
		for i, p in ipairs(r.teams[side].players) do ps[i] = { id = p.id, name = p.name, file = header[p.id] } end
		local n = t and t.n or 0
		s.sides[side] = {
			name = r.teams[side].name, players = ps,
			base = r.base[side], field = r.field[side],
			fieldPositions = cellsOut(r.pos[side], n),
			fieldComplete = #r.pos[side] == r.field[side],
			basePositions = cellsOut(r.baseKnown[side] and r.basePos[side] or {}, n),
			baseComplete = r.baseKnown[side],
		}
	end
	if t and r.phase ~= "over" then
		local def = other(t.side)
		s.attacker, s.defender = t.side, def
		s.inkast = { due = t.due, rethrows = t.rethrows, left = t.due + t.rethrows, dueAtStart = t.dueStart,
			punish = t.P, punishPlaced = t.placedP, rescuable = t.rescuable }
		local thrown = #t.batons
		s.batons = { total = t.batonsTotal, thrown = thrown, left = t.batonsTotal - thrown }
		s.advantage = { applies = t.advantage, observed = t.observed, meters = t.meters }
		local by = {}
		for _, p in ipairs(r.teams[t.side].players) do by[#by + 1] = { id = p.id, batons = 0 } end
		for _, b in ipairs(t.batons) do
			if b.by then for _, x in ipairs(by) do if x.id == b.by then x.batons = x.batons + 1 end end end
		end
		local np = #r.teams[t.side].players
		s.throwers = { batons = by, cap = order.cap(np, t.batonsTotal), distinct = order.distinct(np, t.batonsTotal) }
		if r.phase == "inkast" then
			s.next = { kind = "toss", rethrow = t.due == 0, left = t.due + t.rethrows }
			s.allowed = { "toss", "pitch", "advantage", "baton", "resign", "call", "capture", "note" }
		else
			local standing = r.field[def] + r.base[def]
			s.next = { kind = "baton", n = thrown + 1, of = t.batonsTotal, kingShot = standing == 0,
				targets = r.field[def] > 0 and "field" or (r.base[def] > 0 and "base" or "king"),
				field = r.field[def], base = r.base[def] }
			s.allowed = { "baton", "pitch", "advantage", "resign", "call", "capture", "note" }
			if thrown == 0 and t.placedP < t.P then table.insert(s.allowed, 2, "punish") end
		end
		if r.phase == "inkast" and t.placedP < t.P then table.insert(s.allowed, 2, "punish") end
	else
		s.next = { kind = "over", winner = r.winner, how = r.how }
		s.allowed = { "capture" }
	end
	return s
end

tw.record = record
