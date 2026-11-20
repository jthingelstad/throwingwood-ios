-- A match in progress as plain data, and back (resume). Pure: no playdate.*.
--
-- core/match's table `m` is plain tables but for two metatables, the engine
-- game's (rules.Game) and its score sheet's (notation.Sheet), and the
-- current throw's setup, which match.setup builds again from the engine.
-- save.pack copies what a resume needs into tables of numbers, strings and
-- booleans only (as playdate.datastore writes JSON); save.unpack gives a
-- match table again with the metatables put back. A table met twice, a
-- function or a table with both list and named keys is an error: JSON could
-- not keep it.
import "core/tw"
import "core/rules"
import "core/notation"

local rules, notation = tw.rules, tw.notation

local save = {}

-- 2: teams of several players, with the throwing order and the lineup
-- (docs/PLAYERS.md); a version 1 save is not resumed (Jamie, 2026-11-15)
save.version = 2

local function plain(v, seen, path)
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" or t == "nil" then return v end
	if t ~= "table" then error("save: a " .. t .. " at " .. path) end
	if seen[v] then error("save: a table met twice at " .. path) end
	seen[v] = true
	local n, keys = #v, 0
	for _ in pairs(v) do keys = keys + 1 end
	local out = {}
	if n > 0 then
		if keys ~= n then error("save: a list with named keys at " .. path) end
		for i = 1, n do out[i] = plain(v[i], seen, path .. "[" .. i .. "]") end
	else
		for k, x in pairs(v) do
			if type(k) ~= "string" then error("save: a " .. type(k) .. " key at " .. path) end
			out[k] = plain(x, seen, path .. "." .. k)
		end
	end
	return out
end
save.plain = function(v) return plain(v, {}, "") end

-- Hands writer(d) what a resume needs of match `m`, plus `opts` (the match
-- scene's options: names, teams, vs, autoSettle, wind, and set when the caller has one:
-- since 0.9 the Playdate chooses no kubb set, and a save from before keeps the one it
-- had; the surface and opening are the engine's own) and autoRaise: true when the
-- player switched raising to automatic for the rest of the match (a match that raises
-- by hand, MENU Raising or REST OF GAME), absent when raising by hand. The client sets
-- it on its options mid-match, as it changes, and the next write keeps it, so a resumed
-- match goes on raising as it was. It records who raises, nothing more: what a raise
-- does is the same either way, and the session's snapshot (save.pack with no options)
-- never holds it, so no hash moves): the live tables, not a copy (copying the game
-- cost 43 ms on the device at turn 4), so writer must write it at once
-- (playdate.datastore.write). The score sheet's current turn is also its
-- last entry in turns, the one table the engine reaches two ways: it is
-- detached for the write and kept as an index.
function save.write(m, opts, writer)
	local sheet = m.game.sheet
	local cur, ci = sheet and sheet.current, nil
	if cur then
		for i, t in ipairs(sheet.turns) do if t == cur then ci = i end end
		sheet.current = nil
	end
	local ok, err = pcall(writer, {
		v = save.version, currentIndex = ci,
		game = m.game, start = m.start, mode = m.mode, turn = m.turn, tossed = m.tossed,
		text = m.text, debris = m.debris, order = m.order, lineup = m.lineup,
		opts = { vs = opts and opts.vs, names = opts and opts.names, teams = opts and opts.teams,
			autoSettle = opts and opts.autoSettle or nil,   -- the match options' raising
			set = opts and opts.set or nil,                 -- kubb set (older saves)
			wind = opts and opts.wind or nil,               -- and wind
			autoRaise = opts and opts.autoRaise and true or nil },  -- raising: automatic from here
	})
	if sheet then sheet.current = cur end
	if not ok then error(err, 0) end
end

-- A plain copy of what save.write would write (tests; save.plain refuses
-- anything JSON could not keep).
function save.pack(m, opts)
	local d
	save.write(m, opts, function(t) d = save.plain(t) end)
	return d
end

-- The match table again (and the options), or nil and why.
function save.unpack(d)
	if type(d) ~= "table" or d.v ~= save.version or type(d.game) ~= "table" then
		return nil, "not a saved match of this version"
	end
	local g = setmetatable(d.game, rules.Game)
	local sheet = g.sheet
	if sheet then
		setmetatable(sheet, notation.Sheet)
		local ci = d.currentIndex or sheet.currentIndex
		if ci then sheet.current = sheet.turns[ci] end
		sheet.currentIndex = nil
	end
	local m = { game = g, start = d.start, mode = d.mode, turn = d.turn, tossed = d.tossed, text = d.text,
		settled = nil, setup = nil, debris = d.debris, order = d.order, lineup = d.lineup }
	return m, d.opts or {}
end

tw.save = save
