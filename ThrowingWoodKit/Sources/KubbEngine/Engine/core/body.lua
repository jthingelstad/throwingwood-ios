-- Rigid bodies: the baton (a capsule) and kubbs and the king (boxes).
-- Pure Lua: no playdate.*.
--
-- A body is one flat table of numbers so the physics step makes no garbage:
--   x, y, z          center of mass (world meters)
--   vx, vy, vz       linear velocity
--   qw, qx, qy, qz   orientation (body local -> world)
--   wx, wy, wz       angular velocity, world frame (rad/s)
--   r11 .. r33       rotation matrix of q, row-major; column 3 is the local z
--                    axis, which is the long axis of every piece
--   i11 .. i33       inverse inertia tensor in the world frame (symmetric)
-- Local frame: z is the long axis (a standing kubb has local z up; the
-- baton's segment runs along local z).
import "core/tw"
import "core/quat"

local quat = tw.quat
local sqrt = math.sqrt

local body = {}

body.BOX, body.CAPSULE = 1, 2

-- Piece sizes and masses (DESIGN 2). Not tunables: the rules fix them.
body.kinds = {
	kubb = { shape = 1, hx = 0.035, hy = 0.035, hz = 0.075, mass = 0.40 },
	king = { shape = 1, hx = 0.045, hy = 0.045, hz = 0.15, mass = 1.2 },
	-- 30 cm long overall, 4.4 cm diameter: a segment of half length
	-- 0.15 - 0.022 plus a 0.022 m radius
	baton = { shape = 2, hl = 0.128, r = 0.022, length = 0.30, mass = 0.25 },
	-- a pitch stake: a fixed vertical post (static: it never moves). Radius
	-- from core/pitch; world.addStakes sets its height from world.tune.
	stake = { shape = 2, hl = 0.135, r = 0.015, length = 0.30, mass = 1, static = true },
}

-- Principal moments of inertia (kg m^2) about the local axes.
-- Box (full sides a, b, c): Ix = m (b^2 + c^2) / 12, and so on.
-- Baton: a real baton is a solid wooden cylinder (the capsule is only its
-- collision shape), so it gets the solid cylinder's inertia:
-- axial m r^2 / 2, transverse m (3 r^2 + L^2) / 12.
function body.inertia(k)
	local m = k.mass
	if k.shape == 1 then
		local a, b, c = 2 * k.hx, 2 * k.hy, 2 * k.hz
		return m * (b * b + c * c) / 12, m * (a * a + c * c) / 12, m * (a * a + b * b) / 12
	end
	local r, L = k.r, k.length
	local t = m * (3 * r * r + L * L) / 12
	return t, t, 0.5 * m * r * r
end

function body.new(kind, id)
	local k = body.kinds[kind]
	assert(k, "unknown body kind " .. tostring(kind))
	local Ix, Iy, Iz = body.inertia(k)
	local b = {
		kind = kind, id = id or kind, shape = k.shape,
		hx = k.hx or 0, hy = k.hy or 0, hz = k.hz or 0,
		hl = k.hl or 0, r = k.r or 0,
		m = k.mass, im = 1 / k.mass,
		Ix = Ix, Iy = Iy, Iz = Iz, iIx = 1 / Ix, iIy = 1 / Iy, iIz = 1 / Iz,
		x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
		qw = 1, qx = 0, qy = 0, qz = 0, wx = 0, wy = 0, wz = 0,
		r11 = 1, r12 = 0, r13 = 0, r21 = 0, r22 = 1, r23 = 0, r31 = 0, r32 = 0, r33 = 1,
		i11 = 0, i12 = 0, i13 = 0, i22 = 0, i23 = 0, i33 = 0,
		awake = false, sleepTime = 0, everAwake = false,
		wokeStep = -1,       -- the step a touch woke it in (world.step wakes the group it rests against)
		bounceStep = -1,     -- the last step it bounced off another piece (world.step's restitution)
		rowStep = -1,        -- the last step it was in a bounce group that spread past the pieces that bounce
		cStep = -1,          -- the last step it had a contact (world.step: a body with none moves by
		                     -- the trapezoid)
		-- what holds it up and what it waits for before it sleeps (world.step, phase 8):
		restStep = -1,       -- the last step it pressed on a sleeping or static piece
		propStep = -1,       -- the last step it pressed on an awake piece, propBy
		propBy = false,
		mateStep = -1,       -- the last step it pressed on an awake piece, and mateMin the
		mateMin = 0,         -- least sleep timer among those pieces (the step before)
		-- bounding sphere radius about the center
		radius = (k.shape == 1) and sqrt(k.hx ^ 2 + k.hy ^ 2 + k.hz ^ 2) or (k.hl + k.r),
		-- the outcome of the throw
		toppled = false, touched = false, leftPitch = false,
		-- ground contact slots (one per box corner or capsule end) for warm
		-- starting: accumulated impulses from the last step that had them
		gStamp = {}, gN = {}, gT1 = {}, gT2 = {}, gDig = {}, gBite = {}, gMf = {}, gEf = {},
		groundImpulse = 0,   -- sum of ground normal impulses in this step
		dig = 0,             -- extra rolling-resistance lever from digging in (m), decays
		plough = 0,          -- m slid on the ground since it last left it (snow piles up)
		impact = -1,         -- the last step a ground contact arrived faster than restitutionSpeed
		index = 0,
	}
	if k.static then
		-- infinite mass: no impulse moves it
		b.static = true
		b.im, b.iIx, b.iIy, b.iIz = 0, 0, 0, 0
	end
	for i = 1, 8 do
		b.gStamp[i], b.gN[i], b.gT1[i], b.gT2[i], b.gDig[i], b.gBite[i] = -1, 0, 0, 0, 0, 0
		b.gMf[i], b.gEf[i] = 1, 1   -- the ground texture's friction and bounce factors
	end
	body.updateDerived(b)
	return b
end

-- Rotation matrix and world inverse inertia from the quaternion.
function body.updateDerived(b)
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 = quat.toMatrix(b.qw, b.qx, b.qy, b.qz)
	b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33 = r11, r12, r13, r21, r22, r23, r31, r32, r33
	-- I^-1 world = R diag(iI) R^T
	local a, c, e = b.iIx, b.iIy, b.iIz
	b.i11 = r11 * r11 * a + r12 * r12 * c + r13 * r13 * e
	b.i12 = r11 * r21 * a + r12 * r22 * c + r13 * r23 * e
	b.i13 = r11 * r31 * a + r12 * r32 * c + r13 * r33 * e
	b.i22 = r21 * r21 * a + r22 * r22 * c + r23 * r23 * e
	b.i23 = r21 * r31 * a + r22 * r32 * c + r23 * r33 * e
	b.i33 = r31 * r31 * a + r32 * r32 * c + r33 * r33 * e
end

function body.setPose(b, x, y, z, qw, qx, qy, qz)
	b.x, b.y, b.z = x, y, z
	b.qw, b.qx, b.qy, b.qz = quat.normalize(qw or 1, qx or 0, qy or 0, qz or 0)
	body.updateDerived(b)
end

function body.setVelocity(b, vx, vy, vz, wx, wy, wz)
	b.vx, b.vy, b.vz = vx or 0, vy or 0, vz or 0
	b.wx, b.wy, b.wz = wx or 0, wy or 0, wz or 0
end

-- World inverse inertia times a vector.
function body.invInertiaMul(b, x, y, z)
	return b.i11 * x + b.i12 * y + b.i13 * z,
		b.i12 * x + b.i22 * y + b.i23 * z,
		b.i13 * x + b.i23 * y + b.i33 * z
end

-- Angular momentum about the center, world frame: I_world w = R I R^T w.
function body.angularMomentum(b)
	local wx, wy, wz = b.wx, b.wy, b.wz
	-- to body frame
	local lx = b.r11 * wx + b.r21 * wy + b.r31 * wz
	local ly = b.r12 * wx + b.r22 * wy + b.r32 * wz
	local lz = b.r13 * wx + b.r23 * wy + b.r33 * wz
	lx, ly, lz = lx * b.Ix, ly * b.Iy, lz * b.Iz
	return b.r11 * lx + b.r12 * ly + b.r13 * lz,
		b.r21 * lx + b.r22 * ly + b.r23 * lz,
		b.r31 * lx + b.r32 * ly + b.r33 * lz
end

-- Kinetic energy (J), and kinetic plus potential with gravity g above z = 0.
function body.kinetic(b)
	local Lx, Ly, Lz = body.angularMomentum(b)
	return 0.5 * b.m * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
		+ 0.5 * (Lx * b.wx + Ly * b.wy + Lz * b.wz)
end

function body.energy(b, g)
	return body.kinetic(b) + b.m * g * b.z
end

-- The world z of the body's lowest point.
function body.lowestZ(b)
	if b.shape == 1 then
		return b.z - (b.hx * math.abs(b.r31) + b.hy * math.abs(b.r32) + b.hz * math.abs(b.r33))
	end
	return b.z - b.hl * math.abs(b.r33) - b.r
end

-- Is the long axis within `sinTol` (sine of the angle) of parallel to the ground?
function body.lying(b, sinTol)
	return math.abs(b.r33) <= sinTol
end

-- Would a box fall if whatever it leans on were taken away? True when the
-- plumb line through its centre lands outside the end face it stands on.
-- (A kubb goes at about 25 degrees from upright, the king at about 17.)
function body.wouldFall(b)
	local up = math.abs(b.r33)
	return b.hz * math.abs(b.r31) > b.hx * up or b.hz * math.abs(b.r32) > b.hy * up
end

tw.body = body
