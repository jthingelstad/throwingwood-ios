-- The physics world (DESIGN 5): 3D rigid bodies on a ground plane, fixed
-- step, impulse-based contacts with Coulomb friction and restitution.
-- Pure Lua: no playdate.*.
--
-- One step (world.step), after Box2D v3's soft-step order with one substep:
--   1. gravity and the gyroscopic term for awake bodies
--   2. contacts: body pairs first (an awake body moving into a sleeping one
--      wakes it), then the ground for every awake body
--   3. prepare the contacts and warm start the ground contacts from the
--      impulses of the step before
--   4. `iterations` sequential-impulse passes with a position bias (pushes
--      overlapping pieces apart, lets speculative contacts close their gap)
--   5. move and turn the bodies
--   6. `relaxIterations` passes without the push bias, so pushing apart
--      does not leave pieces with extra speed (no energy gain)
--   7. restitution, from each contact's approach speed before the solve,
--      with its friction
--   8. rolling resistance and dig, sleep, topple and touch bookkeeping
-- Tipping about an edge, rocking back and falling are all just contacts.
--
-- Surfaces are parameter sets (world.surfaces). "Dig": when a corner, edge
-- or baton end arrives steeply and fast, that contact loses its bounce, gets
-- extra friction for as long as it lasts (it is ploughed in), and the body
-- gets a rolling-resistance lever that fades over digTime (it is plugged).
-- "Bite": an edge or corner that strikes the turf is held sideways by it, an
-- extra friction coefficient that fades as it works loose. Every body meets
-- the ground the same way: a drilled kubb (world.launchDrill) is a plain
-- kubb once it is down; in flight it has the air's turn (world.aeroTurn).
--
-- Usage:
--   local w = world.new{ surface = "grass", pieces = { {id=, kind=, x=, y=, yaw=}, ... } }
--   world.launchBaton(w, x, lineY, swivel, loftDeg, speed, tumbleRate, tiltDeg)
--   while not world.isAtRest(w) do world.step(w) end
--   local r = world.result(w)
import "core/tw"
import "core/quat"
import "core/body"
import "core/collide"
import "core/flight"
import "core/pitch"
import "core/drill"

local quat, body, collide = tw.quat, tw.body, tw.collide
local sqrt, abs, min, max, sin, cos, rad, exp = math.sqrt, math.abs, math.min, math.max, math.sin, math.cos, math.rad, math.exp
local floor = math.floor

local world = {}

world.tune = {
	dt = 1 / 240,          -- s, the fixed step (DESIGN 5)
	g = 9.81,              -- m/s^2
	iterations = 4,        -- velocity passes per step with the position bias (guess: enough for
	                       -- a kubb on its edge and three-kubb dominoes at 240 Hz)
	relaxIterations = 1,   -- passes without the bias
	slop = 0.0005,         -- m of overlap left alone (stops resting contacts flickering)
	pushRate = 0.2,        -- fraction of the overlap beyond slop removed per step
	maxPush = 0.5,         -- m/s cap on the push-apart speed
	margin = 0.002,        -- m; contacts are made this far before touching, plus the distance
	                       -- the pieces can close in one step (speculative contacts)
	restitutionSpeed = 0.4,-- m/s; slower impacts do not bounce
	batonTurnHold = 1,     -- share of the ground's rolling resistance (surf.roll) that also holds a
	                       -- baton's end-over-end turn on the ground (all of it holds its roll
	                       -- about the long axis; the plug, dig, holds both)
	restitutionIterations = 4, -- bounce passes (one pass over a flat landing's corners overshoots)
	restitutionMaxIterations = 32, -- and when the bounce reaches a row, up to this many: they stop once
	restitutionTol = 1e-4, -- no impulse changes by this (N s); the push crosses a row of four in 10 to 30
	pairMu = 0.4,          -- wood on wood friction, every pair of pieces (kubb on kubb, the king, a baton,
	                       -- a stake): clean dry wood on wood 0.25 to 0.5, oak on oak sliding 0.48 along
	                       -- the grain and 0.32 across it (Engineering ToolBox, friction coefficients).
	                       -- Kubb on kubb was 0.2 (wet wood) from 2026-11-15 to 2026-11-16 so a tight row
	                       -- fell; at 0.4 it stands more (docs/notes/physics.md, "Edge on edge")
	pairE = 0.35,          -- wood on wood bounce: no measured wood on wood figure found; a wooden
	                       -- ball on concrete is 0.60 (The Physics Factbook, 2005) and a block gives
	                       -- up more. 0.2 from 2026-11-15 to 2026-11-16, to hide a bounce solved
	                       -- without the kubb's footing (docs/notes/physics.md, "The pair bounce with its footing")
	warm = 0.9,            -- fraction of last step's ground impulses applied up front
	gyro = true,           -- gyroscopic term (torque-free precession; implicit, stable)
	flightTurns = 4,       -- a drilled kubb's turn in flight (the air's turn, the gyroscopic term
	                       -- and its attitude) is stepped this many times a step: a drill spinning
	                       -- at 25 rad/s or more precesses too far in one 1/240 s step (docs/notes/physics.md,
	                       -- "Physics", "The turn in flight")
	sleepLin = 0.03,       -- m/s: below this ...
	sleepAng = 0.3,        -- rad/s: ... and this ...
	sleepTime = 0.25,      -- s: ... for this long while touching something: the body sleeps
	wakeLin = 0.05,        -- m/s: a touching awake body moving faster than this (or turning
	wakeAng = 0.5,         -- faster than this, rad/s) wakes a sleeping one
	toppleDeg = 5,         -- toppled: the long axis came within this of parallel to the ground
	pitchHalfWidth = 2.5,  -- m (DESIGN 2)
	pitchLength = 8,
	outMargin = 0.04,      -- m beyond a pitch line before a center counts as out (base kubbs
	                       -- stand centered on the baselines)
	maxTime = 12,          -- s; a throw is called at rest after this long regardless
	stakeHeight = 0.15,    -- m above the ground (6 inches, Jamie 2026-11-14); stakes are fixed posts of radius pitch.stakeRadius
	-- the air's drag on a thrown piece per kind (world.airDrag) is
	-- tw.flight.tune.dragK, the figure the aim solves with
	aeroK = 0.00022,       -- the air's turn on a drilled kubb in flight (world.aeroTurn): rho (k2 - k1)
	                       -- volume: half the slender-body (Munk) moment of a 7 x 7 x 15 cm block (k2 - k1
	                       -- about 0.5), which overstates a bluff block; an estimate. It turns the long axis
	                       -- broadside to the air, so a kubb with too little spin tumbles
}

-- Ground surfaces: one parameter set each (DESIGN 5). All guesses, to be
-- tuned on hardware in stages 2 and 4.
--   mu          Coulomb friction, wood on the ground
--   e           restitution (bounce)
--   dig         how strongly a steep, fast arrival digs in (0 = never). The
--               dig amount of a new contact is dig * steepness * ramp, where
--               steepness = approach speed / contact speed (1 = straight in)
--               and ramp goes 0 -> 1 between digSpeed and digSpeed + digRamp
--   digSpeed, digRamp  m/s
--   digLever    m; rolling resistance lever (per unit dig) a dug-in body gets
--   digTime     s; how fast that lever fades
--   roll        m; rolling resistance lever for the round baton at all times
--   texture     (optional) what a flat plane leaves out (Jamie, 2026-11-14:
--               "in a real game there is always random stuff because of the
--               surface"). The ground is cut into `cell`-sized patches, each
--               with its own values from a hash of the patch and the throw's
--               seed (world.groundSeed), read only when a contact is new:
--     muVar, eVar, digVar  a patch's friction, bounce and dig vary by up to
--               this share either way (clumps, bare spots, soft ground)
--     bump      the patch's tilt: a steep landing (approach faster than
--               bumpSpeed m/s) meets ground sloped up to bump (times its
--               steepness squared) each way, and that step's push and friction
--               lean with it, so it is turned and nothing is added
--     drag      1/s: a lying piece or a baton touching the ground with its
--               full weight loses this share of its ground speed a second (the
--               blades hold it; pressed more lightly, less)
--     grip, gripSpeed  1/s and m/s: and this much more a second below
--               gripSpeed, so it stops instead of creeping
--     footMu, footSpeed  (optional; snow) a piece standing on an end
--               (within 30 degrees of upright: a kubb, the king or a baton)
--               whose foot slides faster than footSpeed m/s ploughs: a
--               resistance at the foot of at most footMu times the ground's
--               push, so it tips the way it is going where the surface's own
--               friction is too low to tip it
--     bite      an edge or corner that strikes the turf cuts into it and is
--               held sideways by it: an extra friction coefficient on that
--               contact, ramped like dig by the edge's own arrival speed and
--               scaled by pointed() (0 on a face)
--     biteTime  s: how fast the hold weakens while the edge stays down
--     plough    1/s per m (optional): the drag grows with the distance a piece
--               has slid since it last left the ground (snow piles up in front
--               of it), so a slide starts slick and ends heavy
world.surfaces = {
	grass = {
		name = "grass", mu = 0.7, e = 0.15,
		dig = 1.0, digSpeed = 0.3, digRamp = 1.5, digLever = 0.006, digTime = 0.15,
		bite = 0.7, biteTime = 0.05,
		roll = 0.01,
		texture = { cell = 0.25, muVar = 0.3, eVar = 0.5, digVar = 0.5, bump = 0.12, bumpSpeed = 0.8,
			drag = 2.5, grip = 12, gripSpeed = 0.5 },
	},
	-- sand (DESIGN 5): very high dig, almost no bounce or slide; pieces plug where
	-- they land, so placement is all in the air. Its texture: soft and packed
	-- spots (dig varies a lot), ridges and footprints that turn a landing more
	-- than grass does, and sand that drags hard and grabs.
	sand = {
		name = "sand", mu = 0.9, e = 0.03,
		dig = 3.0, digSpeed = 0.2, digRamp = 1.0, digLever = 0.03, digTime = 0.5,
		bite = 2, biteTime = 0.1,
		roll = 0.03,
		texture = { cell = 0.2, muVar = 0.25, eVar = 0.4, digVar = 0.7, bump = 0.18, bumpSpeed = 0.6,
			drag = 6, grip = 20, gripSpeed = 0.6 },
	},
	-- snow (Jamie, 2026-11-14): packed snow is slick to a fast piece, but soft:
	-- a steep landing plugs, almost nothing bounces, and a sliding piece ploughs
	-- snow ahead of it, so it starts fast and stops heavy. Icy and soft patches
	-- (friction and dig vary most of all here).
	snow = {
		name = "snow", mu = 0.25, e = 0.02,
		dig = 2.5, digSpeed = 0.3, digRamp = 1.2, digLever = 0.025, digTime = 0.4,
		bite = 0, biteTime = 0.05,
		roll = 0.004,
		texture = { cell = 0.3, muVar = 0.5, eVar = 0.3, digVar = 0.8, bump = 0.1, bumpSpeed = 0.8,
			drag = 0.6, grip = 4, gripSpeed = 0.3, plough = 1.5,
			footMu = 0.3, footSpeed = 0.3 },
	},
	-- ICE (stage 7, not built): very low friction for the Minnesota slide,
	-- something like mu = 0.05, e = 0.1, dig = 0, roll = 0.0005. Add it
	-- here as another parameter set; nothing else should need to change.
}
-- The surfaces a game can be played on, in the order they are offered.
world.SURFACES = { "grass", "sand", "snow" }

-- Optional profiling (the device autobench): set world.prof to a table
-- from world.newProf(clock) and world.step adds the seconds of each phase
-- into it. nil (the default) costs one test per phase.
world.prof = nil
world.PHASES = { "forces", "pairs", "ground", "prepare", "solve", "integrate", "relax",
	"restitution", "store", "tail", "lone" }
function world.newProf(clock)
	local p = { clock = clock, narrow = 0 }
	for _, k in ipairs(world.PHASES) do p[k] = 0 end
	return p
end

-- The awake set's epoch: bumped whenever any body in any world wakes, falls
-- asleep or is added. A world caches what the lone-flight test needs (the one
-- awake body, the highest point of everything else) and rebuilds it when
-- the epoch has moved. A sleeping body is never moved by hand; if one ever
-- is, call world.touch() so the cache is rebuilt.
local epoch = 0
function world.touch() epoch = epoch + 1 end

-- ---------------------------------------------------------------------------
-- Building a world

function world.new(opts)
	opts = opts or {}
	local surf = opts.surface or "grass"
	if type(surf) == "string" then surf = assert(world.surfaces[surf], "unknown surface " .. surf) end
	-- opts.texture = false: the surface as a flat plane (tests of one piece of
	-- mechanics; tools/groundstats --flat)
	if opts.texture == false and surf.texture then
		local flat = {}
		for k, v in pairs(surf) do flat[k] = v end
		flat.texture = nil
		surf = flat
	end
	local w = {
		bodies = {}, n = 0, byId = {},
		surface = surf,
		time = 0, steps = 0,
		projectile = nil,
		firstContact = nil,   -- the projectile's first contact: {t, x, y, z, with}
		firstHit = nil,       -- its first contact with another body: same fields
		contacts = 0,         -- contacts in the last step (for the bench)
		awakeCount = 0,       -- awake bodies in the last step
		bouncePasses = 0,     -- bounce passes run so far (stage 7; for the bench)
		groundSeed = opts.groundSeed or 0,   -- the ground texture's seed (world.launch sets it
		groundSeedFixed = opts.groundSeed ~= nil,   -- from the throw unless one is given here)
		-- the wind (m/s, horizontal): it pushes the thrown piece until its
		-- first contact (airDrag); none, and it meets still air
		windX = opts.windX or 0, windY = opts.windY or 0,
		windOn = (opts.windX or 0) ~= 0 or (opts.windY or 0) ~= 0,
	}
	if opts.stakes ~= false then world.addStakes(w) end
	for _, p in ipairs(opts.pieces or {}) do world.addPiece(w, p) end
	return w
