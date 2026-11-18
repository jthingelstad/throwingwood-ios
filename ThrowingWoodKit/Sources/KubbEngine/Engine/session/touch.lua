-- One contact, in short-screen-edge units, y increasing down and t in seconds.
-- Interpolate the raw path BEFORE projecting it onto the clock. The integer tick
-- counts from down, never from a display frame or the start of a batch.
import "core/swing"
import "tune/touch"

local swing, tune = tw.swing, tw.tune.touch
local dt = 1 / tune.hz
local touch = {}

local function step(s, g, x, y)
	local vertical = g.y0 - y
	local travel = math.max(0, math.abs(vertical) - tune.sideWeight * math.abs(x - g.x0))
	local offset = vertical < 0 and -travel or travel
	local arm = math.floor(offset * tune.degrees * tune.precision + 0.5) / tune.precision
	-- The stroke starts at six; travel above the origin before winding cannot
	-- add power when the finger comes back down.
	if s.swing.phase == "idle" then arm = math.min(0, arm) end
	local delta = (arm - g.arm) * swing.tune.forwardSign
	g.arm, s.arm = arm, arm
	return swing.update(s.swing, delta, dt, true)
end

local function advance(s, g, p)
	local span = p.t - g.t
	if span < 0 then return end -- duplicate/coalesced events can arrive late
	if span > tune.maxGap then return "letdown" end
	local endTick = (p.t - g.t0) * tune.hz
	while g.tick <= endTick + 1e-7 do
		local f = math.min(1, (g.tick - (g.t - g.t0) * tune.hz) / (span * tune.hz))
		local ev = step(s, g, g.x + (p.x - g.x) * f, g.y + (p.y - g.y) * f)
		g.tick = g.tick + 1
		if ev then return ev end
	end
	g.x, g.y, g.t = p.x, p.y, p.t
	if p.phase == "up" then
		-- Hold the endpoint to the next tick for a sub-tick lift, then let
		-- the core decide release vs let-down at that angle.
		if g.tick - 1 < endTick - 1e-7 then
			local ev = step(s, g, p.x, p.y)
			if ev then return ev end
		end
		return swing.stop(s.swing)
	end
end

-- Consumed once, in event order. Empty display frames do not invent samples.
function touch.frame(s, samples)
	local lastEvent
	for _, p in ipairs(samples) do
		if p.phase == "down" then
			lastEvent = nil
			swing.reset(s.swing)
			s.armed, s.pointerDown, s.arm = true, false, 0
			s.touch = { x0 = p.x, y0 = p.y, t0 = p.t, x = p.x, y = p.y, t = p.t, tick = 1, arm = 0 }
		elseif s.touch then
			local ev
			if p.phase == "cancel" then ev = "letdown" else ev = advance(s, s.touch, p) end
			if ev then
				s.touch, s.arm, s.armed = nil, nil, false
				if ev == "release" then return ev end
				swing.reset(s.swing)
				-- A second contact can already be in this display frame.
				lastEvent = ev
			end
		end
	end
	return lastEvent
end

tw.web = tw.web or {}
tw.web.touch = touch
