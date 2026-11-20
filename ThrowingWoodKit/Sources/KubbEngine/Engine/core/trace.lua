-- Crank traces: one recorded swing per line of traces.jsonl. Pure Lua: no
-- playdate.*, so the game writes lines with trace.encode and desktop tools
-- read them back with trace.decode and replay them with core/swing.
--
-- A line is one JSON object:
--   {"v":1,"time":"2026-11-20 19:42:07","sign":-1,"release":"clock",
--    "event":"release","samples":[[0.02,4.5],[0.02,6.1],...],
--    "result":{"back":118,"releaseAngle":88.5,"flickDps":940,"flickFrac":0.94,
--              "smoothness":0.88,"shake":0.12,"pull":1,"how":"stopped",
--              "frames":6,"loft":32,"distance":8.41}}
-- samples are [dt seconds, raw getCrankChange degrees] per frame, from the
-- first frame of the wind-up to the frame of the release or let-down. "sign"
-- is swing.tune.forwardSign at the time. "result" is absent for a let-down.
-- Its first fields are what core/swing measured (the crank as a clock,
-- 2026-11-15; meanings at swing.lua's release()): back, releaseAngle,
-- flickDps, flickFrac, smoothness, shake, pull, how ("stopped" or "sky"),
-- frames. The game adds the throw's plan and what it made of the swing
-- (docs/notes/throw.md "The throw", 2026-11-15), y measured from the thrower's line:
--   "level"       the throw level (beginner, club, pro)
--   "projectile"  "baton" or "kubb" (a drilled kubb)
--   "drillId"     the practice drill's id in a drill run (8m, doubles, wall, ...)
--   "tx","ty"     the target circle; "px","py" the stance
--   "plan"        the planned release (clock degrees); "loft" its launch angle
--   "powerLo","powerHi","releaseLo","releaseHi"   the clock's targets
--   "planTilt"    a baton's planned tilt (degrees); "spin" a kubb's (taps; since 0.9
--                 any value in range, so a fraction is written like any number here, to
--                 six significant digits)
--   "launchSpeed","launchLoft","swivelOff"   the launch (m/s, degrees, degrees
--                 off the plan's swivel: the shake's pull and the nerves);
--                 "tumbleRate", "tilt"
--   "legal"       false for a helicopter
--   "powerV","releaseV"   -1, 0, 1: short / on / long, low / on / high;
--                 "steady" true or false
--   "sideDeg","lenShare"   the nerves (2026-11-16, tw.plan.launch): degrees
--                 off the line (+ right) and the share long (+) or short;
--                 "sideV","lenV" -1, 0, 1: pulled left / straight / pulled
--                 right, short / on / long
--   "distance"    m from the release to the first touch
--
-- "release" says which swing wrote the line: "clock" for the crank as a
-- clock; "stop" (2026-11-14) for the release where the crank stopped against
-- the loft's notch; absent before that (released as the arm passed the
-- bottom). Older results carry that swing's fields (power, powerCap,
-- backswing, releaseSpeed, peakSpeed, tilt, legal, launchSpeed, tumbleRate,
-- launchLoft, how "passed", "slowed", "stopped" or "over"). Every line
-- decodes, and trace.replay runs any line's samples through today's swing.
--
-- A drilled kubb adds, after those, "mode":"drill" (a baton line has no
-- "mode") and, in meters with y measured from the thrower's baseline and x
-- across in the thrower's view:
--   "markerX","markerY"   the target circle (as tx, ty)
--   "landX","landY"       where the kubb first touched anything
--   "restX","restY"       where it came to rest
--   "throwerX"            where the thrower stood on the baseline
-- Lines from 2026-11-14 also carry "band", "verdict" and "cut" (the drill's
-- power band and A or B held for a cut), which today's throw has not.
import "core/tw"
import "core/swing"

local concat, fmt = table.concat, string.format

local trace = {}

local RESULT_KEYS = {
	-- what core/swing measured
	"back", "releaseAngle", "flickDps", "flickFrac", "smoothness", "shake", "pull", "how", "frames",
	-- the plan (added by the game)
	"level", "projectile", "drillId", "tx", "ty", "px", "py", "plan", "loft",
	"powerLo", "powerHi", "releaseLo", "releaseHi", "planTilt", "spin",
	-- what the throw made of it
	"launchSpeed", "launchLoft", "swivelOff", "tumbleRate", "tilt", "legal", "powerV", "releaseV", "steady",
	-- the nerves (core/throwplan "Nerves", 2026-11-16)
	"sideDeg", "lenShare", "sideV", "lenV",
	"distance",
	-- older lines' (the swing before 2026-11-15)
	"power",
	-- drills only (absent on a baton line)
	"mode", "band", "verdict", "cut", "markerX", "markerY", "landX", "landY", "restX", "restY", "throwerX",
}

