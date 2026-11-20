-- Baton flight for stage 1: a plain ballistic arc with tumble, no collisions.
-- Pure Lua: no playdate.*.
--
-- The baton leaves the hand at (x, lineY, handHeight), heading along the
-- swivel (0 = straight downfield, positive = toward +x) at the loft angle
-- above the horizontal. It turns end over end at the tumble
-- rate; the plane it turns in is tilted about the line of flight by the
-- swing's tilt (0 = clean end over end, 90 = a flat helicopter) and wobbles
-- around that tilt. Gravity and the air's drag (tune.dragK, the same figure
-- core/world flies the baton with). It stops dead the moment its center
-- reaches the ground and lies flat there (stage 2 replaces all of this with
-- the rigid body).
--
-- flight.carry and flight.speedForCarry are the aim's arithmetic: how far a
-- launch carries through still air, and the speed that carries a distance.
-- core/throwplan, core/drill and core/autothrow aim with them.
import "core/tw"

local sqrt, sin, cos, rad, abs, min, max = math.sqrt, math.sin, math.cos, math.rad, math.abs, math.min, math.max

local flight = {}

flight.tune = {
	g = 9.81,              -- m/s^2
	handHeight = 0.6,      -- m; release height at the throwing line
	batonLength = 0.30,    -- m (DESIGN 2)
	batonRadius = 0.022,   -- m (4.4 cm diameter)
	loftMinDeg = 5,        -- d-pad down limit: a low, hard throw (Jamie, 2026-11-14: was 15)
	loftMaxDeg = 55,       -- d-pad up limit: a high arc
	loftStepDeg = 5,       -- one d-pad press
	loftDefaultDeg = 35,   -- mid loft
	startAngle = math.pi / 2, -- tumble angle at release: upright in the hand
	wobbleAmp = 0.25,      -- the plane's tilt swings by this fraction of the tilt ...
	wobblePerTurn = 0.6,   -- ... this many times per tumble turn
	maxStep = 1 / 120,     -- s; flight.step subdivides longer frames
	-- The air's drag (audit 8, 2026-11-16): a thrown piece loses k |r| r of its
	-- velocity a second, r the air's velocity past it (the wind less its own),
	-- k = 0.5 rho Cd A / m (1/m), rho 1.2 kg/m^3. Figures from the drag tables
	-- in White, Fluid Mechanics, Tables 7.2 and 7.3 (after Hoerner, Fluid-Dynamic
	-- Drag), at a throw's Reynolds number (2 to 5 x 10^4, subcritical); estimates,
	-- good to perhaps 20 percent:
	--   baton  0.30 x 0.044 m round birch, 0.25 kg, turning end over end. Side on,
	--          a finite cylinder of L/D 6.8 has Cd 0.77 on 0.0132 m^2; end on,
	--          0.95 on 0.0015 m^2. At an angle the crossflow principle gives each
	--          part times |sin|^3 (|cos|^3 end on), whose mean over the turn is
	--          4 / 3 pi: Cd A = 0.0049 m^2, k = 0.0118
	--   kubb   0.15 x 0.07 x 0.07 m, 0.40 kg, tumbling (a lob) or spiralling
	--          about broadside to its flight (a drill, the nose 45 down on a
	--          rising throw): the mean area a tumbling block shows the air is a
	--          quarter of its surface (Cauchy), 0.0130 m^2, with Cd 1.0 (a cube
	--          is 1.07 face on, 0.81 edge on): Cd A = 0.0130 m^2, k = 0.0194
	-- At 10 m/s that is 1.2 m/s^2 on a baton, 1.9 on a kubb.
	dragK = { baton = 0.0118, kubb = 0.0194 },
	carryStep = 1 / 20,    -- s: flight.carry's midpoint step (within 2.5 mm of a fine one on
	                       -- any throw the game makes; cheap enough to solve every aim frame)
}

-- Unit launch velocity direction.
local function launchDir(swivel, loftDeg)
	local e = rad(loftDeg)
	local ce = cos(e)
	return sin(swivel) * ce, cos(swivel) * ce, sin(e)
end

-- Time from a launch height z0 with upward speed vz until z = 0.
local function timeToGround(z0, vz, g)
	return (vz + sqrt(vz * vz + 2 * g * z0)) / g
end

