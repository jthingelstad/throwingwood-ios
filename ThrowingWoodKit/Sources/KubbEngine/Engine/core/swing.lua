-- The crank swing: the crank as a clock (DESIGN.md section 4, "The throw: the
-- crank as a clock"). Pure Lua: no playdate.*.
--
-- The crank is the throwing arm. Read as a clock, 6 is the arm hanging
-- straight down; the backswing goes up the left side (7 .. 12) and the forward
-- swing up the right (5 .. 1). This module only measures the crank: how far
-- back it went, where it stopped going forward, how fast and how steadily the
-- flick was. What a throw makes of that (power, launch angle, error) is the
-- plan's (core/throwplan), not this file's.
--
-- Angles are "forward degrees from the bottom": the raw crank change times
-- tune.forwardSign, so forward is positive. On the backswing 7 o'clock is
-- -30, 9 is -90, 10 is -120, 12 is -180; forward 5 is +30, 3 is +90, 1 is
-- +150, 12 is +180.
--
-- Fed one sample per frame: swing.update(s, delta, dt), delta the crank change
-- in degrees as playdate.getCrankChange gives it (the sign is applied here),
-- dt the frame time in seconds. The throw scene feeds the crank while idle
-- only once it has crossed the bottom of the turn going back (armAngle,
-- crossedBack), and then only the part past the bottom, so the arm starts at 0.
--
--   idle      back motion moves the arm behind the bottom (s.pending; forward
--             motion takes it off again). Past startBackDeg (7 o'clock: 6 to 7
--             is a dead zone) -> winding.
--   winding   s.arm is the real crank, never capped; s.back the farthest back
--             it has been (capped at backswingMaxDeg). Forward slower than
--             swingStartDps lets the arm down: back past the bottom it is a
--             "letdown" (no throw) -> idle. Forward at swingStartDps or faster
--             -> swinging (that frame is the flick's first).
--   swinging  every frame's forward speed goes into s.speeds. The crank has
--             stopped when the forward speed (averaged over speedWindow
--             frames) falls below releaseStopDps: the throw leaves where the
--             arm got farthest forward (releaseAngle). Stopped at or short of
--             the bottom it is a "letdown"; past it, a "release" with
--             how = "stopped". An arm that passes skyDeg (12 o'clock forward)
--             before stopping is released at once, how = "sky".
--   cooldown  after a release, cooldownS of frame time in which every crank
--             change is ignored (the crank swinging back after a throw must
--             not start the next one) -> idle.
--
-- update returns nil, "letdown" or "release"; after a release s.result holds
-- what was measured (fields at release() below). s.back stays as it was until
-- the next wind-up so the dial can keep its dot.
--
-- Crank sign. getCrankChange is negative anti-clockwise. Tried on hardware
-- (2026-11-13): with forwardSign = 1 the wind-up and the throw felt swapped,
-- so the forward swing is the anti-clockwise direction: forwardSign = -1.
-- It is the one constant to flip; nothing else changes.
import "core/tw"

local abs = math.abs

local swing = {}

swing.tune = {
	forwardSign = -1,      -- -1: anti-clockwise (negative getCrankChange) is the forward swing
	startBackDeg = 30,     -- back from the bottom before the wind-up starts: 6 to 7 o'clock is a
	                       -- dead zone, crossing 7 starts the throw
	backswingMaxDeg = 200, -- s.back and result.back stop growing here (a little past 12 o'clock,
	                       -- 180); the arm itself keeps counting
	swingStartDps = 200,   -- forward speed (deg/s) that starts the flick; slower forward is the
	                       -- arm being let down
	speedWindow = 2,       -- frames averaged for "forward speed" (the stop test and the flick
	                       -- speed), so one slow sample in a jittery flick does not stop it
	releaseStopDps = 150,  -- the crank has stopped when the forward speed falls below this
	                       -- (3 degrees a 20 ms frame)
	skyDeg = 180,          -- forward degrees: an arm past 12 o'clock before stopping is a sky
	                       -- ball, released there
	cooldownS = 0.3,       -- seconds of frame time after a release in which the crank is ignored
	fullFlickDps = 1000,   -- flick speed (deg/s, the peak speedWindow average) that gives
	                       -- flickFrac 1: all the power of the backswing
	minFlickFrac = 0.2,    -- flickFrac of the slowest flick (swingStartDps and under)
	pullFrames = 2,        -- pull = +1 when the flick's fastest frame is one of its last
	                       -- pullFrames frames (still speeding up into the stop), else -1
	roughFull = 3.0,       -- roughness (mean second difference of speed / mean speed) that gives
	                       -- smoothness 0. Hardware traces (2026-11-13): a flick is only 4 to 7
	                       -- frames at about 41 ms each and honest flicks measure up to 0.67
	                       -- from sampling jitter alone, so only a clearly stuttered swing
	                       -- (roughness over 1.0) is shaky enough to be a helicopter
	maxSamples = 512,      -- flick speed samples kept (about 10 s at 50 fps); later ones dropped
}

function swing.new()
	return {
		phase = "idle",
		pending = 0,   -- idle: degrees the arm is behind the bottom, before the wind-up starts
		arm = 0,       -- forward degrees from the bottom: where the crank really is (winding, swinging)
		back = 0,      -- farthest back this wind-up (positive degrees, capped at backswingMaxDeg)
		far = 0,       -- farthest forward this flick (forward degrees)
		n = 0,         -- flick speed samples
		speeds = {},   -- deg/s per frame of the flick (reused)
		cool = 0,      -- cooldown seconds left
		result = {},   -- filled at a release (reused)
	}
end

-- Back to idle at once (no cooldown). s.back is kept for the dial; the caller
-- clears it if it wants.
function swing.reset(s)
	s.phase, s.pending, s.arm, s.far, s.n, s.cool = "idle", 0, 0, 0, 0, 0
end

-- Where the crank is, as the throwing arm: forward degrees from the bottom of
-- the turn, in (-180, 180]. `pos` is getCrankPosition (0 = straight up,
-- growing clockwise). Negative = on the wind-up side.
function swing.armAngle(pos)
	local a = ((pos - 180) * swing.tune.forwardSign) % 360
	if a > 180 then a = a - 360 end
	return a
end

-- The throw starts at the bottom of the turn: true when the arm went from
-- `prev` (at or ahead of the bottom) to `a` (behind it) in one frame. The
-- 90 degree limit keeps the jump across the top of the turn from counting.
function swing.crossedBack(prev, a)
	return prev ~= nil and prev >= 0 and a < 0 and (prev - a) < 90
end

-- Smoothness 0..1 of speeds[1..n]: one minus the mean absolute second
-- difference relative to the mean speed. A flick that speeds up evenly has
-- small second differences; alternating fast and slow frames have large ones.
-- With fewer than three samples there is no evidence of jerk: 1.
function swing.smoothness(speeds, n)
	if n < 3 then return 1 end
	local sum = 0
	for i = 1, n do sum = sum + speeds[i] end
	local mean = sum / n
	if mean <= 0 then return 0 end
	local r = 0
	for i = 2, n - 1 do
		r = r + abs(speeds[i] - 0.5 * (speeds[i - 1] + speeds[i + 1]))
	end
	r = r / (n - 2) / mean
	r = 1 - r / swing.tune.roughFull
	if r < 0 then return 0 end
	if r > 1 then return 1 end
	return r
end

-- The forward speed: the mean of speeds over the speedWindow frames ending at `upto`.
local function windowSpeed(speeds, upto)
	local lo = upto - swing.tune.speedWindow + 1
	if lo < 1 then lo = 1 end
	local sum = 0
	for i = lo, upto do sum = sum + speeds[i] end
	return sum / (upto - lo + 1)
end

-- Fill s.result and go to the cooldown. `how` is "stopped" or "sky".
--   back          degrees: the farthest back the wind-up reached (capped at backswingMaxDeg)
--   releaseAngle  forward degrees from the bottom: the farthest forward the arm got (where
--                 the throw leaves; skyDeg or a little over for a sky ball)
--   flickDps      deg/s: the flick's peak speedWindow average
--   flickFrac     minFlickFrac .. 1: the share of the backswing's power the flick gives
--   smoothness    0..1 over the flick's frames (swing.smoothness)
--   shake         1 - smoothness
--   pull          +1: the flick's fastest frame was one of its last pullFrames (still
--                 speeding up into the stop); -1: it peaked earlier and was falling off
--                 before the stop. Which way a shaky throw pulls.
--   how           "stopped" or "sky"
--   frames        frames in the flick (the trailing frames below releaseStopDps not counted)
local function release(s, how)
	local t = swing.tune
	local r = s.result
	local speeds, n = s.speeds, s.n
	-- the flick is its frames up to the last one still turning at speed
	local used = n
	while used > 1 and speeds[used] < t.releaseStopDps do used = used - 1 end
	local flick, fast, fastAt = 0, -math.huge, 1
	for i = 1, used do
		local w = windowSpeed(speeds, i)
		if w > flick then flick = w end
		if speeds[i] >= fast then fast, fastAt = speeds[i], i end
	end
	local f = (flick - t.swingStartDps) / (t.fullFlickDps - t.swingStartDps)
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	local sm = swing.smoothness(speeds, used)
	r.back = s.back
	r.releaseAngle = s.far
	r.flickDps = flick
	r.flickFrac = t.minFlickFrac + (1 - t.minFlickFrac) * f
	r.smoothness = sm
	r.shake = 1 - sm
	r.pull = (fastAt > used - t.pullFrames) and 1 or -1
	r.how = how
	r.frames = used
	s.phase, s.pending, s.arm, s.n, s.cool = "cooldown", 0, 0, 0, t.cooldownS
	return "release"
end

-- At a measured stop (or a finger lift) release at the farthest forward
-- angle. Only a forward swing past the bottom can leave the hand.
function swing.stop(s)
	if s.phase == "swinging" and s.far > 0 then return release(s, "stopped") end
	swing.reset(s)
	return "letdown"
end

-- Feed one frame. Returns nil, "letdown" or "release" (then s.result holds
-- the measurements).
-- A touch contact explicitly releases on lift; while held it can slow down
-- during the upswing. Crossing the sky angle still releases immediately.
function swing.update(s, delta, dt, held)
	local t = swing.tune
	if dt <= 0 then return nil end
	local phase = s.phase

	if phase == "cooldown" then
		s.cool = s.cool - dt
		if s.cool <= 0 then s.phase, s.cool = "idle", 0 end
		return nil
	end

	local fwd = delta * t.forwardSign

	if phase == "idle" then
		local p = s.pending - fwd
		if p < 0 then p = 0 end
		s.pending = p
		if p >= t.startBackDeg then
			s.phase = "winding"
			s.arm = -p
			s.back = (p < t.backswingMaxDeg) and p or t.backswingMaxDeg
			s.far, s.n = -p, 0
		end
		return nil
	end

	if phase == "winding" then
		if fwd > 0 and fwd / dt >= t.swingStartDps then
			s.phase = "swinging"
			s.far, s.n = s.arm, 0
			-- and this frame is the flick's first: on to swinging below
		else
			local a = s.arm + fwd
			s.arm = a
			if -a > s.back then
				s.back = (-a < t.backswingMaxDeg) and -a or t.backswingMaxDeg
			end
			if a >= 0 then
				swing.reset(s)
				return "letdown"
			end
			return nil
		end
	end

	-- swinging
	local n = s.n
	if n < t.maxSamples then
		n = n + 1
		s.speeds[n] = fwd / dt
		s.n = n
	end
	local a = s.arm + fwd
	s.arm = a
	if a > s.far then s.far = a end
	if s.far >= t.skyDeg then return release(s, "sky") end
	if not held and windowSpeed(s.speeds, n) < t.releaseStopDps then
		return swing.stop(s)
	end
	return nil
end

-- Run a recorded swing through a fresh state. `samples` is a flat array
-- {dt1, delta1, dt2, delta2, ...}. Returns the first event ("release" or
-- "letdown") and, for a release, the result table; or nil if the samples end
-- mid-swing.
function swing.replay(samples)
	local s = swing.new()
	for i = 1, #samples - 1, 2 do
		local ev = swing.update(s, samples[i + 1], samples[i])
		if ev then return ev, (ev == "release") and s.result or nil end
	end
	return nil
end

tw.swing = swing