end

-- The six pitch stakes (core/pitch) as static posts, ids stake1 .. stake6.
-- They never move or wake; anything touching one marks it touched.
function world.addStakes(w)
	local h, r = world.tune.stakeHeight, tw.pitch.stakeRadius
	for i, s in ipairs(tw.pitch.stakes) do
		local b = world.addBody(w, "stake", "stake" .. i)
		b.r = r
		b.hl = h / 2 - r
		b.radius = h / 2
		body.setPose(b, s.x, s.y, h / 2, 1, 0, 0, 0)
		b.awake = false
	end
end

function world.addBody(w, kind, id)
	epoch = epoch + 1
	local b = body.new(kind, id)
	w.n = w.n + 1
	b.index = w.n
	w.bodies[w.n] = b
	w.byId[b.id] = b
	return b
end

-- Add a piece at rest on the ground. p = { id, kind, x, y, yaw } stands a
-- kubb or king up (a baton lies along yaw); or give a full pose
-- p.qw, p.qx, p.qy, p.qz (z is then chosen so it rests on the ground unless
-- p.z is given). Pieces start asleep.
function world.addPiece(w, p)
	local b = world.addBody(w, p.kind, p.id)
	local qw, qx, qy, qz = p.qw, p.qx, p.qy, p.qz
	if not qw then
		qw, qx, qy, qz = quat.fromAxisAngle(0, 0, 1, p.yaw or 0)
		if p.kind == "baton" then
			-- lie down: local z (the segment) along the yaw direction
			local tw_, tx, ty, tz = quat.fromAxisAngle(1, 0, 0, -math.pi / 2)
			qw, qx, qy, qz = quat.mul(qw, qx, qy, qz, tw_, tx, ty, tz)
		end
	end
	body.setPose(b, p.x or 0, p.y or 0, 0, qw, qx, qy, qz)
	if p.z then
		b.z = p.z
	else
		b.z = -body.lowestZ(b)
	end
	b.awake = false
	-- a piece that is already down (from an earlier throw) stays toppled
	b.toppled = p.toppled or (b.shape == 1 and (body.lying(b, sin(rad(world.tune.toppleDeg))) or body.wouldFall(b)))
	b.wasToppled = b.toppled
	return b
end

local function wake(b)
	if not b.awake and not b.static then
		epoch = epoch + 1
		b.awake = true
		b.everAwake = true
		b.sleepTime = 0
	end
end
world.wake = wake

-- Launch a projectile body (baton or kubb) with a full pose and velocity.
-- Angular velocity is in the world frame.
-- The ground texture's seed for a throw: from the launch itself, so the same
-- throw meets the same ground (replays, tests) and every other throw its own.
local function seedFrom(...)
	local h = 0x2545F491
	for _, v in ipairs { ... } do
		h = (h ~ math.floor(v * 4096)) * 0x9E3779B1 & 0x7fffffff
	end
	return h
end
world.seedFrom = seedFrom

function world.launch(w, kind, id, x, y, z, qw, qx, qy, qz, vx, vy, vz, wx, wy, wz)
	local b = world.addBody(w, kind, id)
	body.setPose(b, x, y, z, qw, qx, qy, qz)
	body.setVelocity(b, vx, vy, vz, wx, wy, wz)
	if not w.groundSeedFixed then w.groundSeed = seedFrom(x, y, vx, vy, vz, wx, wy, wz) end
	wake(b)
	b.touched = true
	w.projectile = b
	b.dragK = tw.flight.tune.dragK[kind] or 0
	return b
end

-- Unit horizontal direction of the swivel and the launch direction at the
-- loft (the same conventions as core/flight).
local function launchDir(swivel, loftDeg)
	local e = rad(loftDeg)
	local ce = cos(e)
	return sin(swivel) * ce, cos(swivel) * ce, sin(e)
end

-- The baton launch from stage 1's swing outputs: it leaves the hand at
-- (x, lineY, flight.tune.handHeight) heading along the swivel at the loft,
-- held upright, turning end over end at tumbleRate (rad/s) with the top end
-- tipping forward. tiltDeg tilts the plane it turns in about the line of
-- flight (0 = clean end over end, 90 = a flat helicopter): the angular
-- velocity is about the tilted axis, so a helicopter really spins flat.
-- Returns the pose and velocities as 13 numbers.
function world.batonLaunchState(x, lineY, swivel, loftDeg, speed, tumbleRate, tiltDeg)
	local dx, dy = sin(swivel), cos(swivel)
	local lx, ly, lz = launchDir(swivel, loftDeg)
	local tau = rad(tiltDeg or 0)
	-- u: "up" of the turning plane, z turned about d toward the right by tau
	local rx, ry = dy, -dx
	local st, ct = sin(tau), cos(tau)
	local ux, uy, uz = rx * st, ry * st, ct
	-- k = d x u, the axis the baton turns about
	local kx, ky, kz = dy * uz, -dx * uz, dx * uy - dy * ux
	local kn = sqrt(kx * kx + ky * ky + kz * kz)
	kx, ky, kz = kx / kn, ky / kn, kz / kn
	-- local axes: x = k, y = d, z = u (the baton starts along u)
	local qw, qx, qy, qz = quat.fromAxes(kx, ky, kz, dx, dy, 0, ux, uy, uz)
	local h = tw.flight.tune.handHeight
	return x, lineY, h, qw, qx, qy, qz,
		speed * lx, speed * ly, speed * lz,
		-tumbleRate * kx, -tumbleRate * ky, -tumbleRate * kz
end

function world.launchBaton(w, x, lineY, swivel, loftDeg, speed, tumbleRate, tiltDeg, id)
	return world.launch(w, "baton", id or "baton",
		world.batonLaunchState(x, lineY, swivel, loftDeg, speed, tumbleRate, tiltDeg))
end