-- How far a launch at speed (m/s) and loft e (radians) from h (m) above the
-- ground carries through still air with drag k (1/m, tune.dragK) before it
-- comes down to the ground: R (m, horizontal) and T (s). Midpoint steps of
-- tune.carryStep (exact for gravity alone, which k = 0 takes in one go); the
-- last is cut where it reaches the ground. No tables.
local function carry(speed, e, h, k)
	local t = flight.tune
	local g = t.g
	local u, w = speed * cos(e), speed * sin(e)
	if k <= 0 then
		local T = timeToGround(h, w, g)
		return u * T, T
	end
	local H = t.carryStep
	local x, z, time = 0, h, 0
	for _ = 1, 3000 do
		local s = sqrt(u * u + w * w)
		local hu = u - 0.5 * H * k * s * u
		local hw = w - 0.5 * H * (g + k * s * w)
		local sm = sqrt(hu * hu + hw * hw)
		local au, aw = -k * sm * hu, -g - k * sm * hw
		local z1 = z + H * hw
		if z1 <= 0 then
			-- this step reaches the ground: z + w s + aw s^2 / 2 = 0 (aw < 0)
			local a = -aw
			local tau = (w + sqrt(w * w + 2 * a * z)) / a
			return x + u * tau + 0.5 * au * tau * tau, time + tau
		end
		x, z = x + H * hu, z1
		u, w = u + H * au, w + H * aw
		time = time + H
	end
	return x, time
end
flight.carry = carry

