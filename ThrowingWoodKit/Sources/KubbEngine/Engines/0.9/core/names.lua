-- Team names as typed (the Names board: "UP TO 10 LETTERS"). Pure: no
-- playdate.*.
--
-- A name keeps letters, spaces, hyphens and apostrophes, at most names.max
-- characters, with no leading space and no doubled spaces. It needs one
-- letter to count. The game file's id for it is notation.baseId.
import "core/tw"
import "core/notation"

local notation = tw.notation

local names = {}

names.max = 10
names.defaults = { A = "Team A", B = "Team B", you = "You" }

-- The text as a name may be: unwanted characters dropped, spaces tidied,
-- cut to names.max.
function names.clean(s)
	s = (s or ""):gsub("[^%a%s%-']", ""):gsub("%s+", " "):gsub("^ ", "")
	if #s > names.max then s = s:sub(1, names.max) end
	return s
end

-- A finished name: cleaned, trailing space dropped; nil when it has no letter.
function names.finish(s)
	s = names.clean(s):gsub(" $", "")
	if not s:find("%a") then return nil end
	return s
end

-- The game file id the name will have (before a clash with the other team's
-- adds "_b").
function names.id(s)
	return notation.baseId(s)
end

-- The engine's teams for a match: one player per team, named as the team.
-- list = { A = name, B = name }.
function names.teams(list)
	return {
		A = { name = list.A, players = { { name = list.A } } },
		B = { name = list.B, players = { { name = list.B } } },
	}
end

tw.names = names
