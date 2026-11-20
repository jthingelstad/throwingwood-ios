-- Compute ahead and play back (DESIGN 5). The physics runs at a fixed step
-- (world.tune.dt) as far ahead of the screen as the frame budget allows and
-- records every body's pose every frameDt of simulated time. The scene shows
-- any time between two recorded frames (playback.poseAt interpolates), at a
-- speed playback.pace keeps steady: slower than real time when the physics
-- cannot keep up, so the picture slows smoothly instead of stopping and
-- starting. Pure Lua: the clock is passed in.
--
-- Storage: one flat number array per body, 7 numbers per frame
-- (x, y, z, qw, qx, qy, qz), starting at the first frame the body was awake.
-- Before that the body sits at its starting pose. A body woken late costs
-- nothing until then; a standing kubb nobody touches costs nothing at all.
--
--   local pb = playback.new(w, 1 / 50)
--   each frame: playback.advance(pb, budgetSeconds, clock)
--               if pb.frame < pb.frames then pb.frame = pb.frame + 1 end
--               playback.pose(pb, i, pb.frame) for each body index i
--   pb.done and pb.frame == pb.frames: the throw is over
import "core/tw"
import "core/world"

local world = tw.world
local sqrt, floor = math.sqrt, math.floor

local playback = {}

-- The calm: below these speeds (every awake body, m/s and rad/s) nothing on
-- screen visibly moves; the throw only waits for the sleep timer
-- (world.tune.sleepTime) or a last slow roll. pb.calmFrom is the first
-- frame of the calm stretch that runs to the newest recorded frame (nil when
-- the newest frame is not calm). The scene holds the picture there and
-- gives the physics the whole frame (scenes/throw).
playback.calm = { lin = 0.05, ang = 0.5 }

local function record(pb)
	local w = pb.w
	local f = pb.frames
	local calm = true
	local l2, a2 = pb.calmLin2, pb.calmAng2
	for i = 1, w.n do
		local b = w.bodies[i]
		local r = pb.rec[i]
		if not r then
			r = { start = -1, data = {}, x = b.x, y = b.y, z = b.z, qw = b.qw, qx = b.qx, qy = b.qy, qz = b.qz }
			pb.rec[i] = r
		end
		if r.start < 0 and b.everAwake then r.start = f end
		if r.start >= 0 then
			local d, k = r.data, (f - r.start) * 7
			d[k + 1], d[k + 2], d[k + 3] = b.x, b.y, b.z
			d[k + 4], d[k + 5], d[k + 6], d[k + 7] = b.qw, b.qx, b.qy, b.qz
			if calm and b.awake then
				local vx, vy, vz, wx, wy, wz = b.vx, b.vy, b.vz, b.wx, b.wy, b.wz
				if vx * vx + vy * vy + vz * vz > l2 or wx * wx + wy * wy + wz * wz > a2 then calm = false end
			end
		end
	end
	if not calm then pb.calmFrom = nil
	elseif not pb.calmFrom then pb.calmFrom = f end
end

-- A playback of world w (already built and launched) at frameDt per frame.
function playback.new(w, frameDt)
	local pb = {
		w = w,
		frameDt = frameDt,
		frames = 0,       -- last recorded frame (frame 0 is the start)
		frame = 0,        -- the frame on screen; the scene advances it
		done = false,     -- the world came to rest (or ran out of time)
		rec = {},
		steps = 0,        -- physics steps taken
		busy = 0,         -- seconds spent in advance()
		awakeMax = 0,     -- the most bodies awake in any step
		contactsMax = 0,  -- the most contacts in any step
		calmFrom = nil,   -- see playback.calm
		calmLin2 = playback.calm.lin * playback.calm.lin,
		calmAng2 = playback.calm.ang * playback.calm.ang,
		v = 0,            -- the pace (playback.pace)
	}
	record(pb)
	return pb
end

-- Step the world until `ahead` frames past the one on screen are recorded,
-- the world is at rest, or `budget` seconds of clock() have gone by.
-- Returns the number of steps taken.
function playback.advance(pb, budget, clock, ahead)
	if pb.done then return 0 end
	local w = pb.w
	local t0 = clock()
	local stop = t0 + budget
	local want = pb.frame + (ahead or 1000000)
	local n = 0
	local dt = world.tune.dt
	local last = t0
	while pb.frames < want do
		world.step(w)
		n = n + 1
		if w.awakeCount > pb.awakeMax then pb.awakeMax = w.awakeCount end
		if w.contacts > pb.contactsMax then pb.contactsMax = w.contacts end
		local rest = world.isAtRest(w)
		-- record each display frame this step reached (within half a step)
		while w.time + dt * 0.5 >= (pb.frames + 1) * pb.frameDt do
			pb.frames = pb.frames + 1
			record(pb)
		end
		if rest then
			pb.frames = pb.frames + 1
			record(pb)
			pb.done = true
			break
		end
		-- stop when the next step, as long as this one, would end more than
		-- half of it past the budget (a contact step costs several times a
		-- free flight's: stopping only once the budget was spent overran it by
		-- up to a whole step, stopping before any overrun wastes up to one)
		local now = clock()
		if now + (now - last) * 0.5 >= stop then break end
		last = now
	end
	pb.steps = pb.steps + n
	pb.busy = pb.busy + (clock() - t0)
	return n