-- The speed (m/s) that carries R (m) at loft e (radians) from h (m) above the
-- ground through still air with drag k (flight.carry's inverse), and its
-- flight time T (s): from the drag-free speed, a scaled step and then secant
-- steps to within 0.1 um (so the two invert each other on the desktop), or
-- until a step stops getting closer: the device's 32-bit floats stop well
-- short of 0.1 um, and stepping on there only spent carries (the aim solves
-- this every frame the target moves). Two equal carries would divide by zero.
function flight.speedForCarry(R, e, h, k)
	local g = flight.tune.g
	local c = cos(e)
	local v0 = sqrt(g * R * R / (2 * c * c * (R * sin(e) / c + h)))
	if k <= 0 then return v0, timeToGround(h, v0 * sin(e), g) end
	local r0, T0 = carry(v0, e, h, k)
	local best = r0 - R
	if best < 0 then best = -best end
	local v1 = v0 * sqrt(R / r0)
	for _ = 1, 10 do
		local r1, T = carry(v1, e, h, k)
		local err = r1 - R
		local a = err < 0 and -err or err
		if a >= best then return v0, T0 end
		local dr = r1 - r0
		if a < 1e-7 or dr == 0 then return v1, T end
		local v2 = v1 - err * (v1 - v0) / dr
		if v2 == v1 or v2 ~= v2 then return v1, T end
		v0, r0, T0, v1, best = v1, r1, T, v2, a
	end
	return v0, T0
end

-- Predicted landing point and flight time of the baton's center:
-- lx, ly, T (flight.carry with the baton's drag): the arc flight.step follows.
-- z (nil: 0, the ground) is the height the centre comes down to: plan.solve
-- aims it through a piece at its aim height (plan.aimZFor).
function flight.predict(x, lineY, swivel, loftDeg, speed, z)
	local t = flight.tune
	local dx, dy = sin(swivel), cos(swivel)
	local R, T = carry(speed, rad(loftDeg), t.handHeight - (z or 0), t.dragK.baton)
	return x + R * dx, lineY + R * dy, T
end

-- The aim preview: where a full-power throw at this loft would land.
function flight.aimPreview(x, lineY, swivel, loftDeg, fullSpeed)
	local lx, ly = flight.predict(x, lineY, swivel, loftDeg, fullSpeed)
	return lx, ly
end

function flight.new()
	return {
		x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
		t = 0, T = 0,         -- time since release, predicted flight time
		phi = 0, rate = 0,    -- tumble angle (rad) and rate (rad/s)
		tilt = 0,             -- rotation plane tilt, radians
		dx = 0, dy = 1,       -- horizontal line of flight (unit)
		ox = 0, oy = 0,       -- launch point (ground)
		lx = 0, ly = 0,       -- predicted landing point
		landed = false,
		restAx = 1, restAy = 0, -- axis when lying on the ground
	}
end

-- Start a throw. tiltDeg comes from the swing (0 = clean).
function flight.launch(fl, x, lineY, swivel, loftDeg, speed, tumbleRate, tiltDeg)
	local t = flight.tune
	local dx, dy, dz = launchDir(swivel, loftDeg)
	fl.x, fl.y, fl.z = x, lineY, t.handHeight
	fl.vx, fl.vy, fl.vz = speed * dx, speed * dy, speed * dz
	fl.ox, fl.oy = x, lineY
	fl.dx, fl.dy = sin(swivel), cos(swivel)
	fl.t, fl.phi, fl.rate, fl.tilt = 0, t.startAngle, tumbleRate, rad(tiltDeg or 0)
	fl.lx, fl.ly, fl.T = flight.predict(x, lineY, swivel, loftDeg, speed)
	fl.landed = false
	return fl
end

-- Current tilt of the rotation plane, with its wobble.
function flight.planeTilt(fl)
	local t = flight.tune
	local turns = (t.startAngle - fl.phi) / (2 * math.pi)
	return fl.tilt * (1 + t.wobbleAmp * sin(2 * math.pi * t.wobblePerTurn * turns))
end

-- Unit baton axis: ax, ay, az. In flight it turns in the plane spanned by
-- the line of flight d and the "up" of the plane u, where u is z rotated
-- about d by the plane tilt (so a 90 degree tilt is a flat helicopter).
-- The top end tips forward: phi falls from pi/2 (upright) through 0 (along d).
function flight.axis(fl)
	if fl.landed then return fl.restAx, fl.restAy, 0 end
	local tau = flight.planeTilt(fl)
	local dx, dy = fl.dx, fl.dy
	local rx, ry = dy, -dx               -- right of the line of flight
	local ct, st = cos(tau), sin(tau)
	local ux, uy, uz = rx * st, ry * st, ct
	local cp, sp = cos(fl.phi), sin(fl.phi)
	return dx * cp + ux * sp, dy * cp + uy * sp, uz * sp
end

local function settle(fl)
	local ax, ay = flight.axis(fl)
	local n = sqrt(ax * ax + ay * ay)
	if n < 1e-3 then ax, ay, n = fl.dx, fl.dy, 1 end
	fl.restAx, fl.restAy = ax / n, ay / n
	fl.landed = true
	fl.z = 0
	fl.vx, fl.vy, fl.vz = 0, 0, 0
end

-- Advance by dt seconds: gravity and the baton's drag, flight.carry's
-- midpoint steps; the step that reaches the ground is cut at the contact
-- instant. Returns true on the step that lands.
function flight.step(fl, dt)
	if fl.landed then return false end
	local g = flight.tune.g
	local k = flight.tune.dragK.baton
	local maxStep = flight.tune.maxStep
	while dt > 0 do
		local h = min(dt, maxStep)
		dt = dt - h
		local vx, vy, vz = fl.vx, fl.vy, fl.vz
		local s = sqrt(vx * vx + vy * vy + vz * vz)
		local mx, my = vx - 0.5 * h * k * s * vx, vy - 0.5 * h * k * s * vy
		local mz = vz - 0.5 * h * (g + k * s * vz)
		local sm = sqrt(mx * mx + my * my + mz * mz)
		local ax, ay, az = -k * sm * mx, -k * sm * my, -g - k * sm * mz
		local z1 = fl.z + h * mz
		if z1 <= 0 then
			-- the root of z + vz s + az s^2 / 2 = 0 in (0, h]
			local s1 = (vz + sqrt(vz * vz - 2 * az * fl.z)) / -az
			if s1 > h then s1 = h end
			fl.x = fl.x + (vx + 0.5 * ax * s1) * s1
			fl.y = fl.y + (vy + 0.5 * ay * s1) * s1
			fl.t = fl.t + s1
			fl.phi = fl.phi - fl.rate * s1
			settle(fl)
			return true
		end
		fl.x, fl.y, fl.z = fl.x + h * mx, fl.y + h * my, z1
		fl.vx, fl.vy, fl.vz = vx + h * ax, vy + h * ay, vz + h * az
		fl.t = fl.t + h
		fl.phi = fl.phi - fl.rate * h
	end
	return false
end

-- Horizontal distance from the launch point.
function flight.distance(fl)
	local ex, ey = fl.x - fl.ox, fl.y - fl.oy
	return sqrt(ex * ex + ey * ey)
end

-- Fraction of the predicted flight done, 0..1 (for the follow camera).
function flight.progress(fl)
	if fl.landed or fl.T <= 0 then return 1 end
	return max(0, min(1, fl.t / fl.T))
end

-- Whole tumble turns so far.
function flight.turns(fl)
	return abs(flight.tune.startAngle - fl.phi) / (2 * math.pi)
end

tw.flight = flight
