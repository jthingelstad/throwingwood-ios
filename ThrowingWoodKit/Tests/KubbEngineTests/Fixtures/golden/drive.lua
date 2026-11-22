-- The golden driver (docs/DETERMINISM.md): matches played through the API's one
-- door, kubbCall, as a host would, with the hash after every action. Twelve are
-- computer against computer; the thirteenth (since 0.8.0) has a person's side
-- swinging on the dial at chosen distances, so the corpus covers a player's baton
-- planned under flight.tune.nearM, which the computer never throws. The fourteenth and
-- fifteenth (since 0.12.0) cover raising by side: a person raised automatically against
-- the pro computer, and the beginner computer both sides (the twelve are at club). Pure Lua: tests/golden/golden.mjs runs it under wasmoon (the reference)
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
	-- Team A a person, B the computer. A's batons at field kubbs are thrown from these
	-- distances in turn (0.35 to 1.9 m under flight.tune.nearM, 2.0 m its edge;
	-- personThrow).
	out[13] = {
		name = "m13-grass-off-A-near",
		opts = {
			mode = "match", cpu = "B", seed = 1013, surface = "grass", wind = "off",
			first = "A", start = START, maxTurns = 10,
		},
		near = { 0.35, 0.75, 1.25, 1.9, 2.0 },
	}
	-- Since 0.12.0, raising by side (core/match.raisePolicy): Team A a person whose kubbs
	-- the engine raises (RAISING: AUTOMATIC, so by the engine's advice, par) against the
	-- computer at pro (which raises par too), throwing as m13's person does. Seed 1027:
	-- each side has kubbs that par stands on another end than apart would ...
	out[14] = {
		name = "m14-grass-off-B-auto-pro",
		opts = {
			mode = "match", cpu = "B", computer = "pro", raising = "auto", seed = 1027,
			surface = "grass", wind = "off", first = "B", start = START, maxTurns = 10,
		},
		near = { 0.35, 0.75, 1.25, 1.9, 2.0 },
	}
	-- ... and the computer at beginner both sides, which stands its kubbs on the first end
	-- the rules list.
	out[15] = {
		name = "m15-sand-off-A-beginner",
		opts = {
			mode = "match", cpu = "both", computer = "beginner", seed = 1015,
			surface = "sand", wind = "off", first = "A", start = START, maxTurns = 6,
		},
	}
	return out
end

-- The arm angles of a swing as a pointer gives them, a frame each: back to `back`
-- degrees, a quick flick forward to `stop`, held there (tests/node/session.test.mjs).
local function swingArms(back, stop)
	local arms, a = { 0, -5 }, -5
	while a > -back do a = math.max(-back, a - 400 / 60); arms[#arms + 1] = a end
	while a < stop do a = math.min(stop, a + 2400 / 60); arms[#arms + 1] = a end
	for _ = 1, 6 do arms[#arms + 1] = stop end
	return arms
end

-- A baton at a field kubb from d metres short of it, as a scripted action: the
-- session clamps a person's circle to markerNear (3.5 m) out and the stance to the
-- advantage line, so a throw this short comes up in play only when a field kubb stands
-- just past that line. The launch is the core's own (plan.solve, plan.launch) for a
-- clean swing `over` bands past the middle of the power band, at the plan's release.
local plan = tw.plan
local function nearAction(match, need, aim, d, over)
	local m = aim.marker
	local px, py = m.x, m.y - d
	local sol = plan.solve({
		projectile = "baton", px = px, py = py, tx = m.x, ty = m.y,
		release = plan.arcFor("baton", d), level = aim.plan.level, surface = match.opts.surface, spin = 0,
		aimZ = plan.aimZFor("kubb"),
	}, {})
	local mid = (sol.powerLo + sol.powerHi) / 2
	local back = mid + over * (sol.powerHi - sol.powerLo)
	local L = plan.launch(sol, { back = back, releaseAngle = sol.release, flickFrac = 1, smoothness = 1,
		shake = 0, pull = 1, how = "stopped" }, { projectile = "baton", tilt = 0, spin = 0, level = aim.plan.level }, {})
	return {
		type = "throw", seq = need.throws, how = "baton",
		launch = { speed = L.speed, loft = L.loft, swivel = L.swivel, tilt = L.tilt or 0, tumble = L.tumble or 0,
			legal = L.legal ~= false },
		stance = { x = px, y = py, set = true },
		target = { x = m.x, y = m.y, set = true, on = m.on },
		scripted = true, swing = { back = back, stop = sol.release },
	}
end

-- A person's throw in match.near. A baton at a field kubb (the plan's own circle on
-- it) goes from the next of match.near's distances: on the band the first time round,
-- one band long the second (the overpower cost), then on the band again. Every other
-- throw is a swing on the dial at the middle of the plan's power band and its
-- release, sampled at 60 Hz whatever the match's frame time (the swing is the input,
-- so the corpus still does not depend on dt). Returns the action.
local function personThrow(match, need)
	local dt = 1 / 60
	local aim = call("aim").aim
	if need.setup.projectile == "baton" and aim.marker.kind == "field" then
		match.k = match.k + 1
		local n = #match.near
		local d = match.near[(match.k - 1) % n + 1]
		local a = nearAction(match, need, aim, d, ((match.k - 1) // n) % 2 == 1 and 1 or 0)
		call("apply", a)
		return a
	end
	local plan = aim.plan
	local f
	for _, arm in ipairs(swingArms((plan.powerLo + plan.powerHi) / 2, plan.release)) do
		f = call("frame", { dt = dt, arm = arm })
		if f.action then return f.action end
	end
	return call("frame", { dt = dt }).action -- let go: the release
end

-- dt: the frame time fed to frame (1/60 by default: what a 60 fps host gives).
function golden.play(match, dt)
	dt = dt or 1 / 60
	call("useTune", { name = "pointer" })
	call("new", match.opts)
	local res = { name = match.name, start = call("hash").hash, actions = {} }
	local frames = 0
	match.k = 0
	while true do
		local need = call("need")
		if need.kind == "over" then
			res.winner, res.turns = need.winner, need.turn
			break
		end
		local typ
		if need.kind == "throw" and not need.cpu and match.near then
			local a = personThrow(match, need)
			if not a then error(match.name .. ": the person's swing did not throw") end
			typ = a.type
		elseif need.kind == "raise" and not need.cpu and match.near then
			typ = "raise"; call("apply", { type = "raise" })
		elseif need.kind == "punish" and not need.cpu and match.near then
			typ = "punish"; call("apply", { type = "punish", x = need.cursor.x, y = need.cursor.y })
		else
			local f = call("frame", { dt = dt })
			frames = frames + 1
			if frames > 200000 then error(match.name .. ": no action in 200000 frames") end
			typ = f.action and f.action.type
		end
		if typ then
			res.actions[#res.actions + 1] = { type = typ, hash = call("hash").hash }
		end
	end
	return res
end

tw.golden = golden
