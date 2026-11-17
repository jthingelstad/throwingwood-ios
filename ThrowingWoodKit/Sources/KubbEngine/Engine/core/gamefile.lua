-- What the games list shows of a finished game file (DESIGN 7, the Games
-- board): its headers, turns, minutes, each team's baton hit rate and the
-- baton the king fell to. Pure: reads the file's text, no playdate.*.
import "core/tw"
import "core/cards"

local cards = tw.cards

local gamefile = {}

local MONTHS <const> = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }

-- An inkast token carries I or R (core/notation writes IRPQN in order).
local function isInkast(tok) return tok:find("[IR]") ~= nil end

-- The game's summary, or nil and why. Fields: headers (every [Key "Value"]),
-- a, b (team names), winner ("A" | "B" | nil), first ("A" | "B"), turns,
-- minutes, date ("NOV 20"), start (the header's text), mode, hits =
-- { A = { hits, thrown }, B = ... }, kingBaton (the baton of its turn the
-- king fell to, or nil), lines (the file's lines, for the score sheet).
function gamefile.parse(text)
	if type(text) ~= "string" then return nil, "no text" end
	local h, lines = {}, {}
	local hits = { A = { 0, 0 }, B = { 0, 0 } }
	local turns, kingBaton = 0, nil
	local first = nil
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
		local k, v = line:match('^%[([^"]-)%s+"(.*)"%]%s*$')
		if k then
			h[k] = v
		else
			local n, rest = line:match("^(%d+)%.%s+(.*)$")
			if n then
				n = tonumber(n)
				if n > turns then turns = n end
				first = first or ((h["First"] == "Team B") and "B" or "A")
				local side = (n % 2 == 1) and first or ((first == "A") and "B" or "A")
				local batons = 0
				-- a note (# ...) says what the tokens cannot: not throws
				rest = rest:gsub("%s*#.*$", "")
				-- comments in parentheses, positions "(@ 1.32,5.87)" among
				-- them, belong to the token before them: not tokens
				rest = rest:gsub("%b()", " ")
				for tok in rest:gmatch("%S+") do
					local t = tok:match("^[%w_]+:(.+)$") or tok
					if not t:match("^%d+A$") and not isInkast(t) then
						local _, _, hit, thrown = cards.batonCounts(t)
						if thrown then
							batons = batons + 1
							hits[side][2] = hits[side][2] + 1
							if hit then hits[side][1] = hits[side][1] + 1 end
							if t == "K" then kingBaton = batons end
						end
					end
				end
			end
		end
	end
	if not h["Team A"] or not h["Team B"] then return nil, "no teams" end
	local win = h["Win"]
	local s = { headers = h, a = h["Team A"], b = h["Team B"], first = first or "A", turns = turns,
		winner = (win == "Team A") and "A" or ((win == "Team B") and "B" or nil),
		start = h["Start"], mode = h["Mode"], hits = hits, kingBaton = kingBaton, lines = lines }
	-- players a team ("Kim (kim), Max (max)": a comma between each)
	s.players = {}
	for _, side in ipairs { "A", "B" } do
		local v = h["Team " .. side .. " Players"]
		local n = 0
		if v then for _ in v:gmatch("%(") do n = n + 1 end end
		s.players[side] = n
	end
	s.minutes = tonumber((h["Duration"] or ""):match("^(%d+)m")) or 0
	local _, mo, d = (h["Start"] or ""):match("^(%d+)-(%d+)-(%d+)")
	s.date = mo and (MONTHS[tonumber(mo)] .. " " .. tonumber(d)) or ""
	return s
end

-- A game file's line as the score sheet shows it on screen: without the
-- positions on the pitch (" (@ 4.39,4.61 4.34,5.21)"), which are for readers
-- that draw the pitch and would fill the 400 px screen. Other comments stay.
function gamefile.shown(line)
	return (line:gsub(" ?%(@[^()]*%)", ""))
end

-- A team's hit rate as a whole percent, or nil when it threw no batons.
function gamefile.rate(s, side)
	local r = s.hits[side]
	if r[2] == 0 then return nil end
	return math.floor(100 * r[1] / r[2] + 0.5)
end

tw.gamefile = gamefile