local function num(v)
	if v ~= v or v == math.huge or v == -math.huge then return "0" end
	if math.type and math.type(v) == "integer" then return tostring(v) end
	return fmt("%.6g", v)
end

local function value(v)
	local ty = type(v)
	if ty == "number" then return num(v)
	elseif ty == "boolean" then return v and "true" or "false"
	elseif ty == "string" then return '"' .. v:gsub('[%c"\\]', "") .. '"'
	end
	return "null"
end

-- samples: flat {dt1, d1, dt2, d2, ...} with n pairs. result may be nil.
function trace.encode(samples, n, event, result, sign, time)
	local parts = {}
	for i = 1, n do
		parts[i] = "[" .. num(samples[2 * i - 1]) .. "," .. num(samples[2 * i]) .. "]"
	end
	-- every line written now comes from the crank as a clock, let-downs too
	local out = '{"v":1,"time":' .. value(time or "") .. ',"sign":' .. num(sign or 1)
		.. ',"release":"clock","input":"crank","event":' .. value(event or "") .. ',"samples":[' .. concat(parts, ",") .. "]"
	if result then
		local r = {}
		for _, k in ipairs(RESULT_KEYS) do
			if result[k] ~= nil then r[#r + 1] = '"' .. k .. '":' .. value(result[k]) end
		end
		out = out .. ',"result":{' .. concat(r, ",") .. "}"
	end
	return out .. "}"
end

-- A small JSON reader: objects, arrays, numbers, strings without escapes
-- beyond \" and \\, true, false, null. Enough for trace lines.
local function decoder(s)
	local i = 1
	local function ws() i = s:find("[^ \t\r\n]", i) or (#s + 1) end
	local parseValue
	local function parseString()
		local j = i + 1
		local buf = {}
		while true do
			local c = s:sub(j, j)
			if c == "" then error("unterminated string") end
			if c == '"' then break end
			if c == "\\" then j = j + 1; c = s:sub(j, j) end
			buf[#buf + 1] = c
			j = j + 1
		end
		i = j + 1
		return concat(buf)
	end
	function parseValue()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			i = i + 1
			local o = {}
			ws()
			if s:sub(i, i) == "}" then i = i + 1; return o end
			while true do
				ws()
				local k = parseString()
				ws()
				assert(s:sub(i, i) == ":", "expected :")
				i = i + 1
				o[k] = parseValue()
				ws()
				c = s:sub(i, i)
				i = i + 1
				if c == "}" then return o end
				assert(c == ",", "expected , or }")
			end
		elseif c == "[" then
			i = i + 1
			local a = {}
			ws()
			if s:sub(i, i) == "]" then i = i + 1; return a end
			while true do
				a[#a + 1] = parseValue()
				ws()
				c = s:sub(i, i)
				i = i + 1
				if c == "]" then return a end
				assert(c == ",", "expected , or ]")
			end
		elseif c == '"' then
			return parseString()
		elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
		elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
		elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
		else
			local a, b = s:find("^-?[%d.]+[eE]?[-+]?%d*", i)
			assert(a, "bad JSON at " .. i)
			i = b + 1
			return tonumber(s:sub(a, b))
		end
	end
	return parseValue
end

function trace.decode(line)
	return decoder(line)()
end

-- Replay a decoded trace through the current swing model. Returns the event
-- and result as swing.replay does. By default the trace's own sign is kept,
-- so a trace recorded before forwardSign was flipped replays as it was
-- thrown; with useCurrentSign the raw deltas meet today's forwardSign. Every
-- line, whichever swing wrote it ("release"), is replayed through today's.
function trace.replay(t, useCurrentSign)
	local swing = tw.swing
	local flat = {}
	local flip = useCurrentSign and 1 or (t.sign or 1) * swing.tune.forwardSign
	for _, p in ipairs(t.samples or {}) do
		flat[#flat + 1] = p[1]
		flat[#flat + 1] = p[2] * flip
	end
	return swing.replay(flat)
end

tw.trace = trace