end

-- Pose of body index i at frame f (clamped to what is recorded).
function playback.pose(pb, i, f)
	local r = pb.rec[i]
	if f > pb.frames then f = pb.frames end
	if r.start < 0 or f < r.start then
		return r.x, r.y, r.z, r.qw, r.qx, r.qy, r.qz
	end
	local d, k = r.data, (f - r.start) * 7
	return d[k + 1], d[k + 2], d[k + 3], d[k + 4], d[k + 5], d[k + 6], d[k + 7]
end

-- Pose of body index i at time t (s from the release; clamped to what is
-- recorded), between the two recorded frames around it: position linear,
-- rotation the normalized linear blend of the two quaternions (the frames
-- are 20 ms apart, so the difference from a true slerp is far below a pixel).
function playback.poseAt(pb, i, t)
	local u = t / pb.frameDt
	local f = floor(u)
	if f < 0 then f, u = 0, 0 end
	local r = pb.rec[i]
	local start = r.start
	if f >= pb.frames or start < 0 or f + 1 < start then return playback.pose(pb, i, f) end
	local a = u - f
	local d = r.data
	local x0, y0, z0, w0, i0, j0, k0
	if f < start then
		x0, y0, z0, w0, i0, j0, k0 = r.x, r.y, r.z, r.qw, r.qx, r.qy, r.qz
	else
		local k = (f - start) * 7
		x0, y0, z0, w0, i0, j0, k0 = d[k + 1], d[k + 2], d[k + 3], d[k + 4], d[k + 5], d[k + 6], d[k + 7]
	end
	if a <= 0 then return x0, y0, z0, w0, i0, j0, k0 end
	local k = (f + 1 - start) * 7
	local x1, y1, z1, w1, i1, j1, k1 = d[k + 1], d[k + 2], d[k + 3], d[k + 4], d[k + 5], d[k + 6], d[k + 7]
	if w0 * w1 + i0 * i1 + j0 * j1 + k0 * k1 < 0 then w1, i1, j1, k1 = -w1, -i1, -j1, -k1 end
	local qw, qx, qy, qz = w0 + (w1 - w0) * a, i0 + (i1 - i0) * a, j0 + (j1 - j0) * a, k0 + (k1 - k0) * a
	local n = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
	if n > 0 then n = 1 / n; qw, qx, qy, qz = qw * n, qx * n, qy * n, qz * n end
	return x0 + (x1 - x0) * a, y0 + (y1 - y0) * a, z0 + (z1 - z0) * a, qw, qx, qy, qz
end

-- The pace: how fast the picture plays (1 = real time) so that it never
-- catches up with the physics. It follows the simulated time computed ahead
-- of the screen: horizon seconds of it or more play in real time, less plays
-- slower in proportion (so the picture runs at the rate the physics makes
-- frames, and a frame budget that buys more steps fills the store up again).
-- The pace rises by at most rise per second and falls by at most fall per
-- second, so a change of speed is a smooth ease, never a jump; never below
-- floor. Once the throw is computed to rest it eases back to real time.
playback.paceTune = { horizon = 0.4, floor = 0.1, rise = 1.5, fall = 3.0 }

-- Advance the pace by dt seconds of real time with the picture at showTime;
-- returns the new pace (also kept in pb.v).
function playback.pace(pb, showTime, dt)
	local k = playback.paceTune
	local target = 1
	if not pb.done then
		target = (pb.frames * pb.frameDt - showTime) / k.horizon
		if target > 1 then target = 1 elseif target < k.floor then target = k.floor end
	end
	local v = pb.v
	if target > v then
		v = v + k.rise * dt
		if v > target then v = target end
	else
		v = v - k.fall * dt
		if v < target then v = target end
	end
	pb.v = v
	return v
end

-- Slow motion around a hit. Because the physics runs ahead of the screen,
-- the time of the first hit is known before it is shown. Returns the speed
-- of the picture (1 = real time) at screen time `t` for a hit at `hitTime`
-- (nil = no hit known): slowRate from `lead` seconds before the hit until
-- `hold` seconds after it, then easing back to 1 over `ease` seconds.
-- Jamie (2026-11-14): the slow motion is there for the impact, so it ends
-- right after it (it was hold 0.45, ease 0.35: it went on while the baton
-- slid to a stop and held the play up).
playback.slow = { rate = 0.3, lead = 0.10, hold = 0.12, ease = 0.15 }

function playback.speed(t, hitTime)
	if not hitTime then return 1 end
	local k = playback.slow
	local d = t - hitTime
	if d < -k.lead then return 1 end
	if d <= k.hold then return k.rate end
	local e = (d - k.hold) / k.ease
	if e >= 1 then return 1 end
	return k.rate + (1 - k.rate) * e
end

-- Run to the end without a clock (tests, the desktop).
function playback.finish(pb)
	while not pb.done do playback.advance(pb, math.huge, function() return 0 end) end
	return pb
end

-- Bytes of pose data held (8 per number; a rough figure for the readout).
function playback.size(pb)
	local n = 0
	for i = 1, #pb.rec do n = n + #pb.rec[i].data end
	return n * 8
end

tw.playback = playback
