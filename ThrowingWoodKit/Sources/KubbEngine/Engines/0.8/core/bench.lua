-- The physics benchmark (DESIGN 5): one fixed scenario, a baton thrown into a
-- tight group of five kubbs, stepped for 3 simulated seconds whether or not
-- everything has come to rest. `make bench` runs it on the desktop
-- (tools/bench.lua) and the System Menu "Bench" item runs the very same
-- function on the device; only the clock differs.
import "core/tw"
import "core/world"
import "core/quat"
import "core/autothrow"
import "core/drill"
import "core/match"

local world, quat = tw.world, tw.quat

local bench = {}

bench.seconds = 3
-- five field kubbs standing close together around (0, 4.3), turned a little
bench.pieces = {
	{ id = "b1", kind = "kubb", x = 0.00, y = 4.20, yaw = 0.0 },
	{ id = "b2", kind = "kubb", x = 0.10, y = 4.30, yaw = 0.3 },
	{ id = "b3", kind = "kubb", x = -0.10, y = 4.32, yaw = -0.2 },
	{ id = "b4", kind = "kubb", x = 0.03, y = 4.42, yaw = 0.6 },
	{ id = "b5", kind = "kubb", x = -0.06, y = 4.52, yaw = 0.1 },
}
-- from the baseline center, straight up the pitch, 35 degrees of loft,
-- end over end at 7 rad/s; 6.11 m/s carries it through the air's drag as
-- far as 6.0 did with none (before 2026-11-16), into the same group
bench.throw = { x = 0, lineY = 0, swivel = 0, loft = 35, speed = 6.11, tumble = 7, tilt = 0 }

-- A match's worst case for the bodies a throw starts with (docs/notes/match.md
-- "Match"): six batons and ten kubbs lying on the pitch from earlier throws
-- of the turn, already down and asleep, away from the scenario's throw
-- except two batons and a kubb just behind the group (the throw may reach
-- them). bench.run(..., true) adds them.
local function lying(id, kind, x, y, yaw)
	local tw_, tx, ty, tz = quat.fromAxisAngle(1, 0, 0, -math.pi / 2)   -- long axis along +y, a face down
	local zw, zx, zy, zz = quat.fromAxisAngle(0, 0, 1, yaw - math.pi / 2)
	local qw, qx, qy, qz = quat.mul(zw, zx, zy, zz, tw_, tx, ty, tz)
	return { id = id, kind = kind, x = x, y = y, qw = qw, qx = qx, qy = qy, qz = qz, toppled = true }
end
bench.debris = {
	lying("baton1", "baton", -0.15, 4.75, 0.4),
	lying("baton2", "baton", 0.20, 4.85, 1.9),
	lying("baton3", "baton", 1.40, 5.60, 0.2),
	lying("baton4", "baton", -1.30, 6.10, 2.8),
	lying("baton5", "baton", 0.80, 7.30, 1.2),
	lying("baton6", "baton", -0.60, 7.70, 0.7),
	lying("d1", "kubb", 0.05, 4.95, 0.1),
	lying("d2", "kubb", -1.80, 5.20, 1.5),
	lying("d3", "kubb", 1.90, 5.40, 0.3),
	lying("d4", "kubb", -1.00, 6.60, 2.2),
	lying("d5", "kubb", 1.10, 6.80, 0.9),
	lying("d6", "kubb", -2.00, 7.95, 0.0),
	lying("d7", "kubb", -1.00, 8.10, 1.6),
	lying("d8", "kubb", 0.00, 7.85, 0.2),
	lying("d9", "kubb", 1.00, 8.05, 1.4),
	lying("d10", "kubb", 2.00, 7.90, 3.0),
}

-- The match case (the device autobench's "match" lines): a turn in progress
-- as the owner plays it, in the view frame. Base kubbs and the king, two
-- standing field kubbs, and the turn's debris (three lying batons, three
-- downed kubbs). bench.matchSetup(projectile) gives a core/match-style setup
-- for scenes/throw (throw.prepare); bench.matchThrows are the throws played
-- in it, each from that same setup: a baton that hits a field kubb, a baton
-- that misses and rolls on through the debris, and a drilled kubb. They are
-- fixed launches (no scatter): the same throws on every run.
local function standing(id, kind, x, y, yaw)
	local qw, qx, qy, qz = quat.fromAxisAngle(0, 0, 1, yaw or 0)
	return { id = id, kind = kind, x = x, y = y, qw = qw, qx = qx, qy = qy, qz = qz, toppled = false }