-- A lobbed kubb (stage 3's simple inkast; drilling and the cut are stage 4):
-- the same launch as a clean baton, upright in the hand and turning end
-- over end at tumbleRate, as body `id` (the kubb's own id).
function world.launchKubb(w, id, x, lineY, swivel, loftDeg, speed, tumbleRate)
	return world.launch(w, "kubb", id,
		world.batonLaunchState(x, lineY, swivel, loftDeg, speed, tumbleRate, 0))
end

-- A drilled kubb (core/drill), launched the way a baton is: a plain rigid
-- body released from the swing, and the world does the rest (2026-11-16,
-- Jamie: "we didn't treat Kubb throws with the same physics as baton
-- throws"). It leaves the hand at (x, lineY, handHeight) along the swivel at
-- the loft, held by its back end with its long axis pointing down the line,
-- the nose noseDownDeg below the horizontal (a kubb hanging from the hand at
-- the end of an underhand swing), rolled rollDeg about that axis (0: a face
-- flat to the side). The wrist's snap spins it about the long axis at
-- spinRate (rad/s; + = clockwise seen from behind). Nothing is solved back
-- from the landing: a fast spiral is a gyroscope, so the kubb lands about
-- as it left the hand, nose first; the air's turn (world.aeroTurn) tumbles
-- one with too little spin. wobbleRate (rad/s) is a jerky swing's nose-up
-- turn about the right-hand axis; dPitch, dYaw (about the kubb's own up) and
-- dSpin (rad/s) are the swing's own scatter of the release turn, and
-- dNoseDeg of its attitude. Returns the pose and velocities as 13 numbers.
function world.drillLaunchState(x, lineY, swivel, loftDeg, speed, noseDownDeg, rollDeg, spinRate, wobbleRate,
		dPitch, dYaw, dSpin, dNoseDeg)
	dPitch, dYaw, dSpin = dPitch or 0, dYaw or 0, dSpin or 0
	local dx, dy = sin(swivel), cos(swivel)
	local lx, ly, lz = launchDir(swivel, loftDeg)
	local a = rad(noseDownDeg + (dNoseDeg or 0))
	local ca, sa = cos(a), sin(a)
	-- local z: the long axis, nose forward and down; r: the right-hand side
	local zx, zy, zz = dx * ca, dy * ca, -sa
	local rx, ry, rz = dy, -dx, 0
	-- local y = z x r (so r x y = z), then both turned by the roll about z
	local yx, yy, yz = zy * rz - zz * ry, zz * rx - zx * rz, zx * ry - zy * rx
	local c, s = cos(rad(rollDeg or 0)), sin(rad(rollDeg or 0))
	local Xx, Xy, Xz = c * rx + s * yx, c * ry + s * yy, c * rz + s * yz
	local Yx, Yy, Yz = -s * rx + c * yx, -s * ry + c * yy, -s * rz + c * yz
	local qw, qx, qy, qz = quat.fromAxes(Xx, Xy, Xz, Yx, Yy, Yz, zx, zy, zz)
	-- the turn: the spiral about z, a nose-up pitch about r (the wobble and
	-- the scatter's), a yaw about the kubb's own up (y, unrolled)
	local sp, pr = spinRate + dSpin, wobbleRate + dPitch
	return x, lineY, tw.flight.tune.handHeight, qw, qx, qy, qz,
		speed * lx, speed * ly, speed * lz,
		sp * zx + pr * rx + dYaw * yx, sp * zy + pr * ry + dYaw * yy, sp * zz + pr * rz + dYaw * yz
end

-- The swing's scatter of a drill's release: four normals (sd 1) from the
-- launch and the ground's seed when a test or tool fixed it, so a throw is
-- the same every time it is replayed and every other throw its own.
local function drillScatter(w, x, lineY, swivel, loftDeg, speed, spinRate, wobbleRate)
	local h = seedFrom(x, lineY, swivel, loftDeg, speed, spinRate, wobbleRate,
		w.groundSeedFixed and w.groundSeed or 0)
	local s = h % 2147483647
	if s <= 0 then s = s + 2147483646 end
	local function u()
		s = (s * 48271) % 2147483647
		return (s - 1) / 2147483646
	end
	for _ = 1, 4 do u() end
	local function normal()
		local u1 = u()
		if u1 < 1e-12 then u1 = 1e-12 end
		return sqrt(-2 * math.log(u1)) * cos(2 * math.pi * u())
	end
	return normal(), normal(), normal(), normal()
end

-- launchDrill throws kubb `id` with drillLaunchState and the swing's scatter
-- (drill.tune: pitchSdDps, yawSdDps, spinSd, noseSdDeg, each times
-- 1 + scatterJerk x the jerk read from wobbleRate against drill.tune.wobbleRate).
-- On the ground it is a plain kubb, like any other piece.
function world.launchDrill(w, id, x, lineY, swivel, loftDeg, speed, noseDownDeg, rollDeg, spinRate,
		wobbleRate)
	local dt = tw.drill.tune
	wobbleRate = wobbleRate or 0
	local jerk = wobbleRate / dt.wobbleRate
	if jerk < 0 then jerk = -jerk end
	if jerk > 1 then jerk = 1 end
	local k = 1 + dt.scatterJerk * jerk
	local n1, n2, n3, n4 = drillScatter(w, x, lineY, swivel, loftDeg, speed, spinRate, wobbleRate)
	local b = world.launch(w, "kubb", id, world.drillLaunchState(x, lineY, swivel, loftDeg, speed,
		noseDownDeg, rollDeg, spinRate, wobbleRate,
		n1 * rad(dt.pitchSdDps) * k, n2 * rad(dt.yawSdDps) * k, n3 * dt.spinSd * k, n4 * dt.noseSdDeg * k))
	b.aeroK = world.tune.aeroK
	return b
end

-- ---------------------------------------------------------------------------
-- The solver's contacts
--
-- Speed on the device (docs/notes/physics.md "Physics", device costs): a Lua function
-- call costs about 9 us there, a C call (math.sqrt, math.abs, math.min) about
-- 4 us and every switch to another table a cache miss, so the hot paths below
-- are written out in full: no helper calls per pair, per contact or per pass,
-- comparisons instead of math.abs/min/max, and each solver contact is one
-- record (the array part of one table, read with constant indices) rather than
-- sixty parallel arrays. The arithmetic is the same as the plain version, term
-- for term and in the same order, so results are unchanged. Ground contacts
-- (normal +z, tangents +x and +y, nothing on the other side) and contacts
-- with a sleeping or static body (nothing moves on the other side) skip the
-- terms that are zero.

local C = collide.C
local cA, cB, cSlot = C.A, C.B, C.slot
local cPx, cPy, cPz, cNx, cNy, cNz, cSep = C.px, C.py, C.pz, C.nx, C.ny, C.nz, C.sep

-- Record fields. Kind: 1 ground, 2 two awake bodies, 3 B asleep or static.
local K_A <const>, K_B <const>, K_KIND <const>, K_IDX <const> = 1, 2, 3, 4
local K_NX <const>, K_NY <const>, K_NZ <const> = 5, 6, 7
local K_T1X <const>, K_T1Y <const>, K_T1Z <const>, K_T2X <const>, K_T2Y <const>, K_T2Z <const> = 8, 9, 10, 11, 12, 13
-- A's angular terms: (ra x d) and I^-1 (ra x d) for d = n, t1, t2; then B's
local K_ANX <const>, K_ANY <const>, K_ANZ <const>, K_WANX <const>, K_WANY <const>, K_WANZ <const> = 14, 15, 16, 17, 18, 19
local K_A1X <const>, K_A1Y <const>, K_A1Z <const>, K_WA1X <const>, K_WA1Y <const>, K_WA1Z <const> = 20, 21, 22, 23, 24, 25
local K_A2X <const>, K_A2Y <const>, K_A2Z <const>, K_WA2X <const>, K_WA2Y <const>, K_WA2Z <const> = 26, 27, 28, 29, 30, 31
local K_BNX <const>, K_BNY <const>, K_BNZ <const>, K_WBNX <const>, K_WBNY <const>, K_WBNZ <const> = 32, 33, 34, 35, 36, 37
local K_B1X <const>, K_B1Y <const>, K_B1Z <const>, K_WB1X <const>, K_WB1Y <const>, K_WB1Z <const> = 38, 39, 40, 41, 42, 43
local K_B2X <const>, K_B2Y <const>, K_B2Z <const>, K_WB2X <const>, K_WB2Y <const>, K_WB2Z <const> = 44, 45, 46, 47, 48, 49
local K_MN <const>, K_MT1 <const>, K_MT2 <const> = 50, 51, 52   -- effective masses
local K_BIAS <const>, K_RELAX <const> = 53, 54                  -- velocity targets with and without the push
local K_V0 <const>, K_MU <const>, K_E <const> = 55, 56, 57
local K_LN <const>, K_LT1 <const>, K_LT2 <const> = 58, 59, 60   -- accumulated impulses
local K_LNMAX <const> = 61                                      -- largest normal impulse seen
local K_REST <const> = 62                                       -- a bounce pass's velocity target

local REC = {}   -- the records of this step's active contacts, 1 .. nRec (reused)
local nRec = 0
local BOUNCE = {}   -- the records a bounce pass solves, 1 .. nBounce (reused)

-- Per body, filled each step: position, bounding radius, awake, speed bound.
local BX, BY, BZ, BR, AW, SPD, NXT = {}, {}, {}, {}, {}, {}, {}
-- Per awake body, its velocity before this step's forces (world.step stage 1),
-- for the trapezoid move of a body with no contact (stage 5)
local OVX, OVY, OVZ = {}, {}, {}
-- Bodies woken in this step's pair loop (indices), and for each the index below
-- which its pairs with sleepers were passed untested (world.step).
local WK, WLO = {}, {}
local WT, WPOS = {}, {}

-- Implicit gyroscopic step (Bullet's computeGyroscopicImpulseImplicit_Body):
-- one Newton step of I w' = I w - dt w' x I w' in the body frame. Keeps a
-- spinning baton or kubb precessing correctly without blowing up.
-- The air's drag on the thrown piece in flight (audit 8, 2026-11-16; the
-- wind, Jamie and Tyler, 2026-11-14): k |r| r with r = wind - v, the air's
-- velocity past it, and k = 0.5 rho Cd A / m per kind (b.dragK,
-- tw.flight.tune.dragK, where the figures and their sources are). Still air
-- or wind, the same quadratic drag; the aim solves with it in still air
-- (flight.carry). Applied by world.step and the lone step alike (written out
-- there, term for term: no call per step), right after gravity, only to
-- w.projectile until its first contact: after that the
-- pieces move slowly and briefly through the air (a kubb knocked flying at
-- 3 m/s for 0.3 s would lose about 5 cm/s) and the ground's forces dwarf it.
local function airDrag(w, b, dt)
	local k = b.dragK
	local rx, ry, rz = w.windX - b.vx, w.windY - b.vy, -b.vz
	local kd = k * dt * sqrt(rx * rx + ry * ry + rz * rz)
	b.vx, b.vy, b.vz = b.vx + kd * rx, b.vy + kd * ry, b.vz + kd * rz
end
world.airDrag = airDrag

-- The air's turn on the thrown piece in flight (2026-11-16, "Drilling"): a
-- block moving at an angle to its long axis is turned broadside by the air
-- (the slender-body, Munk, moment), tau = K (v . z)(v x z) with z the long
-- axis and K = rho (k2 - k1) volume (world.tune.aeroK per kind). A spiral
-- turns that into a precession, so the nose follows the flight path; with
-- too little spin the kubb tumbles. Applied like airDrag: only to
-- w.projectile until its first contact. The step applies it in substeps,
-- in the kubb's frame (flightTurn); this is the same term in world axes.
local function aeroTurn(w, b, dt)
	local k = b.aeroK
	if not k or k == 0 then return end
	local vx, vy, vz = b.vx, b.vy, b.vz
	if w.windOn then vx, vy = vx - w.windX, vy - w.windY end
	local zx, zy, zz = b.r13, b.r23, b.r33
	local s = k * dt * (vx * zx + vy * zy + vz * zz)
	-- angular impulse s (v x z), through the world inverse inertia
	local tx, ty, tz = s * (vy * zz - vz * zy), s * (vz * zx - vx * zz), s * (vx * zy - vy * zx)
	b.wx = b.wx + b.i11 * tx + b.i12 * ty + b.i13 * tz
	b.wy = b.wy + b.i12 * tx + b.i22 * ty + b.i23 * tz
	b.wz = b.wz + b.i13 * tx + b.i23 * ty + b.i33 * tz
end
world.aeroTurn = aeroTurn

local function gyro(b, dt)
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 =
		b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33
	local wx, wy, wz = b.wx, b.wy, b.wz
	-- body frame
	local ox = r11 * wx + r21 * wy + r31 * wz
	local oy = r12 * wx + r22 * wy + r32 * wz
	local oz = r13 * wx + r23 * wy + r33 * wz
	local Ix, Iy, Iz = b.Ix, b.Iy, b.Iz
	local ix, iy, iz = Ix * ox, Iy * oy, Iz * oz
	-- f = dt * (o x I o)
	local fx = dt * (oy * iz - oz * iy)
	local fy = dt * (oz * ix - ox * iz)
	local fz = dt * (ox * iy - oy * ix)
	if fx * fx + fy * fy + fz * fz < 1e-20 then return end
	-- J = I + dt (skew(o) I - skew(I o))
	local a11 = Ix
	local a12 = dt * (-oz * Iy + iz)
	local a13 = dt * (oy * Iz - iy)
	local a21 = dt * (oz * Ix - iz)
	local a22 = Iy
	local a23 = dt * (-ox * Iz + ix)
	local a31 = dt * (-oy * Ix + iy)
	local a32 = dt * (ox * Iy - ix)
	local a33 = Iz
	-- solve J d = f (Cramer)
	local c11 = a22 * a33 - a23 * a32
	local c12 = a23 * a31 - a21 * a33
	local c13 = a21 * a32 - a22 * a31
	local det = a11 * c11 + a12 * c12 + a13 * c13
	if det < 1e-30 and det > -1e-30 then return end
	local inv = 1 / det
	local dx = (c11 * fx + (a13 * a32 - a12 * a33) * fy + (a12 * a23 - a13 * a22) * fz) * inv
	local dy = (c12 * fx + (a11 * a33 - a13 * a31) * fy + (a13 * a21 - a11 * a23) * fz) * inv
	local dz = (c13 * fx + (a12 * a31 - a11 * a32) * fy + (a11 * a22 - a12 * a21) * fz) * inv
	ox, oy, oz = ox - dx, oy - dy, oz - dz
	b.wx = r11 * ox + r12 * oy + r13 * oz
	b.wy = r21 * ox + r22 * oy + r23 * oz
	b.wz = r31 * ox + r32 * oy + r33 * oz
end

-- A drilled kubb's turn in flight (the projectile with an air's turn,
-- b.aeroK, until its first contact), in n substeps of dt / n: a kubb
-- spinning at 25 rad/s or more precesses too far in one 1/240 s step
-- (docs/notes/physics.md, "Physics", "The turn in flight"). It works in the kubb's own
-- frame, where both terms are cheap: the air's velocity past it (the wind
-- less its own velocity, constant over the step) is turned against the
-- kubb's spin each substep, the air's turn (aeroTurn's tau = K (v.z)(v x z))
-- is a kick to the two cross axes, and the gyroscopic term of a body with a
-- square section (Ix = Iy, every kubb) is an exact turn of the cross spin at
-- (Ix - Iz) wz / Ix (Euler's equations; Cayley's rotation, which keeps its
-- size). The attitude takes each substep's spin (q <- q + hs/2 q (0, w));
-- it is normalized and the rotation matrix, world inverse inertia and world
-- spin are made once at the end. Called by the lone step and by world.step's
-- stage 5, so the two stay identical; stage 1 applies neither term to it.
-- Written out: one call a step, no tables, one square root.
local function flightTurn(w, b, dt, n, useGyro)
	local hs = dt / n
	local h = 0.5 * hs
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 =
		b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33
	-- spin and the air's velocity past it, in the kubb's frame
	local wx, wy, wz = b.wx, b.wy, b.wz
	local ox = r11 * wx + r21 * wy + r31 * wz
	local oy = r12 * wx + r22 * wy + r32 * wz
	local oz = r13 * wx + r23 * wy + r33 * wz
	local vx, vy, vz = b.vx, b.vy, b.vz
	if w.windOn then vx, vy = vx - w.windX, vy - w.windY end
	local ux = r11 * vx + r21 * vy + r31 * vz
	local uy = r12 * vx + r22 * vy + r32 * vz
	local uz = r13 * vx + r23 * vy + r33 * vz
	local ka = (b.aeroK or 0) * hs
	local iIx, iIy = b.iIx, b.iIy
	-- the cross spin turns at gz x wz a second (0 without the gyroscopic term)
	local gz = useGyro and (b.Ix - b.Iz) * iIx * hs or 0
	local qw, qx, qy, qz = b.qw, b.qx, b.qy, b.qz
	for _ = 1, n do
		-- the air's turn: tau = K (v . z)(v x z), z the long axis = (0, 0, 1)
		local s = ka * uz
		ox, oy = ox + s * uy * iIx, oy - s * ux * iIy
		-- the gyroscopic term: (ox, oy) turned by -gz oz (Cayley)
		local t = 0.5 * gz * oz
		local d = 1 / (1 + t * t)
		local c, sn = (1 - t * t) * d, 2 * t * d
		ox, oy = c * ox + sn * oy, c * oy - sn * ox
		-- the attitude: q <- q + hs/2 q (0, o)
		qw, qx, qy, qz = qw - h * (qx * ox + qy * oy + qz * oz),
			qx + h * (qw * ox + qy * oz - qz * oy),
			qy + h * (qw * oy + qz * ox - qx * oz),
			qz + h * (qw * oz + qx * oy - qy * ox)
		-- the air's velocity in the turned frame: u <- u - hs o x u, to second order
		local cx, cy, cz = oy * uz - oz * uy, oz * ux - ox * uz, ox * uy - oy * ux
		local ex, ey, ez = oy * cz - oz * cy, oz * cx - ox * cz, ox * cy - oy * cx
		ux, uy, uz = ux - hs * cx + h * hs * ex, uy - hs * cy + h * hs * ey, uz - hs * cz + h * hs * ez
	end
	local qn = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
	if qn < 1e-12 then
		qw, qx, qy, qz = 1, 0, 0, 0
	else
		qn = 1 / qn
		qw, qx, qy, qz = qw * qn, qx * qn, qy * qn, qz * qn
	end
	b.qw, b.qx, b.qy, b.qz = qw, qx, qy, qz
	local xx, yy, zz = qx * qx, qy * qy, qz * qz
	local xy, xz, yz = qx * qy, qx * qz, qy * qz
	local xw, yw, zw = qw * qx, qw * qy, qw * qz
	r11, r12, r13 = 1 - 2 * (yy + zz), 2 * (xy - zw), 2 * (xz + yw)
	r21, r22, r23 = 2 * (xy + zw), 1 - 2 * (xx + zz), 2 * (yz - xw)
	r31, r32, r33 = 2 * (xz - yw), 2 * (yz + xw), 1 - 2 * (xx + yy)
	b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33 = r11, r12, r13, r21, r22, r23, r31, r32, r33
	local ia, ic, ie = iIx, iIy, b.iIz
	b.i11 = r11 * r11 * ia + r12 * r12 * ic + r13 * r13 * ie
	b.i12 = r11 * r21 * ia + r12 * r22 * ic + r13 * r23 * ie
	b.i13 = r11 * r31 * ia + r12 * r32 * ic + r13 * r33 * ie
	b.i22 = r21 * r21 * ia + r22 * r22 * ic + r23 * r23 * ie
	b.i23 = r21 * r31 * ia + r22 * r32 * ic + r23 * r33 * ie
	b.i33 = r31 * r31 * ia + r32 * r32 * ic + r33 * r33 * ie
	-- the spin back in the world frame, by the new attitude
	b.wx = r11 * ox + r12 * oy + r13 * oz
	b.wy = r21 * ox + r22 * oy + r23 * oz
	b.wz = r31 * ox + r32 * oy + r33 * oz
end

-- How pointed the body meets the ground, 0..1. A box flat on a face is 0
-- (the load spreads, nothing digs); on an edge at 45 degrees or on a corner,
-- 1. A baton lying flat is 0; at 45 degrees or steeper, end first, 1.
local SQRT_HALF = math.sqrt(0.5)
local function pointed(b)
	if b.shape == 1 then
		local m = max(abs(b.r31), abs(b.r32), abs(b.r33))
		return min(1, (1 - m) / (1 - SQRT_HALF))
	end
	return min(1, abs(b.r33) / SQRT_HALF)
end
world.pointed = pointed

local function noteContact(w, b, other, px, py, pz)
	local rec = { t = w.time, x = px, y = py, z = pz, with = other and other.id or "ground" }
	if not w.firstContact then w.firstContact = rec end
	if other and not w.firstHit then w.firstHit = rec end
end

-- One sequential-impulse pass over records 1 .. n of list (REC, or the
-- bounce pass's BOUNCE), each held to its target r[tk] (K_BIAS, K_RELAX or
-- K_REST): the normal impulse, then the friction, capped at mu times the
-- normal impulse accumulated so far. Returns the largest change it made to
-- any impulse (N s), for the bounce passes' convergence test.
local function solve(tk, list, n)
	local dm = 0
	for i = 1, n do
		local r = list[i]
		local a, kind = r[K_A], r[K_KIND]
		local ima = a.im
		local avx, avy, avz, awx, awy, awz = a.vx, a.vy, a.vz, a.wx, a.wy, a.wz
		if kind == 1 then
			-- the ground: n = +z, t1 = +x, t2 = +y
			local anx, any = r[K_ANX], r[K_ANY]
			local vn = avz + awx * anx + awy * any
			local old = r[K_LN]
			local lam = old - r[K_MN] * (vn - r[tk])
			if lam < 0 then lam = 0 end
			r[K_LN] = lam
			if lam > r[K_LNMAX] then r[K_LNMAX] = lam end
			local d = lam - old
			if d ~= 0 then
				if d > dm then dm = d elseif -d > dm then dm = -d end
				avz = avz + ima * d
				awx, awy, awz = awx + d * r[K_WANX], awy + d * r[K_WANY], awz + d * r[K_WANZ]
			end
			local a1y, a1z, a2x, a2z = r[K_A1Y], r[K_A1Z], r[K_A2X], r[K_A2Z]
			local v1 = avx + awy * a1y + awz * a1z
			local v2 = avy + awx * a2x + awz * a2z
			local o1, o2 = r[K_LT1], r[K_LT2]
			local l1, l2 = o1 - r[K_MT1] * v1, o2 - r[K_MT2] * v2
			local cap = r[K_MU] * lam
			local m2 = l1 * l1 + l2 * l2
			if m2 > cap * cap then
				local s = (m2 > 0) and (cap / sqrt(m2)) or 0
				l1, l2 = l1 * s, l2 * s
			end
			r[K_LT1], r[K_LT2] = l1, l2
			local d1, d2 = l1 - o1, l2 - o2
			if d1 ~= 0 or d2 ~= 0 then
				if d1 > dm then dm = d1 elseif -d1 > dm then dm = -d1 end
				if d2 > dm then dm = d2 elseif -d2 > dm then dm = -d2 end
				avx, avy = avx + ima * d1, avy + ima * d2
				awx = awx + d1 * r[K_WA1X] + d2 * r[K_WA2X]
				awy = awy + d1 * r[K_WA1Y] + d2 * r[K_WA2Y]
				awz = awz + d1 * r[K_WA1Z] + d2 * r[K_WA2Z]
			end
			a.vx, a.vy, a.vz, a.wx, a.wy, a.wz = avx, avy, avz, awx, awy, awz
		elseif kind >= 3 then
			-- B asleep or static, or a landing on a tilted patch (4): nothing
			-- moves on the other side
			local nx, ny, nz = r[K_NX], r[K_NY], r[K_NZ]
			local vn = avx * nx + avy * ny + avz * nz
				+ awx * r[K_ANX] + awy * r[K_ANY] + awz * r[K_ANZ]
			local old = r[K_LN]
			local lam = old - r[K_MN] * (vn - r[tk])
			if lam < 0 then lam = 0 end
			r[K_LN] = lam
			if lam > r[K_LNMAX] then r[K_LNMAX] = lam end
			local d = lam - old
			if d ~= 0 then
				if d > dm then dm = d elseif -d > dm then dm = -d end
				avx, avy, avz = avx + ima * d * nx, avy + ima * d * ny, avz + ima * d * nz
				awx, awy, awz = awx + d * r[K_WANX], awy + d * r[K_WANY], awz + d * r[K_WANZ]
			end
			local t1x, t1y, t1z, t2x, t2y, t2z = r[K_T1X], r[K_T1Y], r[K_T1Z], r[K_T2X], r[K_T2Y], r[K_T2Z]
			local v1 = avx * t1x + avy * t1y + avz * t1z
				+ awx * r[K_A1X] + awy * r[K_A1Y] + awz * r[K_A1Z]
			local v2 = avx * t2x + avy * t2y + avz * t2z
				+ awx * r[K_A2X] + awy * r[K_A2Y] + awz * r[K_A2Z]
			local o1, o2 = r[K_LT1], r[K_LT2]
			local l1, l2 = o1 - r[K_MT1] * v1, o2 - r[K_MT2] * v2
			local cap = r[K_MU] * lam
			local m2 = l1 * l1 + l2 * l2
			if m2 > cap * cap then
				local s = (m2 > 0) and (cap / sqrt(m2)) or 0
				l1, l2 = l1 * s, l2 * s
			end
			r[K_LT1], r[K_LT2] = l1, l2
			local d1, d2 = l1 - o1, l2 - o2
			if d1 ~= 0 or d2 ~= 0 then
				if d1 > dm then dm = d1 elseif -d1 > dm then dm = -d1 end
				if d2 > dm then dm = d2 elseif -d2 > dm then dm = -d2 end
				local px, py, pz = d1 * t1x + d2 * t2x, d1 * t1y + d2 * t2y, d1 * t1z + d2 * t2z
				avx, avy, avz = avx + ima * px, avy + ima * py, avz + ima * pz
				awx = awx + d1 * r[K_WA1X] + d2 * r[K_WA2X]
				awy = awy + d1 * r[K_WA1Y] + d2 * r[K_WA2Y]
				awz = awz + d1 * r[K_WA1Z] + d2 * r[K_WA2Z]
			end
			a.vx, a.vy, a.vz, a.wx, a.wy, a.wz = avx, avy, avz, awx, awy, awz
		else
			-- two awake bodies
			local b = r[K_B]
			local imb = b.im
			local bvx, bvy, bvz, bwx, bwy, bwz = b.vx, b.vy, b.vz, b.wx, b.wy, b.wz
			local nx, ny, nz = r[K_NX], r[K_NY], r[K_NZ]
			local dvx, dvy, dvz = avx - bvx, avy - bvy, avz - bvz
			local vn = dvx * nx + dvy * ny + dvz * nz
				+ awx * r[K_ANX] + awy * r[K_ANY] + awz * r[K_ANZ]
				- bwx * r[K_BNX] - bwy * r[K_BNY] - bwz * r[K_BNZ]
			local old = r[K_LN]
			local lam = old - r[K_MN] * (vn - r[tk])
			if lam < 0 then lam = 0 end
			r[K_LN] = lam
			if lam > r[K_LNMAX] then r[K_LNMAX] = lam end
			local d = lam - old
			if d ~= 0 then
				if d > dm then dm = d elseif -d > dm then dm = -d end
				avx, avy, avz = avx + ima * d * nx, avy + ima * d * ny, avz + ima * d * nz
				awx, awy, awz = awx + d * r[K_WANX], awy + d * r[K_WANY], awz + d * r[K_WANZ]
				bvx, bvy, bvz = bvx - imb * d * nx, bvy - imb * d * ny, bvz - imb * d * nz
				bwx, bwy, bwz = bwx - d * r[K_WBNX], bwy - d * r[K_WBNY], bwz - d * r[K_WBNZ]
			end
			local t1x, t1y, t1z, t2x, t2y, t2z = r[K_T1X], r[K_T1Y], r[K_T1Z], r[K_T2X], r[K_T2Y], r[K_T2Z]
			dvx, dvy, dvz = avx - bvx, avy - bvy, avz - bvz
			local v1 = dvx * t1x + dvy * t1y + dvz * t1z
				+ awx * r[K_A1X] + awy * r[K_A1Y] + awz * r[K_A1Z]
				- bwx * r[K_B1X] - bwy * r[K_B1Y] - bwz * r[K_B1Z]
			local v2 = dvx * t2x + dvy * t2y + dvz * t2z
				+ awx * r[K_A2X] + awy * r[K_A2Y] + awz * r[K_A2Z]
				- bwx * r[K_B2X] - bwy * r[K_B2Y] - bwz * r[K_B2Z]
			local o1, o2 = r[K_LT1], r[K_LT2]
			local l1, l2 = o1 - r[K_MT1] * v1, o2 - r[K_MT2] * v2
			local cap = r[K_MU] * lam
			local m2 = l1 * l1 + l2 * l2
			if m2 > cap * cap then
				local s = (m2 > 0) and (cap / sqrt(m2)) or 0
				l1, l2 = l1 * s, l2 * s
			end
			r[K_LT1], r[K_LT2] = l1, l2
			local d1, d2 = l1 - o1, l2 - o2
			if d1 ~= 0 or d2 ~= 0 then
				if d1 > dm then dm = d1 elseif -d1 > dm then dm = -d1 end
				if d2 > dm then dm = d2 elseif -d2 > dm then dm = -d2 end
				local px, py, pz = d1 * t1x + d2 * t2x, d1 * t1y + d2 * t2y, d1 * t1z + d2 * t2z
				avx, avy, avz = avx + ima * px, avy + ima * py, avz + ima * pz
				awx = awx + d1 * r[K_WA1X] + d2 * r[K_WA2X]
				awy = awy + d1 * r[K_WA1Y] + d2 * r[K_WA2Y]
				awz = awz + d1 * r[K_WA1Z] + d2 * r[K_WA2Z]
				bvx, bvy, bvz = bvx - imb * px, bvy - imb * py, bvz - imb * pz
				bwx = bwx - d1 * r[K_WB1X] - d2 * r[K_WB2X]
				bwy = bwy - d1 * r[K_WB1Y] - d2 * r[K_WB2Y]
				bwz = bwz - d1 * r[K_WB1Z] - d2 * r[K_WB2Z]
			end
			a.vx, a.vy, a.vz, a.wx, a.wy, a.wz = avx, avy, avz, awx, awy, awz
			b.vx, b.vy, b.vz, b.wx, b.wy, b.wz = bvx, bvy, bvz, bwx, bwy, bwz
		end
	end
	return dm
end

-- Rolling resistance: an angular impulse of lever * normal impulse against
-- the body's spin, never more than stops it.
local function rollResist(b, lever, impulse)
	local L = lever * impulse
	if L <= 0 then return end
	local wx, wy, wz = b.wx, b.wy, b.wz
	local w2 = wx * wx + wy * wy + wz * wz
	if w2 < 1e-12 then return end
	local wn = sqrt(w2)
	local ux, uy, uz = wx / wn, wy / wn, wz / wn
	local ix = b.i11 * ux + b.i12 * uy + b.i13 * uz
	local iy = b.i12 * ux + b.i22 * uy + b.i23 * uz
	local iz = b.i13 * ux + b.i23 * uy + b.i33 * uz
	-- angular impulse that stops the spin along u: wn / (u . I^-1 u)
	local stop = wn / (ux * ix + uy * iy + uz * iz)
	if L >= stop then
		b.wx, b.wy, b.wz = 0, 0, 0
	else
		b.wx, b.wy, b.wz = wx - L * ix, wy - L * iy, wz - L * iz
	end
end

-- ---------------------------------------------------------------------------
-- The step

local boxBox, capsuleBox, capsuleCapsule = collide.boxBox, collide.capsuleBox, collide.capsuleCapsule
local groundBox, groundCapsule = collide.groundBox, collide.groundCapsule

-- The lone flight. A step with exactly one body awake that is clear of the
-- ground and above everything else (its lowest point higher than the
-- highest point of every sleeping or static body, by more than the contact
-- margin the step could use) finds no contact: the full step would then only
-- apply gravity and the gyroscopic term, move and turn that body and do its
-- bookkeeping. loneStep does exactly that and nothing else, in the same
-- order with the same arithmetic, so results are bit-identical; it saves
-- every loop over the other bodies (a thrown baton spends about half its
-- steps like this). The test is conservative: it bounds the speeds after
-- the forces from above and keeps loneSlack (m) in hand for rounding.
world.loneFlight = true
local LONE_SLACK <const> = 0.001
local COS_END <const> = 0.866   -- cos 30 degrees: within this of upright is "on an end"

local function loneRefresh(w)
	local bodies = w.bodies
	local lone, count, top = false, 0, -1e9
	for i = 1, w.n do
		local b = bodies[i]
		if b.awake then
			count = count + 1
			lone = b
		else
			local h = b.z + b.radius
			if h > top then top = h end
		end
	end
	w.lone = (count == 1) and lone or false
	w.loneTop = top
	w.loneEpoch = epoch
end

-- One step of the lone body b, or false if it might touch something.
local function loneStep(w, b, t, P)
	local dt, g = t.dt, t.g
	local vx, vy, vz, wx, wy, wz = b.vx, b.vy, b.vz, b.wx, b.wy, b.wz
	local r = b.radius
	-- after the forces: |v| grows by at most g dt; the gyroscopic step turns
	-- the spin and changes its size by far less than half
	local avz = vz < 0 and -vz or vz
	local spin = sqrt(wx * wx + wy * wy + wz * wz) * 1.5 * r
	local low = b.z - r - t.margin - LONE_SLACK
	-- the ground: every point is above the ground contact margin
	if low <= (avz + g * dt + spin) * dt then return false end
	-- the pairs: higher than every other body's bounding sphere by the reach
	if low - w.loneTop <= (sqrt(vx * vx + vy * vy + vz * vz) + g * dt + spin) * dt then return false end
	local pc, pt
	if P then pc = P.clock; pt = pc() end
	-- 1. forces
	w.awakeCount = 1
	b.vz = vz - g * dt
	if b == w.projectile and not w.firstContact then
		-- the air's drag (airDrag, written out)
		local k = b.dragK
		local rx, ry, rz = w.windX - b.vx, w.windY - b.vy, -b.vz
		local kd = k * dt * sqrt(rx * rx + ry * ry + rz * rz)
		b.vx, b.vy, b.vz = b.vx + kd * rx, b.vy + kd * ry, b.vz + kd * rz
	end
	-- the turn: a drill in flight takes the air's turn and the gyroscopic
	-- term in substeps as it moves (flightTurn); anything else here
	local drillTurn = b.aeroK and b == w.projectile and not w.firstContact
	if not drillTurn and t.gyro then gyro(b, dt) end
	b.groundImpulse = 0
	b.plough = 0   -- in the air: as the full step does for a body off the ground
	-- 2-4. no contacts
	C.n = 0
	w.contacts = 0
	nRec = 0
	-- 5. integrate (no contact: the trapezoid move, as world.step's stage 5)
	local h = 0.5 * dt
	b.x, b.y, b.z = b.x + (vx + b.vx) * h, b.y + (vy + b.vy) * h, b.z + (vz + b.vz) * h
	if drillTurn then
		flightTurn(w, b, dt, t.flightTurns, t.gyro)
	else
		local qw, qx, qy, qz = b.qw, b.qx, b.qy, b.qz
		wx, wy, wz = b.wx, b.wy, b.wz
		local dw = -(wx * qx + wy * qy + wz * qz)
		local dx = wx * qw + wy * qz - wz * qy
		local dy = wy * qw + wz * qx - wx * qz
		local dz = wz * qw + wx * qy - wy * qx
		qw, qx, qy, qz = qw + h * dw, qx + h * dx, qy + h * dy, qz + h * dz
		local qn = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
		if qn < 1e-12 then
			qw, qx, qy, qz = 1, 0, 0, 0
		else
			qn = 1 / qn
			qw, qx, qy, qz = qw * qn, qx * qn, qy * qn, qz * qn
		end
		b.qw, b.qx, b.qy, b.qz = qw, qx, qy, qz
		local xx, yy, zz = qx * qx, qy * qy, qz * qz
		local xy, xz, yz = qx * qy, qx * qz, qy * qz
		local xw, yw, zw = qw * qx, qw * qy, qw * qz
		local r11, r12, r13 = 1 - 2 * (yy + zz), 2 * (xy - zw), 2 * (xz + yw)
		local r21, r22, r23 = 2 * (xy + zw), 1 - 2 * (xx + zz), 2 * (yz - xw)
		local r31, r32, r33 = 2 * (xz - yw), 2 * (yz + xw), 1 - 2 * (xx + yy)
		b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33 = r11, r12, r13, r21, r22, r23, r31, r32, r33
		local ia, ic, ie = b.iIx, b.iIy, b.iIz
		b.i11 = r11 * r11 * ia + r12 * r12 * ic + r13 * r13 * ie
		b.i12 = r11 * r21 * ia + r12 * r22 * ic + r13 * r23 * ie
		b.i13 = r11 * r31 * ia + r12 * r32 * ic + r13 * r33 * ie
		b.i22 = r21 * r21 * ia + r22 * r22 * ic + r23 * r23 * ie
		b.i23 = r21 * r31 * ia + r22 * r32 * ic + r23 * r33 * ie
		b.i33 = r31 * r31 * ia + r32 * r32 * ic + r33 * r33 * ie
	end
	-- 6-8. nothing to relax, bounce or store; the tail for b (no ground
	-- impulse: no rolling resistance, and it cannot fall asleep)
	w.time = w.time + dt
	w.steps = w.steps + 1
	w.loneStep = w.steps
	if b.dig > 0 then
		b.dig = b.dig * exp(-dt / w.surface.digTime)
		if b.dig < 1e-5 then b.dig = 0 end
	end
	local sinTopple = sin(rad(t.toppleDeg))
	local r33 = b.r33
	if b.shape == 1 and not b.toppled and r33 <= sinTopple and r33 >= -sinTopple then b.toppled = true; b.toppleT = w.time end
	local x, y = b.x, b.y
	local half, len, om = t.pitchHalfWidth, t.pitchLength, t.outMargin
	if x > half + om or x < -(half + om) or y < -om or y > len + om then b.leftPitch = true end
	b.sleepTime = 0
	if P then P.lone = P.lone + pc() - pt end
	return true
end

function world.step(w)
	local t = world.tune
	local P = world.prof
	if world.loneFlight then
		if w.loneEpoch ~= epoch then loneRefresh(w) end
		local b = w.lone
		if b and loneStep(w, b, t, P) then return w end
	end
	local dt = t.dt
	local invDt = 1 / dt
	local surf = w.surface
	local biteFade = 1 - dt / (surf.biteTime or 1)
	local bodies, nb = w.bodies, w.n
	local stamp = w.steps
	local pc, pt
	if P then pc = P.clock; pt = pc() end
	local g = t.g

	-- 1. forces
	local awakeCount = 0
	local useGyro = t.gyro
	local inAir = not w.firstContact
	local proj = w.projectile
	for i = 1, nb do
		local b = bodies[i]
		if b.awake then
			awakeCount = awakeCount + 1
			OVX[i], OVY[i], OVZ[i] = b.vx, b.vy, b.vz
			b.vz = b.vz - g * dt
			if inAir and b == proj then
				-- the air's drag (airDrag, written out)
				local k = b.dragK
				local rx, ry, rz = w.windX - b.vx, w.windY - b.vy, -b.vz
				local kd = k * dt * sqrt(rx * rx + ry * ry + rz * rz)
				b.vx, b.vy, b.vz = b.vx + kd * rx, b.vy + kd * ry, b.vz + kd * rz
			end
			-- a drill in flight takes the air's turn and the gyroscopic term
			-- in substeps as it moves (stage 5, flightTurn)
			if useGyro and not (inAir and b == proj and b.aeroK) then gyro(b, dt) end
			b.groundImpulse = 0
		end
	end
	w.awakeCount = awakeCount

	if P then local now = pc(); P.forces = P.forces + now - pt; pt = now end
	-- 2. contacts: pairs, then the ground
	C.n = 0
	-- per body: position, radius, awake and the speed bound of any of its
	-- points (for the speculative margin)
	for i = 1, nb do
		local b = bodies[i]
		BX[i], BY[i], BZ[i], BR[i] = b.x, b.y, b.z, b.radius
		local aw = b.awake
		AW[i] = aw
		if aw then
			local vx, vy, vz, wx, wy, wz = b.vx, b.vy, b.vz, b.wx, b.wy, b.wz
			SPD[i] = sqrt(vx * vx + vy * vy + vz * vz) + sqrt(wx * wx + wy * wy + wz * wz) * b.radius
		else
			SPD[i] = 0
		end
	end
	-- NXT[k]: the first awake body at k or after (nb + 1: none), so a
	-- sleeping body's pairs jump from one awake partner to the next
	local nxt = nb + 1
	for k = nb, 1, -1 do
		if AW[k] then nxt = k end
		NXT[k] = nxt
	end
	local tmargin = t.margin
	local wakeLin2, wakeAng2 = t.wakeLin * t.wakeLin, t.wakeAng * t.wakeAng
	local nWoke = 0
	for i = 1, nb do
		local sa = SPD[i]
		local ax, ay, az, ar = BX[i], BY[i], BZ[i], BR[i]
		local j = i + 1
		while j <= nb do
			if not AW[i] then j = NXT[j] end
			if j > nb then break end
			do
				local margin = tmargin + (sa + SPD[j]) * dt
				local dx, dy, dz = ax - BX[j], ay - BY[j], az - BZ[j]
				local reach = ar + BR[j] + margin
				if dx * dx + dy * dy + dz * dz < reach * reach then
					local a, b = bodies[i], bodies[j]
					local before = C.n
					if P then P.narrow = P.narrow + 1 end
					if a.shape == 1 then
						if b.shape == 1 then boxBox(a, b, margin)
						else capsuleBox(b, a, margin) end
					else
						if b.shape == 1 then capsuleBox(a, b, margin)
						else capsuleCapsule(a, b, margin) end
					end
					if C.n > before then
						-- wake a sleeper that an awake, moving body touches
						local o, s = nil, 0
						if not a.awake and not a.static then
							if b.vx * b.vx + b.vy * b.vy + b.vz * b.vz > wakeLin2
								or b.wx * b.wx + b.wy * b.wy + b.wz * b.wz > wakeAng2
								or b.wokeStep == stamp then o, s = a, i end
						elseif not b.awake and not b.static then
							if a.vx * a.vx + a.vy * a.vy + a.vz * a.vz > wakeLin2
								or a.wx * a.wx + a.wy * a.wy + a.wz * a.wz > wakeAng2
								or a.wokeStep == stamp then o, s = b, j end
						end
						if o then
							epoch = epoch + 1
							o.awake = true
							o.everAwake = true
							o.sleepTime = 0
							o.vz = o.vz - g * dt
							o.groundImpulse = 0
							AW[s] = true
							local vx, vy, vz, wx, wy, wz = o.vx, o.vy, o.vz, o.wx, o.wy, o.wz
							SPD[s] = sqrt(vx * vx + vy * vy + vz * vz) + sqrt(wx * wx + wy * wy + wz * wz) * o.radius
							for k = s, 1, -1 do
								if NXT[k] > s then NXT[k] = s else break end
							end
							-- the group it rests against wakes with it (below)
							o.wokeStep = stamp
							nWoke = nWoke + 1
							WK[nWoke] = s
							WLO[nWoke] = (s == i) and j or s
							WT[s] = i * (nb + 1) + j
							WPOS[s] = nWoke
						end
					end
				end
			end
			j = j + 1
		end
	end
	-- A body woken this step wakes every sleeper it touches, and so on through
	-- the group (Jamie, 2026-11-15: a baton bounced off four field kubbs
	-- standing in a tight row). A sleeper is immovable to the solver, so a
	-- kubb woken by a blow and leaning on a sleeping neighbour stood braced
	-- against a wall for that step: the blow went into the wall and was gone,
	-- and the neighbour woke a step later to nothing. The loop above wakes
	-- the pairs it still comes to (wokeStep); these are the pairs it had
	-- already passed while both slept. Two bodies both woken this step, or a
	-- woken body and a stake, can also be a pair the loop passed while neither
	-- was awake (a baton wakes two kubbs that touch each other): their contact
	-- is made here too, once, so they do not sink into each other for a step
	-- (Codex on the web game's sync). WT is where the pair loop was when a
	-- body woke (past its end for one woken here): a pair it came to before
	-- both of those was skipped. WPOS is a body's place in the queue; the
	-- earlier of two woken bodies makes their contact. Nothing runs here in a
	-- step that wakes nobody.
	if nWoke > 0 then
		local q = 1
		while q <= nWoke do
			local s, lo = WK[q], WLO[q]
			local o = bodies[s]
			local ts = WT[s]
			for k = 1, nb do
				if k ~= s and (AW[k] or bodies[k].static) then
					-- awake already, or a stake: only the contact, nobody wakes
					local c = bodies[k]
					local pt = (k < s) and (k * (nb + 1) + s) or (s * (nb + 1) + k)
					local skipped = ts > pt
					if skipped and not c.static then
						skipped = c.wokeStep == stamp and WT[k] > pt and WPOS[k] > q
					end
					if skipped then
						local margin = tmargin + (SPD[s] + SPD[k]) * dt
						local dx, dy, dz = BX[s] - BX[k], BY[s] - BY[k], BZ[s] - BZ[k]
						local reach = BR[s] + BR[k] + margin
						if dx * dx + dy * dy + dz * dz < reach * reach then
							local a, b = o, c
							if k < s then a, b = c, o end
							if P then P.narrow = P.narrow + 1 end
							if a.shape == 1 then
								if b.shape == 1 then boxBox(a, b, margin)
								else capsuleBox(b, a, margin) end
							else
								if b.shape == 1 then capsuleBox(a, b, margin)
								else capsuleCapsule(a, b, margin) end
							end
						end
					end
				elseif k ~= s and k < lo then
					local c = bodies[k]
					do
						local margin = tmargin + SPD[s] * dt
						local dx, dy, dz = BX[s] - BX[k], BY[s] - BY[k], BZ[s] - BZ[k]
						local reach = BR[s] + BR[k] + margin
						if dx * dx + dy * dy + dz * dz < reach * reach then
							local a, b = o, c
							if k < s then a, b = c, o end
							local before = C.n
							if P then P.narrow = P.narrow + 1 end
							if a.shape == 1 then
								if b.shape == 1 then boxBox(a, b, margin)
								else capsuleBox(b, a, margin) end
							else
								if b.shape == 1 then capsuleBox(a, b, margin)
								else capsuleCapsule(a, b, margin) end
							end
							if C.n > before then
								epoch = epoch + 1
								c.awake = true
								c.everAwake = true
								c.sleepTime = 0
								c.vz = c.vz - g * dt
								c.groundImpulse = 0
								c.wokeStep = stamp
								AW[k] = true
								local vx, vy, vz, wx, wy, wz = c.vx, c.vy, c.vz, c.wx, c.wy, c.wz
								SPD[k] = sqrt(vx * vx + vy * vy + vz * vz) + sqrt(wx * wx + wy * wy + wz * wz) * c.radius
								nWoke = nWoke + 1
								WK[nWoke] = k
								WLO[nWoke] = nb + 1
								WT[k] = (nb + 1) * (nb + 1)
								WPOS[k] = nWoke
							end
						end
					end
				end
			end
			q = q + 1
		end
	end
	if P then local now = pc(); P.pairs = P.pairs + now - pt; pt = now end
	local nPair = C.n
	for i = 1, nb do
		local b = bodies[i]
		if b.awake then
			local nvz = -b.vz
			if nvz < 0 then nvz = 0 end
			local wx, wy, wz = b.wx, b.wy, b.wz
			local margin = tmargin + nvz * dt + sqrt(wx * wx + wy * wy + wz * wz) * b.radius * dt
			if b.shape == 1 then groundBox(b, margin) else groundCapsule(b, margin) end
		end
	end
	if P then local now = pc(); P.ground = P.ground + now - pt; pt = now end
	local n = C.n
	w.contacts = n

	-- 3. prepare: one record per contact with an awake body
	local slop, pushRate, maxPush = t.slop, t.pushRate, t.maxPush
	local warmF, pairMu, pairE = t.warm, t.pairMu, t.pairE
	local warm = false
	local m = 0
	for i = 1, n do
		local a, b = cA[i], cB[i]
		local nx, ny, nz = cNx[i], cNy[i], cNz[i]
		if not a.awake then
			-- A is asleep: if B is awake, make B the dynamic side
			if b and b.awake then
				a, b = b, a
				nx, ny, nz = -nx, -ny, -nz
			else
				a = nil
			end
		end
		if a and b and not b.awake then b = false end
		if a then
			m = m + 1
			local r = REC[m]
			if not r then r = {}; REC[m] = r end
			r[K_A], r[K_B], r[K_IDX] = a, b, i
			a.cStep = stamp
			if b then b.cStep = stamp end
			local px, py, pz = cPx[i], cPy[i], cPz[i]
			local ax, ay, az = a.x, a.y, a.z
			local rax, ray, raz = px - ax, py - ay, pz - az
			local ima = a.im
			local i11, i12, i13, i22, i23, i33 = a.i11, a.i12, a.i13, a.i22, a.i23, a.i33
			local avx, avy, avz, awx, awy, awz = a.vx, a.vy, a.vz, a.wx, a.wy, a.wz
			local sep = cSep[i]
			local bias, relax
			if sep > 0 then
				bias, relax = -sep * invDt, -sep * invDt
			elseif sep < -slop then
				bias = pushRate * (-sep - slop) * invDt
				if bias > maxPush then bias = maxPush end
				relax = 0
			else
				bias, relax = 0, 0
			end
			r[K_BIAS], r[K_RELAX] = bias, relax
			r[K_LT1], r[K_LT2] = 0, 0
			r[K_LNMAX] = 0
			if i > nPair then
				-- the ground: n = +z, t1 = +x, t2 = +y. (ra x d) and I^-1 (ra x d)
				-- with the zero terms left out.
				r[K_KIND] = 1
				r[K_NX], r[K_NY], r[K_NZ] = 0, 0, 1
				r[K_T1X], r[K_T1Y], r[K_T1Z], r[K_T2X], r[K_T2Y], r[K_T2Z] = 1, 0, 0, 0, 1, 0
				-- n: j = (ray, -rax, 0)
				local jx, jy = ray, -rax
				local wx, wy, wz = i11 * jx + i12 * jy, i12 * jx + i22 * jy, i13 * jx + i23 * jy
				r[K_ANX], r[K_ANY], r[K_ANZ], r[K_WANX], r[K_WANY], r[K_WANZ] = jx, jy, 0, wx, wy, wz
				local kn = ima + (jx * wx + jy * wy)
				-- t1: j = (0, raz, -ray)
				jy = raz
				local jz = -ray
				wx, wy, wz = i12 * jy + i13 * jz, i22 * jy + i23 * jz, i23 * jy + i33 * jz
				r[K_A1X], r[K_A1Y], r[K_A1Z], r[K_WA1X], r[K_WA1Y], r[K_WA1Z] = 0, jy, jz, wx, wy, wz
				local k1 = ima + (jy * wy + jz * wz)
				-- t2: j = (-raz, 0, rax)
				jx, jz = -raz, rax
				wx, wy, wz = i11 * jx + i13 * jz, i12 * jx + i23 * jz, i13 * jx + i33 * jz
				r[K_A2X], r[K_A2Y], r[K_A2Z], r[K_WA2X], r[K_WA2Y], r[K_WA2Z] = jx, 0, jz, wx, wy, wz
				local k2 = ima + (jx * wx + jz * wz)
				local mn = 1 / kn
				r[K_MN], r[K_MT1], r[K_MT2] = mn, 1 / k1, 1 / k2
				local anx, any = r[K_ANX], r[K_ANY]
				local v0 = avz + awx * anx + awy * any
				r[K_V0] = v0
				if v0 < -t.restitutionSpeed then a.impact = stamp end
				-- surface friction and bounce, dig, warm start
				local k = cSlot[i]
				local mu, e = surf.mu, surf.e
				local dig, bite
				local biteVar = 0
				local sx, sy = 0, 0
				local ln, l1, l2 = 0, 0, 0
				if a.gStamp[k] == stamp - 1 then
					dig = a.gDig[k]
					-- the bite weakens as the edge works the turf loose
					if a.gN[k] > 0 then bite = a.gBite[k] * biteFade end
					ln, l1, l2 = a.gN[k] * warmF, a.gT1[k] * warmF, a.gT2[k] * warmF
				else
					-- a new contact: how steeply and how fast did it arrive?
					dig = 0
					-- the ground texture: this patch's values (a hash of the
					-- patch and the throw's seed; five numbers in -1..1)
					local tex = surf.texture
					local u1, u2, u3, u4, u5 = 0, 0, 0, 0, 0
					if tex then
						-- (math.floor: a true integer; // leaves a float, which the
						-- device's 32-bit Lua will not take into & and >>)
						local cx, cy = floor(px / tex.cell), floor(py / tex.cell)
						local hh = (cx * 0x1B873593 + cy * 0x5BD1E995 + w.groundSeed) & 0xffffffff
						hh = ((hh ~ (hh >> 15)) * 0x2C1B3C6D) & 0xffffffff
						hh = ((hh ~ (hh >> 12)) * 0x297A2D39) & 0xffffffff
						hh = hh ~ (hh >> 15)
						local h2 = ((hh * 0x85EBCA6B) & 0xffffffff) ~ (hh >> 13)
						u1, u2, u3 = (hh & 1023) / 511.5 - 1, ((hh >> 10) & 1023) / 511.5 - 1, ((hh >> 20) & 1023) / 511.5 - 1
						u4, u5 = (h2 & 1023) / 511.5 - 1, ((h2 >> 10) & 1023) / 511.5 - 1
						biteVar = u3
						a.gMf[k], a.gEf[k] = 1 + tex.muVar * u1, 1 + tex.eVar * u2
						-- a bump: the patch is tilted a few degrees (slope up to bump
						-- each way), and a landing faster than bumpSpeed meets it: its
						-- push that step is along the tilted normal (below), so it is
						-- turned, and nothing is added (the ground stays the plane z = 0)
						-- (the slope is scaled by how steeply it comes in: a low
						-- skidding drill barely feels it, a baton dropping end first does)
						if v0 < -tex.bumpSpeed then
							local vt1 = avx + awy * raz - awz * ray
							local vt2 = avy + awz * rax - awx * raz
							local steep = -v0 / sqrt(v0 * v0 + vt1 * vt1 + vt2 * vt2)
							steep = tex.bump * steep * steep
							sx, sy = steep * u4, steep * u5
						end
					else
						a.gMf[k], a.gEf[k] = 1, 1
					end
					if v0 < -surf.digSpeed and surf.dig > 0 then
						local vt1 = avx + awy * raz - awz * ray
						local vt2 = avy + awz * rax - awx * raz
						local steep = -v0 / sqrt(v0 * v0 + vt1 * vt1 + vt2 * vt2)
						local ramp = (-v0 - surf.digSpeed) / surf.digRamp
						if ramp > 1 then ramp = 1 end
						dig = surf.dig * steep * ramp * pointed(a)
						if tex then dig = dig * (1 + tex.digVar * u3) end
						local lever = surf.digLever * min(1, dig)
						if lever > a.dig then a.dig = lever end
					end
				end
				if not bite then
					-- the turf's bite: an edge or corner that strikes the turf cuts
					-- into it and is held sideways by the turf around it, not only by
					-- sliding friction (an extra friction coefficient), until it works
					-- loose: it catches a spinning kubb's edge and turns the kubb about
					-- it, where a hard floor lets the edge skate. Judged like the dig,
					-- by the edge's own arrival (v0, spin included) and how steep it
					-- is (an edge skimming in cuts the turf less), when the contact
					-- first presses (one made ahead of the touch waits for it).
					bite = 0
					if surf.bite and v0 < -surf.digSpeed then
						local vt1 = avx + awy * raz - awz * ray
						local vt2 = avy + awz * rax - awx * raz
						local steep = -v0 / sqrt(v0 * v0 + vt1 * vt1 + vt2 * vt2)
						local ramp = (-v0 - surf.digSpeed) / surf.digRamp
						if ramp > 1 then ramp = 1 end
						bite = surf.bite * ramp * pointed(a) * steep
						if surf.texture then bite = bite * (1 + surf.texture.digVar * biteVar) end
					end
				end
				a.gDig[k], a.gBite[k] = dig, bite
				r[K_MU] = mu * (1 + dig) * a.gMf[k] + bite
				local ef = 1 - dig
				if ef < 0 then ef = 0 end
				r[K_E] = e * ef * a.gEf[k]
				r[K_LN], r[K_LT1], r[K_LT2] = ln, l1, l2
				-- (the warm start, last step's impulses, is applied once every
				-- contact is built, below)
				if ln > 0 or l1 ~= 0 or l2 ~= 0 then
					warm = true
				elseif sx ~= 0 or sy ~= 0 then
					-- a landing on a tilted patch (new, so nothing to warm start): this
					-- step's contact takes the patch's normal, as a contact with a
					-- static body does (kind 4: solved as kind 3, stored as the ground)
					r[K_KIND] = 4
					local l = 1 / sqrt(sx * sx + sy * sy + 1)
					local nx, ny, nz = -sx * l, -sy * l, l
					r[K_NX], r[K_NY], r[K_NZ] = nx, ny, nz
					-- tangents (nx is small: t1 = (0, nz, -ny), t2 = n x t1)
					l = 1 / sqrt(nz * nz + ny * ny)
					local t1x, t1y, t1z = 0, nz * l, -ny * l
					local t2x, t2y, t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
					r[K_T1X], r[K_T1Y], r[K_T1Z], r[K_T2X], r[K_T2Y], r[K_T2Z] = t1x, t1y, t1z, t2x, t2y, t2z
					local jx, jy, jz = ray * nz - raz * ny, raz * nx - rax * nz, rax * ny - ray * nx
					local wx = i11 * jx + i12 * jy + i13 * jz
					local wy = i12 * jx + i22 * jy + i23 * jz
					local wz = i13 * jx + i23 * jy + i33 * jz
					r[K_ANX], r[K_ANY], r[K_ANZ], r[K_WANX], r[K_WANY], r[K_WANZ] = jx, jy, jz, wx, wy, wz
					local kn = ima + (jx * wx + jy * wy + jz * wz)
					jx, jy, jz = ray * t1z - raz * t1y, raz * t1x - rax * t1z, rax * t1y - ray * t1x
					wx = i11 * jx + i12 * jy + i13 * jz
					wy = i12 * jx + i22 * jy + i23 * jz
					wz = i13 * jx + i23 * jy + i33 * jz
					r[K_A1X], r[K_A1Y], r[K_A1Z], r[K_WA1X], r[K_WA1Y], r[K_WA1Z] = jx, jy, jz, wx, wy, wz
					local k1 = ima + (jx * wx + jy * wy + jz * wz)
					jx, jy, jz = ray * t2z - raz * t2y, raz * t2x - rax * t2z, rax * t2y - ray * t2x
					wx = i11 * jx + i12 * jy + i13 * jz
					wy = i12 * jx + i22 * jy + i23 * jz
					wz = i13 * jx + i23 * jy + i33 * jz
					r[K_A2X], r[K_A2Y], r[K_A2Z], r[K_WA2X], r[K_WA2Y], r[K_WA2Z] = jx, jy, jz, wx, wy, wz
					local k2 = ima + (jx * wx + jy * wy + jz * wz)
					r[K_MN], r[K_MT1], r[K_MT2] = 1 / kn, 1 / k1, 1 / k2
					r[K_V0] = avx * nx + avy * ny + avz * nz + awx * r[K_ANX] + awy * r[K_ANY] + awz * r[K_ANZ]
				end
			else
				r[K_NX], r[K_NY], r[K_NZ] = nx, ny, nz
				-- tangents
				local t1x, t1y, t1z
				if nx < 0.57 and nx > -0.57 then
					t1x, t1y, t1z = 0, nz, -ny
				else
					t1x, t1y, t1z = nz, 0, -nx
				end
				local l = 1 / sqrt(t1x * t1x + t1y * t1y + t1z * t1z)
				t1x, t1y, t1z = t1x * l, t1y * l, t1z * l
				local t2x, t2y, t2z = ny * t1z - nz * t1y, nz * t1x - nx * t1z, nx * t1y - ny * t1x
				r[K_T1X], r[K_T1Y], r[K_T1Z], r[K_T2X], r[K_T2Y], r[K_T2Z] = t1x, t1y, t1z, t2x, t2y, t2z
				-- A's angular terms for n, t1, t2
				local jx, jy, jz = ray * nz - raz * ny, raz * nx - rax * nz, rax * ny - ray * nx
				local wx = i11 * jx + i12 * jy + i13 * jz
				local wy = i12 * jx + i22 * jy + i23 * jz
				local wz = i13 * jx + i23 * jy + i33 * jz
				r[K_ANX], r[K_ANY], r[K_ANZ], r[K_WANX], r[K_WANY], r[K_WANZ] = jx, jy, jz, wx, wy, wz
				local kn = ima + (jx * wx + jy * wy + jz * wz)
				jx, jy, jz = ray * t1z - raz * t1y, raz * t1x - rax * t1z, rax * t1y - ray * t1x
				wx = i11 * jx + i12 * jy + i13 * jz
				wy = i12 * jx + i22 * jy + i23 * jz
				wz = i13 * jx + i23 * jy + i33 * jz
				r[K_A1X], r[K_A1Y], r[K_A1Z], r[K_WA1X], r[K_WA1Y], r[K_WA1Z] = jx, jy, jz, wx, wy, wz
				local k1 = ima + (jx * wx + jy * wy + jz * wz)
				jx, jy, jz = ray * t2z - raz * t2y, raz * t2x - rax * t2z, rax * t2y - ray * t2x
				wx = i11 * jx + i12 * jy + i13 * jz
				wy = i12 * jx + i22 * jy + i23 * jz
				wz = i13 * jx + i23 * jy + i33 * jz
				r[K_A2X], r[K_A2Y], r[K_A2Z], r[K_WA2X], r[K_WA2Y], r[K_WA2Z] = jx, jy, jz, wx, wy, wz
				local k2 = ima + (jx * wx + jy * wy + jz * wz)
				local v0 = avx * nx + avy * ny + avz * nz
					+ awx * r[K_ANX] + awy * r[K_ANY] + awz * r[K_ANZ]
				if b then
					r[K_KIND] = 2
					local imb = b.im
					local j11, j12, j13, j22, j23, j33 = b.i11, b.i12, b.i13, b.i22, b.i23, b.i33
					-- B's arm reaches B's own surface: P is on A, and a contact made
					-- ahead of the touch (sep > 0) meets B sep along the normal
					-- short of it. (Along n it moves no normal impulse's torque, only
					-- friction's: the baton's drag down a kubb's face, levered from
					-- the baton's side of the gap, held the kubb back from tipping.)
					local rbx, rby, rbz = px - nx * sep - b.x, py - ny * sep - b.y, pz - nz * sep - b.z
					kn, k1, k2 = kn + imb, k1 + imb, k2 + imb
					jx, jy, jz = rby * nz - rbz * ny, rbz * nx - rbx * nz, rbx * ny - rby * nx
					wx = j11 * jx + j12 * jy + j13 * jz
					wy = j12 * jx + j22 * jy + j23 * jz
					wz = j13 * jx + j23 * jy + j33 * jz
					r[K_BNX], r[K_BNY], r[K_BNZ], r[K_WBNX], r[K_WBNY], r[K_WBNZ] = jx, jy, jz, wx, wy, wz
					kn = kn + (jx * wx + jy * wy + jz * wz)
					jx, jy, jz = rby * t1z - rbz * t1y, rbz * t1x - rbx * t1z, rbx * t1y - rby * t1x
					wx = j11 * jx + j12 * jy + j13 * jz
					wy = j12 * jx + j22 * jy + j23 * jz
					wz = j13 * jx + j23 * jy + j33 * jz
					r[K_B1X], r[K_B1Y], r[K_B1Z], r[K_WB1X], r[K_WB1Y], r[K_WB1Z] = jx, jy, jz, wx, wy, wz
					k1 = k1 + (jx * wx + jy * wy + jz * wz)
					jx, jy, jz = rby * t2z - rbz * t2y, rbz * t2x - rbx * t2z, rbx * t2y - rby * t2x
					wx = j11 * jx + j12 * jy + j13 * jz
					wy = j12 * jx + j22 * jy + j23 * jz
					wz = j13 * jx + j23 * jy + j33 * jz
					r[K_B2X], r[K_B2Y], r[K_B2Z], r[K_WB2X], r[K_WB2Y], r[K_WB2Z] = jx, jy, jz, wx, wy, wz
					k2 = k2 + (jx * wx + jy * wy + jz * wz)
					v0 = v0 - (b.vx * nx + b.vy * ny + b.vz * nz)
						- (b.wx * r[K_BNX] + b.wy * r[K_BNY] + b.wz * r[K_BNZ])
				else
					r[K_KIND] = 3
				end
				r[K_MN], r[K_MT1], r[K_MT2] = 1 / kn, 1 / k1, 1 / k2
				r[K_V0] = v0
				r[K_MU], r[K_E] = pairMu, pairE
				r[K_LN] = 0
			end
		end
	end
	nRec = m
	-- warm start the ground contacts (n = +z, t1 = +x, t2 = +y), after every
	-- contact has taken its approach speed (v0) from the velocities the step
	-- began with: applied as each was built, a piece's later corners read its
	-- speed with its earlier corners' warm start in it, and after a hard
	-- landing (last step's impulses, the bounce's among them, are large) a
	-- corner at rest read an approach of metres a second and was given a
	-- bounce off it (docs/notes/physics.md, "Physics", "The bounce reaches the row")
	if warm then
		for i = 1, m do
			local r = REC[i]
			if r[K_KIND] == 1 then
				local ln, l1, l2 = r[K_LN], r[K_LT1], r[K_LT2]
				if ln > 0 or l1 ~= 0 or l2 ~= 0 then
					local a = r[K_A]
					local ima = a.im
					a.vx, a.vy, a.vz = a.vx + ima * l1, a.vy + ima * l2, a.vz + ima * ln
					a.wx = a.wx + ln * r[K_WANX] + l1 * r[K_WA1X] + l2 * r[K_WA2X]
					a.wy = a.wy + ln * r[K_WANY] + l1 * r[K_WA1Y] + l2 * r[K_WA2Y]
					a.wz = a.wz + ln * r[K_WANZ] + l1 * r[K_WA1Z] + l2 * r[K_WA2Z]
				end
			end
		end
	end

	if P then local now = pc(); P.prepare = P.prepare + now - pt; pt = now end
	-- 4. solve with the push bias
	for _ = 1, t.iterations do solve(K_BIAS, REC, m) end

	if P then local now = pc(); P.solve = P.solve + now - pt; pt = now end
	-- 5. integrate positions (quaternion step, normalize, rotation matrix and
	-- world inverse inertia: quat.integrate and body.updateDerived written out).
	-- A body with no contact this step moves by the mean of its velocity
	-- before and after the forces (the trapezoid: exact for gravity, and what
	-- flight.carry's midpoint steps do), so a throw flies as far as the aim
	-- says; the semi-implicit move (the velocity after) dropped g dt t / 2 and
	-- came down 2 to 3 cm short. A body in contact moves by its solved
	-- velocity, so a piece at rest stays put.
	local h = 0.5 * dt
	for i = 1, nb do
		local b = bodies[i]
		if b.awake then
			if b.cStep == stamp then
				b.x, b.y, b.z = b.x + b.vx * dt, b.y + b.vy * dt, b.z + b.vz * dt
			else
				b.x, b.y, b.z = b.x + (OVX[i] + b.vx) * h, b.y + (OVY[i] + b.vy) * h, b.z + (OVZ[i] + b.vz) * h
			end
			if inAir and b == proj and b.aeroK and b.cStep ~= stamp then
				-- the thrown piece in flight: its turn in substeps (flightTurn)
				flightTurn(w, b, dt, t.flightTurns, useGyro)
			else
				local qw, qx, qy, qz = b.qw, b.qx, b.qy, b.qz
				local wx, wy, wz = b.wx, b.wy, b.wz
				local dw = -(wx * qx + wy * qy + wz * qz)
				local dx = wx * qw + wy * qz - wz * qy
				local dy = wy * qw + wz * qx - wx * qz
				local dz = wz * qw + wx * qy - wy * qx
				qw, qx, qy, qz = qw + h * dw, qx + h * dx, qy + h * dy, qz + h * dz
				local qn = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
				if qn < 1e-12 then
					qw, qx, qy, qz = 1, 0, 0, 0
				else
					qn = 1 / qn
					qw, qx, qy, qz = qw * qn, qx * qn, qy * qn, qz * qn
				end
				b.qw, b.qx, b.qy, b.qz = qw, qx, qy, qz
				local xx, yy, zz = qx * qx, qy * qy, qz * qz
				local xy, xz, yz = qx * qy, qx * qz, qy * qz
				local xw, yw, zw = qw * qx, qw * qy, qw * qz
				local r11, r12, r13 = 1 - 2 * (yy + zz), 2 * (xy - zw), 2 * (xz + yw)
				local r21, r22, r23 = 2 * (xy + zw), 1 - 2 * (xx + zz), 2 * (yz - xw)
				local r31, r32, r33 = 2 * (xz - yw), 2 * (yz + xw), 1 - 2 * (xx + yy)
				b.r11, b.r12, b.r13, b.r21, b.r22, b.r23, b.r31, b.r32, b.r33 = r11, r12, r13, r21, r22, r23, r31, r32, r33
				local ia, ic, ie = b.iIx, b.iIy, b.iIz
				b.i11 = r11 * r11 * ia + r12 * r12 * ic + r13 * r13 * ie
				b.i12 = r11 * r21 * ia + r12 * r22 * ic + r13 * r23 * ie
				b.i13 = r11 * r31 * ia + r12 * r32 * ic + r13 * r33 * ie
				b.i22 = r21 * r21 * ia + r22 * r22 * ic + r23 * r23 * ie
				b.i23 = r21 * r31 * ia + r22 * r32 * ic + r23 * r33 * ie
				b.i33 = r31 * r31 * ia + r32 * r32 * ic + r33 * r33 * ie
			end
		end
	end

	if P then local now = pc(); P.integrate = P.integrate + now - pt; pt = now end
	-- 6. relax: remove the push-apart speed
	for _ = 1, t.relaxIterations do solve(K_RELAX, REC, m) end

	if P then local now = pc(); P.relax = P.relax + now - pt; pt = now end
	-- 7. restitution, the bounce of each contact that arrived faster than
	-- restitutionSpeed and pressed this step: the target is -e times its
	-- approach speed before the solve (v0). (Several passes: a box landing
	-- flat has four corners, and one pass in order over them tips it and
	-- overshoots the bounce.) A bounce between two pieces is solved together
	-- with every other contact of those pieces that pressed this step (their
	-- footing on the ground, a neighbour), held to the target they had in the
	-- relax pass: applied alone, a baton's bounce off a standing kubb drove
	-- the kubb into the ground and the ground threw it up the next step.
	-- Friction is solved in these passes too, capped at mu times the
	-- contact's whole normal impulse (the push, the relax and the bounce):
	-- in the bias passes a speculative contact's impulse only takes the
	-- approach speed past the gap still to close, so a landing kept 0.6 to
	-- 0.9 of its ground speed, and how much depended on where the step fell
	-- (docs/notes/physics.md, "Physics", "Friction in the bounce").
	-- The bounce reaches the whole group of awake pieces pressed together,
	-- not only the pieces that bounce: a baton striking the front of a row
	-- of touching kubbs strikes the row, and with the bounce cut off at the
	-- front kubb's own contacts the second kubb was free in these passes, so
	-- the front two took the blow as a light pair, met the third a step later
	-- and stopped (docs/notes/physics.md, "Physics", "The bounce reaches the row"). When
	-- it reaches past the pieces that bounce (a row), the passes run until
	-- the impulses settle (restitutionTol), up to restitutionMaxIterations:
	-- each pass carries the push one kubb further, and four left it short
	-- of the far kubbs. Any other bounce keeps restitutionIterations: run to
	-- the limit there, a sliding contact's friction and its push fed each
	-- other pass after pass (a spinning baton's corner swung between all of
	-- its bounce and none), and the fuzz's energy rises went from 5 to 24.
	local rs = t.restitutionSpeed
	local any, pair, row = false, false, false
	for i = 1, m do
		local r = REC[i]
		if r[K_V0] < -rs and r[K_LNMAX] > 0 and r[K_E] > 0 then
			any = true
			local kind = r[K_KIND]
			if kind ~= 1 then
				pair = true
				r[K_A].bounceStep = stamp
				if kind == 2 then r[K_B].bounceStep = stamp end
			end
		end
	end
	if pair then
		-- spread the mark through every pressing contact between two awake
		-- pieces (a row of n needs n passes; usually one finds nothing new)
		local grew = true
		while grew do
			grew = false
			for i = 1, m do
				local r = REC[i]
				if r[K_KIND] == 2 and r[K_LNMAX] > 0 then
					local a, b = r[K_A], r[K_B]
					if a.bounceStep == stamp then
						if b.bounceStep ~= stamp then
							b.bounceStep = stamp; b.rowStep = stamp; grew = true; row = true
						end
					elseif b.bounceStep == stamp then
						a.bounceStep = stamp; a.rowStep = stamp; grew = true; row = true
					end
				end
			end
		end
		if row then
			-- the islands that grew: spread rowStep from the pieces the bounce
			-- reached through the same contacts, so only their contacts get the
			-- extra passes (a bounce elsewhere in the step keeps its four)
			grew = true
			while grew do
				grew = false
				for i = 1, m do
					local r = REC[i]
					if r[K_KIND] == 2 and r[K_LNMAX] > 0 then
						local a, b = r[K_A], r[K_B]
						if a.rowStep == stamp then
							if b.rowStep ~= stamp then b.rowStep = stamp; grew = true end
						elseif b.rowStep == stamp then
							a.rowStep = stamp; grew = true
						end
					end
				end
			end
		end
	end
	if any then
		local nb = 0
		for i = 1, m do
			local r = REC[i]
			local v0 = r[K_V0]
			local a, kind = r[K_A], r[K_KIND]
			if v0 < -rs and r[K_LNMAX] > 0 and r[K_E] > 0 then
				nb = nb + 1
				BOUNCE[nb] = r
				r[K_REST] = -r[K_E] * v0
			elseif pair and r[K_LNMAX] > 0 and (a.bounceStep == stamp
				or (kind == 2 and r[K_B].bounceStep == stamp)) then
				nb = nb + 1
				BOUNCE[nb] = r
				r[K_REST] = r[K_RELAX]
			end
		end
		local tol, least, most = t.restitutionTol, t.restitutionIterations, t.restitutionMaxIterations
		if not row then most = least end
		local passes = 0
		-- (restitutionIterations 0 turns the bounce off: a diagnostic, docs/notes/physics.md)
		while least > 0 do
			local dm = solve(K_REST, BOUNCE, nb)
			passes = passes + 1
			if passes >= most or (passes >= least and dm < tol) then break end
			if passes == least and row then
				-- past restitutionIterations only the rows' contacts go on
				local k = 0
				for i = 1, nb do
					local r = BOUNCE[i]
					if r[K_A].rowStep == stamp or (r[K_KIND] == 2 and r[K_B].rowStep == stamp) then
						k = k + 1
						BOUNCE[k] = r
					end
				end
				nb = k
			end
		end
		w.bouncePasses = w.bouncePasses + passes
	end

	if P then local now = pc(); P.restitution = P.restitution + now - pt; pt = now end
	-- 8. store ground impulses; touches
	local proj = w.projectile
	for i = 1, m do
		local r = REC[i]
		local idx = r[K_IDX]
		local kind = r[K_KIND]
		if kind == 1 or kind == 4 then
			local a = r[K_A]
			local k = cSlot[idx]
			local ln = r[K_LN]
			local l1, l2 = r[K_LT1], r[K_LT2]
			if kind == 4 then
				-- (its friction in the ground's x and y, for next step's warm start)
				l1, l2 = l1 * r[K_T1X] + l2 * r[K_T2X], l1 * r[K_T1Y] + l2 * r[K_T2Y]
			end
			a.gStamp[k], a.gN[k], a.gT1[k], a.gT2[k] = stamp, ln, l1, l2
			a.groundImpulse = a.groundImpulse + ln
			if w.onContact and a == proj and r[K_LNMAX] > 0 then
				w.onContact(w.time, a, nil, r[K_LNMAX])
			end
			if r[K_LNMAX] > 0 and a == proj and not w.firstContact then
				noteContact(w, a, nil, cPx[idx], cPy[idx], cPz[idx])
			end
		elseif r[K_LNMAX] > 0 then
			-- what holds a piece up, for its sleep: a sleeping or static piece,
			-- or an awake one (propBy); and an awake piece it presses on is a
			-- mate, whose sleep timer it waits for (the sleep test below)
			local a = r[K_A]
			if kind == 3 then
				a.restStep = stamp
			else
				local b = r[K_B]
				a.propStep, a.propBy = stamp, b
				b.propStep, b.propBy = stamp, a
				local ta, tb = a.sleepTime, b.sleepTime
				if a.mateStep ~= stamp then a.mateStep, a.mateMin = stamp, tb
				elseif tb < a.mateMin then a.mateMin = tb end
				if b.mateStep ~= stamp then b.mateStep, b.mateMin = stamp, ta
				elseif ta < b.mateMin then b.mateMin = ta end
			end
			local other = cB[idx]
			local first = cA[idx]
			if w.onContact then w.onContact(w.time, first, other, r[K_LNMAX]) end
			first.touched, other.touched = true, true
			-- the first moment each body is struck (render/burst: the burst and
			-- knock come at the impact); one test a contact, no arithmetic
			if not first.touchT then first.touchT = w.time end
			if not other.touchT then other.touchT = w.time end
			if proj and not w.firstHit and (first == proj or other == proj) then
				noteContact(w, proj, (first == proj) and other or first, cPx[idx], cPy[idx], cPz[idx])
			end
		end
	end

	if P then local now = pc(); P.store = P.store + now - pt; pt = now end
	-- rolling resistance and dig, then sleep and bookkeeping
	w.time = w.time + dt
	w.steps = stamp + 1
	local sinTopple = sin(rad(t.toppleDeg))
	local half, len, om = t.pitchHalfWidth, t.pitchLength, t.outMargin
	local sleepLin2, sleepAng2, sleepTime = t.sleepLin * t.sleepLin, t.sleepAng * t.sleepAng, t.sleepTime
	for i = 1, nb do
		local b = bodies[i]
		if b.awake then
			local gi = b.groundImpulse
			if gi <= 0 then b.plough = 0 end   -- off the ground: the ploughed snow is left behind
			if gi > 0 then
				-- the ground's push this step, as the turf feels it: all of it,
				-- except in a step where a contact struck (faster than
				-- restitutionSpeed), when only the weight's share: the strike is
				-- taken by the contacts and the dig, and one hard step must not
				-- stop a turn or a slide the plug lets go
				local load = gi
				if b.impact == stamp then
					local wt = b.m * t.g * dt
					if load > wt then load = wt end
				end
				if b.shape == 2 then
					-- a baton: its spin taken in two parts, each held by an angular
					-- impulse (lever times the ground's impulse), never past stopping
					-- that part: its end-over-end turn by the plug (dig) and
					-- batonTurnHold of the rolling resistance (surf.roll), its roll
					-- about the long axis by the plug and all of it. As one vector
					-- (rollResist) a spin with any part along the long axis, where
					-- the baton turns most easily, read as nearly stopped, and a
					-- baton landing on an end lost all of its spin in that step and
					-- went on without turning (Tyler's play test, 2026-11-15:
					-- "gliding"; tools/batonprobe.lua)
					local ux, uy, uz = b.r13, b.r23, b.r33
					local wx, wy, wz = b.wx, b.wy, b.wz
					local wu = wx * ux + wy * uy + wz * uz
					local px, py, pz = wx - wu * ux, wy - wu * uy, wz - wu * uz
					local i11, i12, i13, i22, i23, i33 = b.i11, b.i12, b.i13, b.i22, b.i23, b.i33
					-- (rolling resistance is the turf giving under the ground's push,
					-- `load` above: a landing's turn loss is the plug's)
					local gr = load
					local L = b.dig * gi + t.batonTurnHold * surf.roll * gr
					local p2 = px * px + py * py + pz * pz
					if L > 0 and p2 > 1e-12 then
						local pn = sqrt(p2)
						local ex, ey, ez = px / pn, py / pn, pz / pn
						local ix = i11 * ex + i12 * ey + i13 * ez
						local iy = i12 * ex + i22 * ey + i23 * ez
						local iz = i13 * ex + i23 * ey + i33 * ez
						local stop = pn / (ex * ix + ey * iy + ez * iz)
						if L > stop then L = stop end
						wx, wy, wz = wx - L * ix, wy - L * iy, wz - L * iz
					end
					L = b.dig * gi + surf.roll * gr
					if L > 0 and (wu > 1e-9 or wu < -1e-9) then
						local ix = i11 * ux + i12 * uy + i13 * uz
						local iy = i12 * ux + i22 * uy + i23 * uz
						local iz = i13 * ux + i23 * uy + i33 * uz
						local stop = wu / (ux * ix + uy * iy + uz * iz)
						if stop < 0 then stop = -stop end
						if L > stop then L = stop end
						if wu < 0 then L = -L end
						wx, wy, wz = wx - L * ix, wy - L * iy, wz - L * iz
					end
					b.wx, b.wy, b.wz = wx, wy, wz
				else
					rollResist(b, b.dig, gi)
				end
				local tex = surf.texture
				if tex then
					local r33 = b.r33
					if r33 < 0 then r33 = -r33 end
					local vx, vy = b.vx, b.vy
					local v2 = vx * vx + vy * vy
					if v2 > 1e-8 then
						if r33 > COS_END then
							-- a piece standing on an end and sliding on snow (a kubb, the
							-- king, a baton): its foot sinks into the snow and ploughs it,
							-- a resistance at the foot against the slip of the point under
							-- its centre, no more than footMu times the ground's push this
							-- step (Coulomb, like the corners' friction) and never past
							-- stopping the slip, so it slows the piece and tips it the way
							-- it is going. Elsewhere the friction at the foot alone tips a
							-- piece sliding on an end (a baton's trip, a spin added with
							-- nothing pushed back, went 2026-11-16)
							local fm = tex.footMu
							if fm then
								local h = b.z
								local wx, wy = b.wx, b.wy
								local sx, sy = vx - h * wy, vy + h * wx
								local s2 = sx * sx + sy * sy
								if s2 > tex.footSpeed * tex.footSpeed then
									local im = b.im
									local jx = -sx / (im + h * h * b.i22)
									local jy = -sy / (im + h * h * b.i11)
									local j2 = jx * jx + jy * jy
									local cap = fm * gi
									if j2 > cap * cap then
										local f = cap / sqrt(j2)
										jx, jy = jx * f, jy * f
									end
									-- r = (0, 0, -h): r x J = (h jy, -h jx, 0)
									local tx, ty = h * jy, -h * jx
									b.vx, b.vy = vx + im * jx, vy + im * jy
									b.wx = wx + b.i11 * tx + b.i12 * ty
									b.wy = wy + b.i12 * tx + b.i22 * ty
									b.wz = b.wz + b.i13 * tx + b.i23 * ty
								end
							end
						elseif b.shape == 2 or r33 < 0.5 then
							-- a baton or a lying piece on grass: the blades hold it,
							-- harder once it is slow, so it stops instead of creeping
							-- (in snow, harder the farther it has ploughed)
							-- (in proportion to how hard it presses: its full weight on
							-- the ground gives the rates in full, a baton propped on a
							-- kubb with one end in the grass less; a harder push, a
							-- landing or a pivot, is the corners' friction's, not more)
							local f = tex.drag
							if v2 < tex.gripSpeed * tex.gripSpeed then f = f + tex.grip end
							local pl = tex.plough
							if pl then
								local d = b.plough + sqrt(v2) * dt
								b.plough = d
								f = f + pl * d
							end
							local share = load / (b.m * t.g * dt)
							if share > 1 then share = 1 end
							f = 1 - f * share * dt
							if f < 0 then f = 0 end
							b.vx, b.vy = vx * f, vy * f
							b.wx, b.wy, b.wz = b.wx * f, b.wy * f, b.wz * f
						end
					end
				end
			end
			if b.dig > 0 then
				b.dig = b.dig * exp(-dt / surf.digTime)
				if b.dig < 1e-5 then b.dig = 0 end
			end
			local r33 = b.r33
			if b.shape == 1 and not b.toppled and r33 <= sinTopple and r33 >= -sinTopple then b.toppled = true; b.toppleT = w.time end
			local x, y = b.x, b.y
			if x > half + om or x < -(half + om) or y < -om or y > len + om then b.leftPitch = true end
			local vx, vy, vz, wx, wy, wz = b.vx, b.vy, b.vz, b.wx, b.wy, b.wz
			-- held up: by the ground, by a sleeping or static piece, or by an
			-- awake piece that is itself held up that way (a kubb lying on a
			-- kubb never touches the ground; Physics fuzz, 2026-11-16)
			local held = gi > 0 or b.restStep == stamp
			if not held and b.propStep == stamp then
				local p = b.propBy
				held = not p.awake or p.groundImpulse > 0 or p.restStep == stamp
			end
			if vx * vx + vy * vy + vz * vz < sleepLin2 and wx * wx + wy * wy + wz * wz < sleepAng2 and held then
				local st = b.sleepTime + dt
				b.sleepTime = st
				-- an awake piece it presses on that is still settling holds it
				-- awake until both are ready, so they sleep in the same step: one
				-- that slept first left the other its weight's worth of warm
				-- started push from the ground, which kicked it and woke the
				-- sleeper again (a leaner woke 20 times, 1:14364)
				local ready = st >= sleepTime
				if ready and b.mateStep == stamp and b.mateMin > 0
					and b.mateMin + dt < sleepTime then ready = false end
				if ready then
					epoch = epoch + 1
					b.awake = false
					b.vx, b.vy, b.vz, b.wx, b.wy, b.wz = 0, 0, 0, 0, 0, 0
					b.dig = 0
					-- the leaner rule: a piece that comes to rest propped on another is
					-- down if it would fall with the prop taken away
					if b.shape == 1 and not b.toppled and body.wouldFall(b) then b.toppled = true; b.toppleT = w.time end
				end
			else
				b.sleepTime = 0
			end
		end
	end
	if P then local now = pc(); P.tail = P.tail + now - pt end
	return w
end


-- Everything asleep (or the throw ran past tune.maxTime).
function world.isAtRest(w)
	if w.time >= world.tune.maxTime then return true end
	-- the body found awake last time is the likely one (the projectile is
	-- added last, so the plain scan would walk past every sleeper first)
	local bodies = w.bodies
	local h = w.awakeHint
	if h and bodies[h] and bodies[h].awake then return false end
	for i = 1, w.n do
		if bodies[i].awake then
			w.awakeHint = i
			return false
		end
	end
	return true
end

-- Step until at rest or for at most `seconds` more.
function world.run(w, seconds)
	local stop = w.time + (seconds or world.tune.maxTime)
	while not world.isAtRest(w) and w.time < stop - 1e-9 do world.step(w) end
	return w
end

-- Is the center outside the pitch (beyond tune.outMargin)?
function world.outside(x, y)
	local t = world.tune
	return abs(x) > t.pitchHalfWidth + t.outMargin or y < -t.outMargin or y > t.pitchLength + t.outMargin
end

-- The outcome of the throw:
--   time, steps           simulated time and steps
--   touched               ids of bodies something touched (the projectile included)
--   stakesTouched         ids of stakes something touched (stake1 .. stake6, core/pitch order)
--   toppled               ids of kubbs and kings that toppled in this throw
--   kingToppled           true if a king toppled
--   outNotToppled         ids of kubbs that ended outside the pitch without toppling
--   bodies[id]            {kind, x, y, z, qw, qx, qy, qz, toppled, touched, out, leftPitch}
--   firstContact, firstHit  the projectile's first contact (any) and first body hit
function world.result(w)
	local r = {
		time = w.time, steps = w.steps,
		touched = {}, toppled = {}, outNotToppled = {}, kingToppled = false,
		stakesTouched = {},
		bodies = {},
		firstContact = w.firstContact, firstHit = w.firstHit,
	}
	for i = 1, w.n do
		local b = w.bodies[i]
		-- a piece still moving when the throw ran out of time gets the leaner rule here
		if b.shape == 1 and not b.static and not b.toppled and body.wouldFall(b) then b.toppled = true; b.toppleT = w.time end
		local out = world.outside(b.x, b.y)
		r.bodies[b.id] = {
			kind = b.kind, x = b.x, y = b.y, z = b.z, qw = b.qw, qx = b.qx, qy = b.qy, qz = b.qz,
			toppled = b.toppled, touched = b.touched, out = out, leftPitch = b.leftPitch,
		}
		if b.touched then
			if b.static then r.stakesTouched[#r.stakesTouched + 1] = b.id
			else r.touched[#r.touched + 1] = b.id end
		end
		if b.shape == 1 and b.toppled and not b.wasToppled and b ~= w.projectile then
			r.toppled[#r.toppled + 1] = b.id
			if b.kind == "king" then r.kingToppled = true end
		end
		if b.shape == 1 and out and not b.toppled and b ~= w.projectile then
			r.outNotToppled[#r.outNotToppled + 1] = b.id
		end
	end
	return r
end

-- Total energy (kinetic + potential) of all moving bodies, J.
function world.energy(w)
	local e = 0
	for i = 1, w.n do
		local b = w.bodies[i]
		if not b.static then e = e + body.energy(b, world.tune.g) end
	end
	return e
end

tw.world = world
