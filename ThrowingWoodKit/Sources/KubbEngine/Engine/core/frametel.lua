-- Frame-time telemetry for one throw: was a slow picture the deliberate slow
-- motion (core/playback.speed) or frames the device dropped? Pure Lua: no
-- playdate.*. The throw scene keeps one table (frametel.new, made once) and
-- per flight frame calls frametel.frame: a few number fields change, nothing
-- is allocated. When the throw is at rest, frametel.encode makes the one
-- line that framelog.lua appends to frames.jsonl in the Data folder.
--
-- A line is one JSON object (under 300 bytes):
--   {"v":1,"time":"2026-11-20 19:42:07","scene":"match","proj":"baton",
--    "pre":[41,0.82,20.0,24.1],"slow":[52,1.07,20.6,38.2],"post":[30,0.61,20.3,22.0],
--    "starved":3,"stall":44.0,"awake":6,"contacts":27,"bodies":28,"steps":712,"phys":512.3}
-- pre, slow, post: the flight before the slow motion, in it (the picture
--   slower than real time), and after it; each [frames, real seconds, mean
--   frame dt ms, max frame dt ms]. A throw with no hit is all "pre".
-- starved: shown frames that had to wait for the physics (the show time was
--   clamped because the computed frames ran out); stall: the longest run of
--   such frames, ms of real time.
-- awake, contacts: the most bodies awake and contacts in any physics step;
--   bodies: bodies in the world (the six stakes included); steps: physics
--   steps; phys: ms the physics took in all (core/playback busy time).
import "core/tw"

local fmt = string.format

local frametel = {}

local PHASES = { "pre", "slow", "post" }
frametel.PHASES = PHASES

-- Clear for a new throw (all number fields: n/s/m per phase, 1..3).
function frametel.reset(t)
	t.n1, t.s1, t.m1 = 0, 0, 0
	t.n2, t.s2, t.m2 = 0, 0, 0
	t.n3, t.s3, t.m3 = 0, 0, 0
	t.phase = 1
	t.starved, t.run, t.stall = 0, 0, 0
	return t
end

function frametel.new() return frametel.reset({}) end

-- One shown flight frame: dt seconds of real time, the picture's speed
-- (playback.speed: below 1 is slow motion), and whether it was starved
-- (the show time clamped because the physics had not computed far enough).
function frametel.frame(t, dt, speed, starved)
	local ph = t.phase
	if speed < 1 then ph = 2
	elseif ph == 2 then ph = 3 end
	t.phase = ph
	if ph == 1 then
		t.n1, t.s1 = t.n1 + 1, t.s1 + dt
		if dt > t.m1 then t.m1 = dt end
	elseif ph == 2 then
		t.n2, t.s2 = t.n2 + 1, t.s2 + dt
		if dt > t.m2 then t.m2 = dt end
	else
		t.n3, t.s3 = t.n3 + 1, t.s3 + dt
		if dt > t.m3 then t.m3 = dt end
	end
	if starved then
		t.starved = t.starved + 1
		t.run = t.run + dt
		if t.run > t.stall then t.stall = t.run end
	else
		t.run = 0
	end
end

local function r1(v) return fmt("%.1f", v) end

local function phase(t, i)
	local n, s, m = t["n" .. i], t["s" .. i], t["m" .. i]
	return fmt("[%d,%.2f,%s,%s]", n, s, r1(n > 0 and s * 1000 / n or 0), r1(m * 1000))
end

local function str(v) return '"' .. tostring(v or ""):gsub('[%c"\\]', "") .. '"' end

-- The line (no newline). info: time (string), scene, proj, awake, contacts,
-- bodies, steps, phys (seconds of physics).
function frametel.encode(t, info)
	return '{"v":1,"time":' .. str(info.time) .. ',"scene":' .. str(info.scene) .. ',"proj":' .. str(info.proj)
		.. ',"pre":' .. phase(t, 1) .. ',"slow":' .. phase(t, 2) .. ',"post":' .. phase(t, 3)
		.. fmt(',"starved":%d,"stall":%s,"awake":%d,"contacts":%d,"bodies":%d,"steps":%d,"phys":%s}',
			t.starved, r1(t.stall * 1000), info.awake or 0, info.contacts or 0, info.bodies or 0,
			info.steps or 0, r1((info.phys or 0) * 1000))
end

tw.frametel = frametel