end
function bench.matchSetup(projectile)
	local pieces = {}
	for i, x in ipairs { -2, -1, 0, 1, 2 } do pieces[i] = standing("b" .. i, "kubb", x, 8, 0) end
	pieces[#pieces + 1] = standing("f1", "kubb", 0.8, 5.0, 0.2)
	pieces[#pieces + 1] = standing("f2", "kubb", -0.9, 5.6, -0.3)
	pieces[#pieces + 1] = standing("king", "king", 0, 4, 0)
	local debris = {
		lying("baton1", "baton", 0.35, 5.95, 0.4),
		lying("baton2", "baton", -1.6, 6.9, 1.9),
		lying("baton3", "baton", 1.5, 7.0, 0.2),
		lying("d1", "kubb", 1.1, 5.35, 0.3),
		lying("d2", "kubb", -0.2, 7.3, 1.2),
		lying("d3", "kubb", 1.8, 6.2, 2.2),
	}
	for _, p in ipairs(debris) do
		-- resting on the ground: the half side of the lying box or the baton's radius
		p.z = (p.kind == "baton") and 0.022 or 0.035
	end
	local kubb = projectile == "kubb"
	return {
		kind = kubb and "toss" or "baton", side = "A", projectile = projectile or "baton",
		kubb = kubb and "f3" or nil, batonId = (not kubb) and "baton4" or nil,
		pieces = pieces, debris = debris, lineY = 0, forwardY = 0,
		targets = { "f1", "f2" }, label = "bench",
	}
end
-- core/autothrow-style throws ({x, y, swivel, loftDeg, speed, tumbleRate,
-- tilt, legal}; a drill has drill = {markerX, markerY}: thrown at the band's
-- center, clean). `aim` = {tx, ty}: where the launch is aimed (the speed that
-- lands the center there at this loft); filled in by bench.matchThrow.
bench.matchThrows = {
	{ name = "hit", projectile = "baton", x = 0.8, aim = { 0.8, 4.85 }, loftDeg = 30, tumbleRate = 5.5 },
	{ name = "miss", projectile = "baton", x = -1.0, aim = { -1.25, 6.2 }, loftDeg = 30, tumbleRate = 5.5 },
	-- (the marker moved from (0.3, 6.4) on 2026-11-16: a drill aimed short of it for its
	-- run on lands on baton1 there)
	{ name = "drill", projectile = "kubb", drill = { markerX = -0.5, markerY = 6.4 } },
}
function bench.matchThrow(t)
	local a = { x = t.x or 0, y = 0, swivel = 0, loftDeg = t.loftDeg or 30, speed = 0,
		tumbleRate = t.tumbleRate or 0, tilt = 0, legal = true, drill = t.drill }
	if t.aim then
		local dx, dy = t.aim[1] - a.x, t.aim[2] - a.y
		a.swivel = math.atan(dx, dy)
		a.speed = tw.autothrow.speedFor(math.sqrt(dx * dx + dy * dy), a.loftDeg)
	end
	return a
end

function bench.world(withDebris)
	local pieces = bench.pieces
	if withDebris then
		pieces = {}
		for i, p in ipairs(bench.pieces) do pieces[i] = p end
		for _, p in ipairs(bench.debris) do pieces[#pieces + 1] = p end
	end
	local w = world.new{ surface = "grass", pieces = pieces }
	local t = bench.throw
	world.launchBaton(w, t.x, t.lineY, t.swivel, t.loft, t.speed, t.tumble, t.tilt)
	return w
end

-- Bodies that were ever awake (the projectile included).
local function woke(w)
	local n = 0
	for i = 1, w.n do if w.bodies[i].everAwake then n = n + 1 end end
	return n
end

-- Run the scenario. clock() returns seconds. If `chunk` is given, `yield`
-- is called every `chunk` steps (the device redraws a progress line there;
-- the time spent in yield is not counted). withDebris adds bench.debris.
-- Returns a result table.
function bench.run(clock, chunk, yield, withDebris)
	local w = bench.world(withDebris)
	local steps = math.floor(bench.seconds / world.tune.dt + 0.5)
	local busy, maxAwake, maxContacts = 0, 0, 0
	-- the collision phase: steps with two or more bodies awake (timed one by one)
	local hotSteps, hotTime = 0, 0
	local done = 0
	while done < steps do
		local n = chunk and math.min(chunk, steps - done) or (steps - done)
		local t0 = clock()
		local ts = t0
		for _ = 1, n do
			world.step(w)
			local te = clock()
			if w.awakeCount >= 2 then hotSteps, hotTime = hotSteps + 1, hotTime + (te - ts) end
			ts = te
			if w.awakeCount > maxAwake then maxAwake = w.awakeCount end
			if w.contacts > maxContacts then maxContacts = w.contacts end
		end
		busy = busy + (ts - t0)
		done = done + n
		if yield then yield(done, steps) end
	end
	local r = world.result(w)
	return {
		steps = steps,
		simSeconds = steps * world.tune.dt,
		seconds = busy,
		msPerStep = busy * 1000 / steps,
		stepsPerSecond = steps / busy,
		msPerSimSecond = busy * 1000 / (steps * world.tune.dt),
		hotSteps = hotSteps,
		hotMsPerStep = hotSteps > 0 and hotTime * 1000 / hotSteps or 0,
		maxAwake = maxAwake,
		maxContacts = maxContacts,
		toppled = #r.toppled,
		touched = #r.touched,
		bodies = w.n,
		woke = woke(w),
	}
end

-- The scenario again with world.prof on: ms per step of each phase of
-- world.step, separately for the collision phase (2+ bodies awake) and the
-- rest. Returns lines of text. yield(done, steps) as in bench.run.
function bench.profile(clock, chunk, yield)
	local w = bench.world()
	local steps = math.floor(bench.seconds / world.tune.dt + 0.5)
	local P = world.newProf(clock)
	local hot, cold = world.newProf(clock), world.newProf(clock)
	local nh, nc = 0, 0
	local phases = world.PHASES
	world.prof = P
	for s = 1, steps do
		for _, k in ipairs(phases) do P[k] = 0 end
		P.narrow = 0
		world.step(w)
		local acc = (w.awakeCount >= 2) and hot or cold
		if acc == hot then nh = nh + 1 else nc = nc + 1 end
		for _, k in ipairs(phases) do acc[k] = acc[k] + P[k] end
		acc.narrow = acc.narrow + P.narrow
		acc.contacts = (acc.contacts or 0) + w.contacts
		if yield and s % (chunk or 24) == 0 then
			world.prof = nil
			yield(s, steps)
			world.prof = P
		end
	end
	world.prof = nil
	local lines = {}
	for _, row in ipairs { { "collision", hot, nh }, { "other", cold, nc } } do
		local acc, n = row[2], row[3]
		if n > 0 then
			local sum = 0
			local parts = {}
			for _, k in ipairs(phases) do
				sum = sum + acc[k]
				parts[#parts + 1] = string.format("%s %.3f", k, acc[k] * 1000 / n)
			end
			lines[#lines + 1] = string.format("  %s steps %d: %.3f ms/step (narrowphase pairs %.1f, contacts %.1f per step)",
				row[1], n, sum * 1000 / n, acc.narrow / n, (acc.contacts or 0) / n)
			lines[#lines + 1] = "    " .. table.concat(parts, ", ")
		end
	end
	return lines
end

-- The match case's throws (bench.matchThrows) stepped to rest with nothing
-- drawn: ms per step for each kind of step (lone: taken by world.loneFlight;
-- air: one body awake and no contact; ground: one body awake touching
-- something; multi: two or more awake). Returns one line of text. The device
-- runs it with world.loneFlight off and on.
function bench.matchPhysics(clock, yield)
	local acc = { lone = { 0, 0 }, air = { 0, 0 }, ground = { 0, 0 }, multi = { 0, 0 } }
	local steps, busy = 0, 0
	for _, t in ipairs(bench.matchThrows) do
		local s = bench.matchSetup(t.projectile)
		local w = world.new { surface = "grass", pieces = tw.match.worldPieces(s) }
		local a = bench.matchThrow(t)
		if a.drill then
			local drill = tw.drill
			local sol = drill.solve(a.drill.markerX, a.drill.markerY, 0, {})
			local L = drill.launch(sol, { power = sol.band, smoothness = 1, tilt = 0 }, 0, {})
			world.launchDrill(w, s.kubb, sol.x, 0, L.swivel, L.loft, L.speed, L.noseDown, L.rollLand, L.spin,
				L.wobble)
		else
			world.launchBaton(w, a.x, a.y, a.swivel, a.loftDeg, a.speed, a.tumbleRate, a.tilt, s.batonId)
		end
		while not world.isAtRest(w) do
			local t0 = clock()
			world.step(w)
			local dt = clock() - t0
			local c
			if w.loneStep == w.steps then c = "lone"
			elseif w.awakeCount >= 2 then c = "multi"
			elseif w.contacts > 0 then c = "ground"
			else c = "air" end
			local A = acc[c]
			A[1], A[2] = A[1] + 1, A[2] + dt
			steps, busy = steps + 1, busy + dt
			if yield and steps % 24 == 0 then yield() end
		end
	end
	local parts = {}
	for _, c in ipairs { "lone", "air", "ground", "multi" } do
		local A = acc[c]
		parts[#parts + 1] = string.format("%s %d at %.3f", c, A[1], A[1] > 0 and A[2] * 1000 / A[1] or 0)
	end
	return string.format("match physics (lone flight %s): %d steps, %.3f ms/step; %s",
		world.loneFlight and "on" or "off", steps, busy * 1000 / steps, table.concat(parts, ", "))
end

-- One line of text for the result (the device appends it to bench.txt).
function bench.line(r, where)
	return string.format("%s: %d steps (%.1f s simulated) in %.3f s; %.3f ms/step; %.0f steps/s; %.1f ms per simulated s; %.1f steps per 20 ms frame; collision phase %d steps at %.3f ms/step (%.1f per 20 ms frame); awake max %d, contacts max %d; toppled %d",
		where or "bench", r.steps, r.simSeconds, r.seconds, r.msPerStep, r.stepsPerSecond, r.msPerSimSecond,
		20 / r.msPerStep, r.hotSteps, r.hotMsPerStep, r.hotMsPerStep > 0 and 20 / r.hotMsPerStep or 0,
		r.maxAwake, r.maxContacts, r.toppled) .. string.format("; bodies %d, woke %d", r.bodies, r.woke)
end

tw.bench = bench
