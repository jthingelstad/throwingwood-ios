-- The golden driver (docs/DETERMINISM.md): computer-vs-computer matches played
-- through the API's one door, kubbCall, as a host would, with the hash after every
-- action. Pure Lua: tests/golden/golden.mjs runs it under wasmoon (the reference)
-- and tests/golden/native.lua under desktop Lua.
--
-- golden.matches(): the matches, seeded across surfaces, wind and the first team.
-- golden.play(match): { name, opts, start = hash, actions = { { type, hash }, ... },
-- winner, turns }.
import "core/tw"
import "session/api"
import "session/json"

local json = tw.web.json

local golden = {}

local function call(method, a)
	local text = kubbCall(method, a == nil and "" or json.encode(a))
	local r = json.decode(text)
	if type(r) == "table" and r.error then error(method .. ": " .. r.error, 2) end
	return r
end

local SURFACES = { "grass", "sand", "snow" }
local WINDS = { "off", "light", "strong" }
local START = { year = 2026, month = 11, day = 17, hour = 12, min = 0 }

-- Twelve matches: every surface with every wind, the first team alternating, and two
-- more seeds. maxTurns keeps each short enough for CI (the side to throw at that
-- turn resigns, which is an action too).
function golden.matches()
	local out = {}
	for i = 1, 12 do
		local opts = {
			mode = "match", cpu = "both", seed = 1000 + i,
			surface = SURFACES[(i - 1) % 3 + 1], wind = WINDS[((i - 1) // 3) % 3 + 1],
			first = (i % 2 == 1) and "A" or "B", start = START, maxTurns = 6,
		}
		out[i] = { name = string.format("m%02d-%s-%s-%s", i, opts.surface, opts.wind, opts.first), opts = opts }
	end
	return out
end

-- dt: the frame time fed to frame (1/60 by default: what a 60 fps host gives).
function golden.play(match, dt)
	dt = dt or 1 / 60
	call("useTune", { name = "pointer" })
	call("new", match.opts)
	local res = { name = match.name, start = call("hash").hash, actions = {} }
	local frames = 0
	while true do
		local need = call("need")
		if need.kind == "over" then
			res.winner, res.turns = need.winner, need.turn
			break
		end
		local f = call("frame", { dt = dt })
		frames = frames + 1
		if frames > 200000 then error(match.name .. ": no action in 200000 frames") end
		if f.action then
			res.actions[#res.actions + 1] = { type = f.action.type, hash = call("hash").hash }
		end
	end
	return res
end

tw.golden = golden
