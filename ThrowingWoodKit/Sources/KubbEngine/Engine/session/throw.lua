-- The throw scene with the screen taken out (docs/SESSION.md). Pure Lua 5.4.
--
-- This is the Playdate's source/scenes/throw.lua (../../playdate-kubb), taken
-- over line for line where it decides something: the aim (target circle,
-- stance, plan, "stay put"), the plan solve, the swing (core/swing fed the
-- dial's angle stream), the launch (core/throwplan), the world run to rest,
-- the verdicts, the result flag, the cameras (first person, plan view,
-- follow, impact, the half circle) and the computer's arm on the clock.
-- What the Playdate drew is returned as data instead. Where the web differs
-- it says so here and in docs/SESSION.md "Differences from the Playdate":
--   * a throw is computed whole at release (playback.finish) and returned as
--     a recording; the camera for any shown time is a pure function of it;
--   * the target circle and the stance are also set by absolute position
--     (the pointer drags them), not only nudged;
--   * the dial is a pointer: its angle stream is turned into crank changes,
--     and lifting the pointer while swinging forward is the release.
--
-- Everything is in the thrower's view frame (core/frame): the throw is from
-- y = lineY (0) toward +y.
import "core/tw"
import "core/camera"
import "core/swing"
import "session/touch"
import "core/flight"
import "core/pitch"
import "core/world"
import "core/body"
import "core/playback"
import "core/quat"
import "core/burstpick"
import "core/drill"
import "core/throwplan"
import "session/json"

local camera, swing, flight, pitch = tw.camera, tw.swing, tw.flight, tw.pitch
local phys, playback, quat, burstpick = tw.world, tw.playback, tw.quat, tw.burstpick
local drill, plan, body = tw.drill, tw.plan, tw.body
-- The host's tune (tune/<name>.lua, chosen by session.useTune): read when it is used,
-- not when this file loads, since the host chooses it after loading the engine.
local function wtune() return assert(tw.web.tune, "no tune: call useTune first") end

local abs, sqrt, max, min, floor, rad = math.abs, math.sqrt, math.max, math.min, math.floor, math.rad
local fmt = string.format

local throw = {}

-- scenes/throw.lua's tune, the fields the web uses, with the Playdate's
-- values (the pacing fields of the device's flight are not needed: the
-- throw is computed whole).
throw.tune = {
	walkSpeed = 1.2,      -- m/s along the throwing line (keys held)
	halfWidth = 2.5,      -- the line is 5 m wide (DESIGN 2)
	backMax = 3.0,        -- m the player may step back from the throwing line
	snapRadius = 0.25,    -- m: aimAt (snap) puts the circle onto a standing target this near;
	                      -- a baton's circle this near one is on it (replan: aimed through it)
	keepNear = 1.0,       -- m: a circle moved by hand stays put for the next throw while a live
	                      -- target stands this near it (else it goes onto the nearest target)
	overDeg = 150,        -- backswing degrees past which the clock shows overpowered (11 o'clock)
	cpuSwingTime = 0.6,   -- s the computer's arm takes on the clock before its throw leaves
	cpuBackShare = 0.6,   -- the share of that spent going back
	lineY = 0,            -- the throwing line: the thrower's baseline
	surface = "grass",    -- the practice pitch
	set = "classic",      -- the practice pitch's kubb set (passed through to the renderer)
	focusSpeed = 4,       -- m/s the impact camera's aim point slews toward the first hit
	frameRadius = 1.5,    -- m from the impact point within which the camera keeps the baton in frame
	swingDeg = 180,       -- the impact camera's half circle round the struck piece ...
	swingTime = 0.8,      -- ... over this many s of shown time from its impact
	drillKeep = 10,       -- drilled kubbs kept on the practice pitch; the oldest goes past this
	markerRadius = 0.25,  -- m: the target circle (0.5 m across, DESIGN 4)
	arc = true,           -- the planned arc shows
	arcPoints = 24,       -- points along the arc, release to landing
	arcSkip = 2,          -- the first points (at the hand, under the camera) are left out
	arcFitFrom = 6,       -- the plan view keeps the arc on screen from this point on
	-- ground impacts (throw.impacts, since 0.14; docs/SESSION.md "Ground impacts")
	impactSpeed = 0.8,    -- m/s: a piece meeting the ground at least this fast is an impact
	impactGap = 0.12,     -- s: a piece's touches within this of its last impact are that impact
	impactMax = 64,       -- impacts kept a throw, at most
}

-- Ground impacts (kubbCall "setImpacts"): while true, throw.fire gathers where each piece
-- met the ground hard into the recording's timeline (`impacts`). Off, no listener is set.
throw.impacts = false

-- The level a thrower record names (s.level: a named player's; s.defaultLevel: the
-- session's; throw.level otherwise). From 0.13 it changes nothing in a person's throw:
-- every person plans and throws on one meter (throw.meterFor, plan.meters). It is kept
-- so older callers and records still read and write it.
throw.level = plan.tune.defaultLevel
function throw.levelFor(s)
	return s.level or s.defaultLevel or throw.level
end
-- The meter a person's throw is planned on (plan.meter): the same for every person,
-- whatever throw.levelFor(s) says.
function throw.meterFor(s)
	return plan.meter(s.meter)
end

-- ---------- pieces ----------

-- How high a piece's centre sits when it rests on the ground with this
-- orientation (scenes/throw.lua restZ, with the physics' own half extents).
local function restZ(kind, qw, qx, qy, qz)
	local k = body.kinds[kind]
	local _, _, _, _, _, _, r31, r32, r33 = quat.toMatrix(qw, qx, qy, qz)
	if k.shape == 1 then
		return abs(r31) * k.hx + abs(r32) * k.hy + abs(r33) * k.hz
	end
	return k.hl * abs(r33) + k.r
end

local function newItem(p)
	local qw, qx, qy, qz = p.qw, p.qx, p.qy, p.qz
	if not qw then
		local yaw = (p.yaw or 0) / 2
		qw, qx, qy, qz = math.cos(yaw), 0, 0, math.sin(yaw)
	end
	return {
		id = p.id, kind = p.kind, x = p.x, y = p.y, z = p.z or restZ(p.kind, qw, qx, qy, qz),
		qw = qw, qx = qx, qy = qy, qz = qz,
		toppled = p.toppled or false, base = p.base, role = p.role, half = p.half,
		debris = p.debris, exact = p.z ~= nil,
	}
end

-- The practice layout: five base kubbs on each baseline and the king.
function throw.defaultLayout()
	local l = {}
	for _, side in ipairs { { "a", 0 }, { "b", 8 } } do
		for i, x in ipairs(pitch.baseX) do
			l[#l + 1] = { id = side[1] .. i, kind = "kubb", x = x, y = side[2], base = side[2] == 8 }
		end
	end
	l[#l + 1] = { id = "king", kind = "king", x = pitch.king.x, y = pitch.king.y }
	return l
end

function throw.standUp(s)
	local items = {}
	for i, p in ipairs(s.layout) do items[i] = newItem(p) end
	s.items = items
	s.practiceBaton = 0
end

local function itemsFrom(pieces, debris)
	local items = {}
	for i, p in ipairs(pieces) do items[i] = newItem(p) end
	for _, p in ipairs(debris or {}) do items[#items + 1] = newItem(p) end
	return items
end

function throw.setPieces(s, pieces, debris)
	s.items = itemsFrom(pieces, debris)
end

local function itemById(s, id)
	if not id then return nil end
	for _, it in ipairs(s.items) do
		if it.id == id then return it end
	end
	return nil
end

-- Live targets for the aim camera and the circle (scenes/throw.lua updateTargets).
local function updateTargets(s)
	local tg, sn = {}, {}
	local ids = s.targetIds
	for _, it in ipairs(s.items) do
		if ids then
			if not it.toppled then
				for j = 1, #ids do
					if ids[j] == it.id then
						tg[#tg + 1] = it
						sn[#sn + 1] = it
						break
					end
				end
			end
		elseif not it.toppled and not it.drilled and it.kind ~= "baton" then
			local king = it.kind == "king"
			local far = it.y > s.lineY + 4
			if far and not king then tg[#tg + 1] = it end
			if far or king then sn[#sn + 1] = it end
		end
	end
	s.targets, s.snaps = tg, sn
end

local function kindOf(it)
	if it.kind == "king" then return "king" end
	if it.role == "field" then return "field" end
	return "base"
end

-- ---------- the aim ----------

local function arcShown(s)
	return throw.tune.arc and (s.drill or s.projectile ~= "kubb")
end

-- The arc's launch (scenes/throw.lua arcLaunch): the flight has the air's
-- drag (flight.carry), so the arc is drawn as the plain parabola from the
-- hand to the same landing in the same time (within 2 to 4 cm of it). A
-- drilled kubb's lands where drill.solveAt puts it: sol.land out, its centre
-- at drill.tune.landZ. A baton's plan already sends its centre through the
-- target (plan.solve: sol.dist out, at sol.aimZ, in sol.flightT); on a piece
-- (replan's s.aimFace) the arc stops where it reaches the piece's near face,
-- a hair above the aim height: the fourth value is the time drawn to.
local function arcLaunch(s)
	local sol = s.sol
	local speed, loft, sw = sol.speed or 0, sol.loft or 32, sol.swivel or 0
	local T, R, z1 = sol.T, sol.land, drill.tune.landZ
	local Tdraw = nil
	if s.projectile ~= "kubb" and sol.flightT and sol.dist then
		T, R, z1 = sol.flightT, sol.dist > 0.1 and sol.dist or 0.1, sol.aimZ or 0
		local face = s.aimFace
		if face and face > 0 and face < R then Tdraw = T * face / R end
	elseif not (s.drill and T and R) then
		local lx, ly
		lx, ly, T = flight.predict(s.playerX, s.playerY, sw, loft, speed)
		lx, ly = lx - s.playerX, ly - s.playerY
		R, z1 = sqrt(lx * lx + ly * ly), 0
	end
	if T <= 0 then return 0, 0, 0, 0 end
	-- a baton's hand (plan.solve's handZ, handFwd): on a short throw lower and
	-- ahead of the feet, so the arc starts there and carries the rest
	local h, g = flight.tune.handHeight, flight.tune.g
	if s.projectile ~= "kubb" and sol.handZ then
		h = sol.handZ
		if sol.flightT and sol.dist then
			R = R - (sol.handFwd or 0)
			if Tdraw then
				local f = s.aimFace - (sol.handFwd or 0)
				Tdraw = f > 0 and T * f / R or nil
			end
		end
	end
	local vh = R / T
	return vh * math.sin(sw), vh * math.cos(sw), (z1 - h + 0.5 * g * T * T) / T, Tdraw or T
end

-- Where the planned arc starts: the hand (x, y, z), ahead of the stance and
-- lower on a short baton (plan.solve's handZ, handFwd).
local function arcOrigin(s)
	local sol = s.sol
	local h, f = flight.tune.handHeight, 0
	if s.projectile ~= "kubb" and sol and sol.handZ then h, f = sol.handZ, sol.handFwd or 0 end
	local sw = sol and sol.swivel or 0
	return s.playerX + f * math.sin(sw), s.playerY + f * math.cos(sw), h
end

-- The planned arc's points (arcSkip..arcPoints), as drawn on the Playdate.
local function arcPoints(s)
	local t = throw.tune
	local vx, vy, vz, T = arcLaunch(s)
	local x0, y0, h = arcOrigin(s)
	local g = flight.tune.g
	local out = {}
	for i = t.arcSkip, t.arcPoints do
		local tt = T * i / t.arcPoints
		out[#out + 1] = { x0 + vx * tt, y0 + vy * tt, h + vz * tt - 0.5 * g * tt * tt }
	end
	return out
end
throw.arcPoints = arcPoints

local function shoulderFit(s, c)
	local t = throw.tune
	local xs, ys, zs, n, across = {}, {}, {}, 0, 0
	if arcShown(s) and not s.watching then
		local vx, vy, vz, T = arcLaunch(s)
		local x0, y0, h = arcOrigin(s)
		local g = flight.tune.g
		across = t.arcFitFrom - t.arcSkip
		for i = t.arcSkip, t.arcPoints do
			local tt = T * i / t.arcPoints
			n = n + 1
			xs[n], ys[n], zs[n] = x0 + vx * tt, y0 + vy * tt, h + vz * tt - 0.5 * g * tt * tt
		end
	end
	local R = t.markerRadius
	for k = 0, 3 do
		n = n + 1
		local a = k * math.pi / 2
		xs[n], ys[n], zs[n] = s.markerX + R * math.cos(a), s.markerY + R * math.sin(a), 0
	end
	camera.shoulder(c, s.playerX, s.playerY, s.swivel, s.lineY, n, xs, ys, zs, across)
end

-- The aim camera (scenes/throw.lua aimCamera): first person, blended toward
-- the plan view by s.camMix; k eases the plan view's lens (1 snaps).
local function aimCamera(s, k)
	local mix = s.camMix
	local fp = (mix > 0) and s.fpCam or s.aimCam
	local look
	if not s.watching or s.cpuTarget then
		look = camera.lookDistAt(s.playerX, s.playerY, s.markerX, s.markerY)
	elseif s.targetIds then
		look = camera.lookDistFor(s.playerX, s.playerY, s.targets, #s.targets)
	end
	local back = s.lineY - s.playerY
	if back < 0 then back = 0 end
	camera.aim(fp, s.playerX, s.playerY, s.swivel, s.targets, back, look)
	do
		local dx, dy = s.markerX - s.playerX, s.markerY - s.playerY
		local d = sqrt(dx * dx + dy * dy)
		local r = throw.tune.markerRadius
		if d > r then
			camera.fitNear(fp, s.markerX - dx * r / d, s.markerY - dy * r / d)
		else
			camera.fitNear(fp, s.playerX, s.playerY)
		end
	end
	if mix <= 0 then
		s.shF = nil
		return
	end
	local sh = s.shCam
	shoulderFit(s, sh)
	k = k or 1
	if s.shF and k < 1 then
		local f, cx, cy = sh.f, sh.cx, sh.cy
		if abs(f - s.shF) > 0.5 or abs(cx - s.shCx) > 0.5 or abs(cy - s.shCy) > 0.5 then
			sh.f = s.shF * (f / s.shF) ^ k
			sh.cx = s.shCx + (cx - s.shCx) * k
			sh.cy = s.shCy + (cy - s.shCy) * k
		end
	end
	s.shF, s.shCx, s.shCy = sh.f, sh.cx, sh.cy
	camera.blend(s.aimCam, fp, sh, camera.smooth(mix))
end
throw.aimCamera = aimCamera

-- (a kubb's is its setup's forwardY too, since 0.15.0: the baseline in a standard match,
-- where it is lineY, and the Kid line in a Kid match)
local function forwardLimit(s)
	return s.forwardY
end
throw.forwardLimit = forwardLimit

-- The standing target a baton's circle is on (within snapRadius of its centre), or nil.
local function circleOn(s)
	if s.projectile == "kubb" or not s.snaps then return nil end
	return plan.snap(s.markerX, s.markerY, s.snaps, #s.snaps, throw.tune.snapRadius)
end

-- The default release for the throw as it is planned now: a drill's, or a baton's
-- for the distance from the stance to the circle (plan.arcFor; from 0.16 the lowered
-- line, the drive close in).
function throw.defaultArc(s)
	if s.projectile == "kubb" then return plan.arcFor("drill") end
	local dx, dy = s.markerX - s.playerX, s.markerY - s.playerY
	return plan.arcFor("baton", math.sqrt(dx * dx + dy * dy))
end

local function replan(s)
	local kubb = s.projectile == "kubb"
	if not s.stanceSet then
		local o = plan.stance(s.markerX, s.markerY, s.lineY, forwardLimit(s), throw.tune.halfWidth, {})
		s.playerX, s.playerY = o.x, o.y
	end
	if not s.arcSet then s.release = throw.defaultArc(s) end
	local q = {
		projectile = kubb and "kubb" or "baton",
		px = s.playerX, py = s.playerY, tx = s.markerX, ty = s.markerY,
		release = s.release, meter = throw.meterFor(s),
		-- a drill runs on by the ground and less with spin (drill.slideFor)
		surface = s.surface, spin = kubb and s.spin or 0,
	}
	-- a baton's circle on a piece (a standing target within snapRadius of its
	-- centre) aims the baton's centre through it at the piece's aim height
	-- (plan.aimZFor), and the arc ends on that piece's near face (s.aimFace, m
	-- along the throw from the stance); an empty spot is aimed at the ground
	-- (scenes/throw.lua replan)
	local on = circleOn(s)
	if on then
		local king = on.kind == "king"
		q.aimZ = plan.aimZFor(king and "king" or "kubb")
		local dx, dy = s.markerX - s.playerX, s.markerY - s.playerY
		local d = sqrt(dx * dx + dy * dy)
		local along = d > 0 and ((on.x - s.playerX) * dx + (on.y - s.playerY) * dy) / d or 0
		s.aimFace = along - (king and body.kinds.king.hx or body.kinds.kubb.hx)
	else
		q.aimZ, s.aimFace = 0, nil
	end
	local sol = plan.solve(q, {})
	s.sol = sol
	-- the lowest release this throw can be planned at (plan.solve's drive floor, 0.16):
	-- ARC's real range for the throw in hand (throw.controls)
	s.arcMin = plan.arcFloor(q)
	s.swivel, s.loftDeg = sol.swivel, sol.loft
	s.planLevel, s.planDirty = throw.levelFor(s), false
end
throw.replan = replan

local function settleMarker(s, snap)
	local sn = s.snaps
	local best, bd = nil, math.huge
	for i = 1, #sn do
		local dx, dy = sn[i].x - s.markerX, sn[i].y - s.markerY
		local d = dx * dx + dy * dy
		if d < bd then best, bd = sn[i], d end
	end
	if best then s.markerKind = kindOf(best) end
	s.markerOnId = nil
	if snap then
		local it = plan.snap(s.markerX, s.markerY, sn, #sn, throw.tune.snapRadius)
		if it then s.markerX, s.markerY, s.markerOnId = it.x, it.y, it.id end
	end
	s.planDirty = true
end

local function retarget(s, keep)
	if keep and s.markerSet then
		local sn, r = s.snaps, throw.tune.keepNear
		for i = 1, #sn do
			local dx, dy = sn[i].x - s.markerX, sn[i].y - s.markerY
			if dx * dx + dy * dy <= r * r then
				settleMarker(s, false)
				return
			end
		end
	end
	s.markerSet = false
	local on = itemById(s, s.markerOnId)
	if keep and on and not on.toppled then
		for i = 1, #s.snaps do
			if s.snaps[i] == on then
				s.markerX, s.markerY, s.markerKind = on.x, on.y, kindOf(on)
				s.planDirty = true
				return
			end
		end
	end
	local tg = s.targets
	local best, bd = nil, math.huge
	for i = 1, #tg do
		local dx, dy = tg[i].x - s.playerX, tg[i].y - s.playerY
		local d = dx * dx + dy * dy
		if d < bd then best, bd = tg[i], d end
	end
	if best then s.markerX, s.markerY, s.markerOnId, s.markerKind = best.x, best.y, best.id, kindOf(best) end
	s.planDirty = true
end

local function freshPlan(s)
	s.arcSet, s.tilt, s.spin = false, 0, 0
	s.planDirty = true
end

local function clearLast(s)
	s.lastBack, s.lastStop, s.showVerdicts, s.restText = nil, nil, false, nil
end
throw.clearLast = clearLast

local function markerHome(s)
	s.markerX, s.markerY, s.markerOnId = 0, s.lineY + drill.tune.markerStartY, nil
	s.planDirty = true
end

local function resetSwing(s)
	s.arm, s.armed, s.pointerDown, s.touch = nil, false, false, nil
	swing.reset(s.swing)
end

-- A fast sample can traverse both edges of a band. Report them in travel
-- order, including the last real movement before release or a let-down.
local function edge(s, name, direction)
	s.crossings = s.crossings or {}
	s.crossings[#s.crossings + 1] = { band = name, edge = direction }
end

local function bandEdges(s, a, b, lo, hi, name)
	if a < b then
		if a < lo and b >= lo then edge(s, name, "enter") end
		if a <= hi and b > hi then edge(s, name, "exit") end
	elseif a > b then
		if a > hi and b <= hi then edge(s, name, "enter") end
		if a >= lo and b < lo then edge(s, name, "exit") end
	end
end

function throw.new(opts)
	opts = opts or {}
	local s = {
		mode = "aim",            -- "aim" | "cputhink" | "cpuswing"
		playerX = 0, playerY = throw.tune.lineY,
		swivel = 0, loftDeg = flight.tune.loftDefaultDeg,
		arm = nil, armed = false, pointerDown = false,
		swing = swing.new(),
		aimCam = camera.new(), fpCam = camera.new(), shCam = camera.new(),
		camMix = 0, shF = nil, shCx = nil, shCy = nil, planHeld = false,
		throws = 0,
		surface = opts.surface or throw.tune.surface,
		set = opts.set or throw.tune.set,
		defaultLevel = opts.level,
		meter = opts.meter,   -- the meter a person throws on (plan.meters): "kid" in a Kid match, nil the standard
		layout = throw.defaultLayout(),
		items = {}, targets = {}, snaps = {},
		lineY = throw.tune.lineY, forwardY = throw.tune.lineY, advY = nil,
		projectile = "baton", projectileId = nil,
		auto = true,
		drill = false, thisDrill = false, drillSeq = 0,
		markerX = 0, markerY = 0, markerHeld = 0, markerSide = nil, markerFixed = false,
		markerOnId = nil, markerSet = false, markerKind = "base", markerMoving = false,
		stanceSet = false,
		release = plan.arcFor("baton"), arcSet = false, tilt = 0, spin = 0,
		sol = {}, planDirty = true, planLevel = nil,
		lastBack = nil, lastStop = nil, showVerdicts = false,
		vPower = 0, vRelease = 0, vSteady = true, restText = nil,
		watching = false,
		railName = "PRACTICE",
	}
	s.swing.onArm = function(a, b)
		local p = s.sol
		if b > a then
			bandEdges(s, a, b, -p.powerHi, -p.powerLo, "power")
			bandEdges(s, a, b, p.releaseLo, p.releaseHi, "release")
		elseif b < a then
			bandEdges(s, a, b, p.releaseLo, p.releaseHi, "release")
			bandEdges(s, a, b, -p.powerHi, -p.powerLo, "power")
		end
	end
	throw.standUp(s)
	updateTargets(s)
	retarget(s, false)
	replan(s)
	aimCamera(s)
	return s
end

-- The match: set the next throw up (scenes/throw.lua throw.prepare).
function throw.prepare(s, setup)
	if setup.surface then s.surface = setup.surface end
	throw.setPieces(s, setup.pieces, setup.debris)
	s.lineY, s.forwardY, s.advY = setup.lineY, setup.forwardY or setup.lineY, setup.advY
	s.kidY = setup.kidY
	s.kid = setup.kid or nil -- a Kid match: a helicopter counts, so the flag says what it did
	s.projectile, s.projectileId = setup.projectile, setup.kubb or setup.batonId
	s.targetIds = setup.targets
	s.auto = false
	updateTargets(s)
	if s.stanceSide ~= setup.side then clearLast(s) end
	-- Stay put (Jamie, 2026-11-14): a team's batons after its first of a
	-- turn keep the stance walked to, held to where this one may stand.
	local keep = setup.projectile == "baton" and (setup.n or 1) > 1
		and s.stanceSide == setup.side and s.stanceKind == "baton"
	local t = throw.tune
	if keep and s.stanceSet then
		s.playerX = max(-t.halfWidth, min(t.halfWidth, s.playerX))
		s.playerY = max(s.lineY - t.backMax, min(s.forwardY, s.playerY))
	else
		s.stanceSet = false
		s.playerX, s.playerY = 0, s.forwardY
	end
	s.stanceSide, s.stanceKind = setup.side, setup.projectile
	freshPlan(s)
	local adv = s.forwardY - s.lineY
	s.advMeters = (setup.projectile == "baton" and adv > 0.05) and adv or nil
	s.advText = s.advMeters and fmt("ADVANTAGE LINE  %.1f M", s.advMeters) or nil
	-- a Kid match: the line is the Kid line unless the advantage line is beyond it
	if s.kidY and s.forwardY - s.lineY > 0.05 and (not s.advY or s.advY <= s.kidY + 1e-9) then
		s.advText = fmt("KID LINE  %.1f M", s.kidY - s.lineY)
	end
	s.markerFixed = false
	if setup.projectile == "kubb" then
		if not (s.drill and s.markerSide == setup.side) then
			markerHome(s)
			s.keptSpin = nil
		end
		s.markerSide = setup.side
		s.drill = true
		-- A kubb's spin is a turn setting (Jamie, 2026-11-20: "Keep between throws"): the
		-- spin a person threw the side's last kubb with (s.keptSpin, set from the action
		-- by Session:applyThrow) stays for the rest of the side's kubbs in this inkast
		-- turn, rethrows included, with the same scope as the circle. Arc and tilt are
		-- throw settings: freshPlan above put them back.
		s.spin = s.keptSpin or 0
	else
		s.drill = false
		s.keptSpin = nil
		retarget(s, keep)
	end
	s.thisDrill = false
	s.mode = "aim"
	s.flagText = nil
	s.cpuThrow, s.cpuPlan, s.cpuTarget, s.cpuSpeed, s.cpuAim = nil, nil, false, nil, nil
	s.remote = nil
	resetSwing(s)
	s.camMix, s.planHeld, s.shF = 0, false, nil
	replan(s)
	aimCamera(s)
end

-- Practice: drill kubbs (on) or throw batons (off).
function throw.setDrill(s, on)
	s.markerFixed = false
	s.drill = on and true or false
	s.projectile = on and "kubb" or "baton"
	s.projectileId = nil
	s.stanceSet = false
	freshPlan(s)
	s.keptSpin = nil
	clearLast(s)
	if on then
		markerHome(s)
	else
		s.playerX, s.playerY = 0, s.lineY
		retarget(s, false)
	end
	resetSwing(s)
	s.flagText = nil
	replan(s)
	aimCamera(s)
	return true
end

-- Practice: everything standing again.
function throw.reset(s)
	throw.standUp(s)
	s.thisDrill = false
	updateTargets(s)
	s.mode = "aim"
	resetSwing(s)
	if not s.drill then retarget(s, false) end
	-- practice with KUBBS on keeps its spin from throw to throw until the pitch is reset
	-- (a kubb's spin is a turn setting, Jamie, 2026-11-20)
	if s.drill then s.spin, s.keptSpin = 0, nil end
	s.planDirty = true
	replan(s)
	aimCamera(s)
end

-- The circle onto (x, y) (view frame), clamped by drill.clampMarker.
-- snap: onto a standing target within snapRadius (scenes/throw.lua aimAt);
-- without it the circle is where it was put, as the d-pad leaves it
-- (markerSet: kept for the team's next throw while a target stands near).
function throw.setTarget(s, x, y, snap)
	if s.markerFixed then return false end
	local mx, my = drill.clampMarker(x, y - s.lineY)
	s.markerX, s.markerY = mx, s.lineY + my
	if snap then
		settleMarker(s, s.projectile ~= "kubb")
	else
		s.markerSet = true
		settleMarker(s, false)
	end
	replan(s)
	aimCamera(s)
	return true
end

-- The stance onto (x, y), held to the line's ends, backMax behind it and
-- the forward limit (as walking is): "A has walked it".
function throw.setStance(s, x, y)
	local t = throw.tune
	s.playerX = max(-t.halfWidth, min(t.halfWidth, x))
	s.playerY = max(s.lineY - t.backMax, min(forwardLimit(s), y))
	s.stanceSet = true
	replan(s)
	aimCamera(s)
end

-- The stance follows the target again (plan.stance).
function throw.freeStance(s)
	s.stanceSet = false
	replan(s)
	aimCamera(s)
end

-- ARC and the drive's floor (0.16): the release a person sets is kept as they set it,
-- but never under the throw's floor at the time they set it (s.arcMin, plan.arcFloor),
-- so what ARC shows is what is kept. When the circle or the stance moves, the floor moves
-- with them: a kept release under the new floor is planned at the floor (and shown at
-- it), and when the floor falls again the plan comes back to the kept release, the value
-- the player last saw. A step goes from the release as it is planned (the effective one,
-- never the kept one under the floor) and never under the floor, so every step, and
-- every reversal at the floor, moves the throw at once (Codex on #47).
local function effectiveRelease(s)
	local f = s.arcMin or plan.tune.releaseMinDeg
	return s.release < f and f or s.release
end
throw.effectiveRelease = effectiveRelease

function throw.setArc(s, releaseDeg)
	local r = plan.clampRelease(releaseDeg, s.projectile)
	local f = s.arcMin or plan.tune.releaseMinDeg
	s.release, s.arcSet = r < f and f or r, true
	replan(s)
	aimCamera(s)
end

-- B + up/down: the release half an hour a step, from the release as planned.
function throw.stepArc(s, step)
	local r = plan.clampRelease(effectiveRelease(s) + step * plan.tune.arcStepDeg, s.projectile)
	local f = s.arcMin or plan.tune.releaseMinDeg
	s.release = r < f and f or r
	s.arcSet, s.planDirty = true, true
	replan(s)
	aimCamera(s)
end

-- B + left/right: a baton's tilt or a kubb's spin, a step.
function throw.stepSide(s, side)
	local pt = plan.tune
	if s.projectile == "kubb" then
		s.spin = max(-pt.spinSteps, min(pt.spinSteps, s.spin + side))
		s.planDirty = true
	else
		s.tilt = max(-pt.tiltMaxDeg, min(pt.tiltMaxDeg, s.tilt + side * pt.tiltStepDeg))
	end
end

-- Any value in range (Jamie, 2026-11-20): a baton's tilt in degrees, a kubb's spin in
-- taps (fractions too). Each does nothing for the other projectile. setArc takes any
-- release already (plan.clampRelease does not round).
local function finite(v) return type(v) == "number" and v == v end

function throw.setTilt(s, deg)
	if s.projectile == "kubb" or not finite(deg) then return false end
	s.tilt = plan.clampTilt(deg)
	return true
end

function throw.setSpin(s, taps)
	if s.projectile ~= "kubb" or not finite(taps) then return false end
	s.spin = plan.clampSpin(taps)
	s.planDirty = true
	replan(s)
	aimCamera(s)
	return true
end

-- What a slider draws for each of the plan's controls: its range, default, value, the
-- tick a held key slides by and the step a press jumps by. arc for every throw; tilt for
-- a baton, spin for a kubb. scope: "throw" (back to default at every throw) or "turn"
-- (kept for the side's next kubb in the inkast turn).
function throw.controls(s)
	local pt = plan.tune
	local kubb = s.projectile == "kubb"
	local out = {
		arc = { min = s.arcMin or pt.releaseMinDeg, max = pt.releaseMaxDeg,
			value = effectiveRelease(s), set = s.arcSet and true or false,
			knee = pt.driveKneeDeg,
			default = throw.defaultArc(s), tick = pt.arcTickDeg, step = pt.arcStepDeg,
			unit = "deg", scope = "throw" },
	}
	if kubb then
		out.spin = { min = -pt.spinSteps, max = pt.spinSteps, value = s.spin, default = 0, tick = pt.spinTick,
			step = 1, unit = "taps", radPerTap = pt.spinPerStep, baseRad = drill.tune.spiral, scope = "turn" }
	else
		out.tilt = { min = -pt.tiltMaxDeg, max = pt.tiltMaxDeg, value = s.tilt, default = 0, tick = pt.tiltTickDeg,
			step = pt.tiltStepDeg, unit = "deg", scope = "throw" }
	end
	return out
end

-- The plan starts afresh (arc follows the target, no tilt or spin).
function throw.freshPlan(s)
	freshPlan(s)
	replan(s)
	aimCamera(s)
end

-- ---------- the dial ----------

local function wrap(d)
	d = d % 360
	if d > 180 then d = d - 360 end
	return d
end

-- scenes/throw.lua swingInput: arming at the bottom of the turn, then core/swing.
local function swingInput(s, sw, delta, arm, prevArm, dt)
	if sw.phase == "idle" then
		if not s.armed then
			if swing.crossedBack(prevArm, arm) then
				s.armed = true
				delta = arm * swing.tune.forwardSign
			else
				delta = 0
			end
		elseif arm >= 0 then
			s.armed = false
			sw.pending = 0
			delta = 0
		end
	end
	local ev = swing.update(sw, delta, dt)
	if ev then s.armed = false end
	if sw.phase == "winding" and (s.lastBack or s.showVerdicts) then clearLast(s) end
	return ev
end

-- One aim frame (scenes/throw.lua aimInput and the aim part of throw.update).
-- inp = { arm = forward degrees in (-180, 180] or nil (the pointer is not
-- on the dial), dt = s, plan = the plan view held, move = {dx, dy} (the
-- circle's keys, -1..1), walk = {dx, dy} (the stance's keys) }.
-- Returns nil, "letdown" or "release" (then s.swing.result).
function throw.aimFrame(s, inp)
	local t = throw.tune
	local dt = inp.dt or 1 / 60
	if dt <= 0 then dt = 1 / 60 end
	local mv, wk = inp.move or {}, inp.walk or {}
	local mdx, mdy = mv.dx or mv[1] or 0, mv.dy or mv[2] or 0
	local wdx, wdy = wk.dx or wk[1] or 0, wk.dy or wk[2] or 0
	local holdPlan = inp.plan and true or false
	s.planHeld = holdPlan
	local moving = false
	if wdx ~= 0 or wdy ~= 0 then
		if wdx ~= 0 then
			s.playerX = max(-t.halfWidth, min(t.halfWidth, s.playerX + wdx * t.walkSpeed * dt))
		end
		if wdy ~= 0 then
			s.playerY = max(s.lineY - t.backMax, min(forwardLimit(s), s.playerY + wdy * t.walkSpeed * dt))
		end
		s.stanceSet, s.planDirty = true, true
	end
	if (mdx ~= 0 or mdy ~= 0) and not s.markerFixed then
		local dtn = drill.tune
		s.markerHeld = s.markerHeld + dt
		local v = min(dtn.markerSpeedMax, dtn.markerSpeed + dtn.markerAccel * s.markerHeld)
		local mx, my = drill.clampMarker(s.markerX + mdx * v * dt, s.markerY - s.lineY + mdy * v * dt)
		s.markerX, s.markerY, s.markerOnId, s.markerSet = mx, s.lineY + my, nil, true
		s.planDirty = true
		moving = true
	end
	if not moving then
		s.markerHeld = 0
		if s.markerMoving then settleMarker(s, false) end
	end
	s.markerMoving = moving
	local changed = s.planDirty or s.planLevel ~= throw.levelFor(s)
	if changed then replan(s) end
	-- the plan view: a smooth move both ways (camera.tune.shoulder.time)
	local st = camera.tune.shoulder
	local want = (s.planHeld and not s.watching) and 1 or 0
	local step = (st.time > 0) and dt / st.time or 1
	if s.camMix < want then s.camMix = min(want, s.camMix + step)
	elseif s.camMix > want then s.camMix = max(want, s.camMix - step) end
	aimCamera(s, (st.refit > 0) and min(1, dt / st.refit) or 1)
	if s.watching then return nil, changed end
	-- the dial
	local sw = s.swing
	local arm = inp.arm
	if holdPlan then
		-- while the plan view is held the dial does not throw (B on the Playdate)
		if s.touch or sw.phase ~= "idle" then resetSwing(s) end
		s.armed = false
		s.arm, s.pointerDown = arm, arm ~= nil
		return nil, changed
	end
	if inp.touch or s.touch then
		local ev = tw.web.touch.frame(s, inp.touch or {})
		if sw.phase == "winding" then clearLast(s) end
		return ev, changed, "touch"
	end
	if arm == nil then
		-- the pointer is up
		local was = s.pointerDown
		s.pointerDown = false
		s.arm = nil
		if not was then
			-- nothing held: only the cooldown runs
			if sw.phase == "cooldown" then swing.update(sw, 0, dt) end
			return nil, changed
		end
		if sw.phase == "swinging" then
			-- lifting the pointer while swinging forward is the release: core/swing is
			-- fed stopped frames until its stop test releases (or lets down)
			local d = wtune().dial
			local n = math.ceil(d.upFeedS / d.upFeedDt)
			for _ = 1, n do
				local ev = swing.update(sw, 0, d.upFeedDt)
				if ev then
					s.armed = false
					return ev, changed
				end
			end
			swing.reset(sw)
			s.armed = false
			return "letdown", changed
		end
		-- winding or armed: letting go puts the arm down, no throw
		local winding = sw.phase == "winding" or (sw.phase == "idle" and (s.armed or sw.pending > 0))
		if sw.phase ~= "cooldown" then swing.reset(sw) end
		s.armed = false
		return winding and "letdown" or nil, changed
	end
	local prevArm = s.arm
	if not s.pointerDown then
		-- a press: a press inside the dead zone behind 6 counts as starting at
		-- the bottom (tune.dial.pressArmDeg)
		s.pointerDown = true
		local pa = wtune().dial.pressArmDeg
		if pa > 0 and arm < 0 and arm > -pa then prevArm = 0 else prevArm = nil end
	end
	s.arm = arm
	local delta = 0
	if prevArm ~= nil then delta = wrap(arm - prevArm) * swing.tune.forwardSign end
	return swingInput(s, sw, delta, arm, prevArm, dt), changed
end

-- What the prompt over the clock says (scenes/throw.lua promptFor).
local function promptFor(s, sw, sol)
	local ph = sw.phase
	if ph == "winding" then
		local b = sw.back
		if b < sol.powerLo then return "WIND BACK" end
		if b <= sol.powerHi then return "FLICK!" end
		return "EASE OFF"
	elseif ph == "idle" then
		if not s.armed and (s.arm or 0) < -3 then return "CRANK DOWN" end
		return "WIND BACK"
	end
	return nil
end

-- hud.clock's state (scenes/throw.lua dialState). aiming: the throw is not
-- in the air (a recording playing back passes false).
function throw.dial(s, aiming)
	local st = {}
	local sw, sol = s.swing, s.sol
	local P
	if s.watching or (s.scripted and not aiming) then P = s.cpuPlan or (s.remote and sol) else P = sol end
	st.powerLo, st.powerHi = P and P.powerLo, P and P.powerHi
	st.releaseLo, st.releaseHi = P and P.releaseLo, P and P.releaseHi
	st.deadDeg, st.overDeg = swing.tune.startBackDeg, throw.tune.overDeg
	local stop = s.lastStop
	if stop and stop > 180 then stop = 180 end
	st.lastBack, st.lastStop, st.prompt = s.lastBack, stop, nil
	if s.mode == "cpuswing" then
		st.phase, st.arm, st.crank, st.back = s.cpuPhase, s.cpuArm, 0, s.cpuBack
		st.lastBack, st.lastStop = nil, nil
	elseif aiming and s.remote then
		-- (web) someone else's dial, from their aimState
		local r = s.remote
		st.phase, st.arm, st.crank, st.back = r.phase or "idle", r.arm or 0, r.arm or 0, r.back or 0
	elseif aiming and not s.watching then
		st.phase, st.arm, st.crank, st.back = sw.phase, sw.arm, s.arm or 0, sw.back
		st.prompt = promptFor(s, sw, sol)
	elseif aiming then
		st.phase, st.arm, st.crank, st.back = "idle", 0, 0, 0
		st.prompt = "WATCH"
	else
		st.phase, st.arm, st.crank, st.back = "idle", 0, stop or 0, 0
	end
	return st
end

-- ---------- the computer's throw ----------

-- scenes/throw.lua showAim: the computer's stance and aim before it throws.
function throw.showAim(s, a)
	if s.projectile == "kubb" and not a.drill then s.drill = false end
	s.playerX, s.playerY, s.swivel, s.loftDeg = a.x, a.y, a.swivel, a.loftDeg
	local P = a.plan
	s.cpuPlan, s.cpuSpeed = P, a.speed
	if a.drill and a.drill.spin then
		s.spin = drill.plannedSpin(a.drill.spin) / plan.tune.spinPerStep
	end
	s.cpuTarget = P ~= nil and P.tx ~= nil
	-- the circle and its label move together: the label names the piece the
	-- computer aims at (a.on), not the one the circle was on before (a
	-- play-test match: four batons of a turn labelled a4 were aimed at a3)
	if s.cpuTarget then s.markerX, s.markerY, s.markerOnId = P.tx, P.ty, a.on end
	aimCamera(s)
end

-- The computer's turn starts: its aim shows for tune cpuThink, then its arm
-- plays on the dial (cpuSwingTime), then it throws.
function throw.cpuBegin(s, a)
	s.watching = true
	throw.showAim(s, a)
	s.cpuAim, s.cpuWait = a, 0
	s.mode = "cputhink"
	s.scripted = true
	clearLast(s)
end

-- One frame of the computer's turn. Returns "release" when its throw leaves.
function throw.cpuFrame(s, dt)
	local t = throw.tune
	if s.mode == "cputhink" then
		s.cpuWait = s.cpuWait + dt
		aimCamera(s)
		if s.cpuWait < wtune().throw.cpuThink then return nil end
		local a = s.cpuAim
		s.cpuThrow, s.cpuT, s.cpuArm, s.cpuBack, s.cpuPhase = a, 0, 0, 0, "winding"
		s.cpuPlan = s.cpuPlan or a.plan
		s.mode = "cpuswing"
		if not a.swing then return "release" end
		return nil
	end
	if s.mode ~= "cpuswing" then return nil end
	local a = s.cpuThrow
	local back, rel = a.swing.back or 0, a.swing.releaseAngle or 0
	s.cpuT = s.cpuT + dt
	local tb = t.cpuSwingTime * t.cpuBackShare
	local u = s.cpuT
	if u < tb then
		local f = u / tb
		s.cpuArm, s.cpuPhase = -back * f * (2 - f), "winding"
		s.cpuBack = -s.cpuArm
	elseif u < t.cpuSwingTime then
		local f = (u - tb) / (t.cpuSwingTime - tb)
		s.cpuArm, s.cpuPhase, s.cpuBack = -back + (back + rel) * f * f, "swinging", back
	else
		return "release"
	end
	return nil
end

-- ---------- the launch ----------

-- The nerves (vendor/core/throwplan.lua plan.tune "Nerves", scenes/throw.lua
-- nervesFor): the player's throws go off the planned line and length by
-- seeded draws, as the computer's do. s.nerves (true or false) overrides
-- throw.nerves; a test that wants the plan's clean throw turns them off.
throw.nerves = true
local function nervesFor(s)
	if s.nerves ~= nil then return s.nerves end
	return throw.nerves
end

-- The player's launch for swing result r (scenes/throw.lua launch, before
-- fire): plan.launch against the solved plan. Returns L and how.
function throw.playerLaunch(s, r)
	local kubb = s.projectile == "kubb"
	-- (no level: the solution's, the person's meter at this distance)
	local o = { projectile = kubb and "kubb" or "baton", tilt = s.tilt, spin = s.spin }
	o.nerves = nervesFor(s) or nil
	if s.planDirty or s.planLevel ~= throw.levelFor(s) then replan(s) end
	local L = plan.launch(s.sol, r, o, {})
	return L, kubb and "drill" or "baton"
end

local CLEAN = { back = 0, releaseAngle = 0, flickFrac = 1, smoothness = 1, shake = 0, pull = 1, how = "stopped" }
throw.CLEAN = CLEAN

-- The computer's launch for its throw a (scenes/throw.lua autoFire, before fire).
function throw.cpuLaunch(s, a)
	local L = {}
	local d = a.drill
	if s.projectile == "kubb" and d then
		s.markerX, s.markerY, s.markerOnId = d.markerX, s.lineY + d.markerY, nil
		if d.noseDown then
			L.speed, L.loft, L.swivel, L.tilt, L.tumble, L.legal = a.speed, a.loftDeg, a.swivel, 0, 0, true
			L.noseDown, L.rollLand, L.spin, L.wobble = d.noseDown, d.rollLand, d.spin, d.wobble
			L.scatter = d.scatter
		else
			s.stanceSet, s.arcSet, s.tilt, s.spin = false, false, 0, 0
			s.projectile, s.drill = "kubb", true
			replan(s)
			CLEAN.back, CLEAN.releaseAngle = s.sol.back, s.sol.release
			plan.launch(s.sol, CLEAN, { projectile = "kubb", tilt = 0, spin = 0, level = throw.levelFor(s) }, L)
		end
		s.drill = true
		return L, "drill"
	end
	L.speed, L.loft, L.swivel, L.tilt, L.tumble, L.legal = a.speed, a.loftDeg, a.swivel, a.tilt or 0, a.tumbleRate,
		a.legal ~= false
	return L, s.projectile == "kubb" and "lob" or "baton"
end

-- ---------- the throw, whole ----------

local function copyCam(c)
	local o = {}
	for k, v in pairs(c) do o[k] = v end
	return o
end

local function scaledInt(v, k)
	return floor(v * k + 0.5)
end

-- The renderer's item for a piece (DESIGN 4.1): id, kind, pose, team.
local function teamOf(id, kind)
	if kind ~= "kubb" then return nil end
	local c = id:match("^([ab])%d")
	if c then return c:upper() end
	if id:match("^d%d") then return "A" end
	return nil
end
throw.teamOf = teamOf

local function itemOut(id, kind, x, y, z, qw, qx, qy, qz, toppled)
	return { id = id, kind = kind, x = x, y = y, z = z, qw = qw, qx = qx, qy = qy, qz = qz,
		team = teamOf(id, kind), toppled = toppled or false }
end
throw.itemOut = itemOut

-- The six stakes (static posts) as renderer items.
local function stakeItems(out)
	local h = phys.tune.stakeHeight
	for i, st in ipairs(pitch.stakes) do
		out[#out + 1] = itemOut("stake" .. i, "stake", st.x, st.y, h / 2, 1, 0, 0, 0)
	end
	return out
end

-- The pitch as it stands, for the renderer (aiming).
function throw.items(s)
	local out = {}
	for _, it in ipairs(s.items) do
		out[#out + 1] = itemOut(it.id, it.kind, it.x, it.y, it.z, it.qw, it.qx, it.qy, it.qz, it.toppled)
	end
	return stakeItems(out)
end

-- Engine pieces and debris (core/match's setup shape) as the renderer's items, without
-- touching a throw's state: the pitch as it stands while nothing is set up to throw
-- (raising, punishment kubbs, the end).
function throw.itemsOf(pieces, debris)
	return throw.items { items = itemsFrom(pieces, debris) }
end

-- Fire launch L (how: "baton", "drill" or "lob") from where the player
-- stands, run the world to rest and return the recording (scenes/throw.lua
-- fire, then flightUpdate's playback run to the end and landed). s.last
-- keeps what the playback camera needs.
function throw.fire(s, L, how, info)
	info = info or {}
	local t = throw.tune
	local wt = wtune().throw
	local aimCamNow
	-- the follow camera starts from the aim camera as it is in first person
	s.camMix, s.planHeld, s.shF = 0, false, nil
	aimCamera(s)
	aimCamNow = copyCam(s.aimCam)
	local fl = flight.new()
	local kubb = how ~= "baton"
	local drilling = how == "drill"
	if drilling and not s.projectileId then
		s.drillSeq = s.drillSeq + 1
		s.drillId = "d" .. s.drillSeq
	end
	s.thisDrill = drilling
	local id = s.projectileId or (drilling and s.drillId) or nil
	local tumble = drilling and 0 or (L.tumble or 0)
	local tilt = kubb and 0 or (L.tilt or 0)
	-- a baton's hand (flight.handAt): from the planned distance, the stance to
	-- the circle, as plan.solve has it; a kubb leaves at the feet as before
	local handZ, handFwd, handTip = nil, nil, nil
	if not kubb then
		local _
		handZ, handFwd, _, _, handTip = flight.handAt(sqrt((s.markerX - s.playerX) ^ 2 + (s.markerY - s.playerY) ^ 2))
	end
	flight.launch(fl, s.playerX, s.playerY, L.swivel, L.loft, L.speed, tumble, tilt, handZ, handFwd, handTip)
	-- In practice the six batons stay where they landed. Pick up the oldest
	-- for the seventh throw, retaining every other body in the solver.
	if not kubb and not s.projectileId then
		s.practiceBaton = (s.practiceBaton or 0) % 6 + 1
		id = s.practiceBaton == 1 and "baton" or ("baton" .. s.practiceBaton)
		for i, it in ipairs(s.items) do
			if it.id == id then table.remove(s.items, i); break end
		end
	end
	local pieces = {}
	for i, it in ipairs(s.items) do
		pieces[i] = { id = it.id, kind = it.kind, x = it.x, y = it.y, z = it.z,
			qw = it.qw, qx = it.qx, qy = it.qy, qz = it.qz, toppled = it.toppled }
	end
	local w = phys.new { surface = s.surface, pieces = pieces, windX = s.windX, windY = s.windY }
	local b
	if kubb then
		if drilling then
			b = phys.launchDrill(w, id, s.playerX, s.playerY, L.swivel, L.loft, L.speed, L.noseDown, L.rollLand,
				L.spin, L.wobble, L.scatter)
		else
			b = phys.launchKubb(w, id, s.playerX, s.playerY, L.swivel, L.loft, L.speed, tumble)
		end
	else
		b = phys.launchBaton(w, s.playerX, s.playerY, L.swivel, L.loft, L.speed, tumble, tilt, id, handZ, handFwd, handTip)
	end
	-- Listen after the solver. Keep one strike per unordered pair, taking
	-- the strongest contact point of its first pressing step (N s).
	local contacts, pairsSeen, batonLanding = {}, {}, nil
	w.onContact = function(time, a, other, impulse)
		local strength = min(1, impulse / 2)
		if not other then
			if a == b and a.kind == "baton" then
				if not batonLanding then
					batonLanding = { t = time, surface = s.surface, strength = strength }
				elseif batonLanding.t == time then
					batonLanding.strength = max(batonLanding.strength, strength)
				end
			end
			return
		end
		local key = min(a.index, other.index) * w.n + max(a.index, other.index)
		local e = pairsSeen[key]
		if not e then
			e = { t = time, a = a.kind, b = other.kind, idA = a.id, idB = other.id, strength = strength }
			pairsSeen[key] = e
			contacts[#contacts + 1] = e
		elseif e.t == time then
			e.strength = max(e.strength, strength)
		end
	end
	-- ground impacts, only when asked (throw.impacts): for a scene that rings, puffs or
	-- sprays where something meets the ground. One per piece per strike: the touches
	-- within impactGap of its first make one, at the strongest point. In the throw's
	-- frame, on the recording's clock; never in a snapshot, an action or a hash
	local impacts, lastImpact = nil, nil
	if throw.impacts then
		impacts, lastImpact = {}, {}
		w.onGround = function(time, a, impulse, px, py, speed)
			if speed < t.impactSpeed then return end
			local e = lastImpact[a]
			if e and time - e.t <= t.impactGap then
				if impulse > e.impulse then e.x, e.y, e.impulse = px, py, impulse end
				if speed > e.speed then e.speed = speed end
				return
			end
			if #impacts >= t.impactMax then return end
			e = { t = time, x = px, y = py, id = a.id, with = a.kind, thrown = a == b, speed = speed,
				impulse = impulse }
			lastImpact[a] = e
			impacts[#impacts + 1] = e
		end
	end
	local pb = playback.new(w, wt.frameDt)
	playback.finish(pb)
	w.onContact = nil
	w.onGround = nil
	if impacts then
		for _, e in ipairs(impacts) do
			e.strength = min(1, e.impulse / 2)
			e.impulse = nil
		end
	end
	s.throws = s.throws + 1
	local legal = L.legal ~= false
	-- landed (scenes/throw.lua): the result, the distance, the rest distance
	local res = phys.result(w)
	local fc = w.firstContact
	local ex, ey
	if fc then ex, ey = fc.x, fc.y
	else
		local x, y = playback.pose(pb, b.index, pb.frames)
		ex, ey = x, y
	end
	local distance = sqrt((ex - fl.ox) ^ 2 + (ey - fl.oy) ^ 2)
	local down = #res.toppled
	local hit = w.firstHit and w.firstHit.with or nil
	local restCm, restText, restX, restY
	if drilling then
		local rb = res.bodies[b.id]
		restX, restY = rb.x, rb.y
		restCm = floor(100 * sqrt((restX - s.markerX) ^ 2 + (restY - s.markerY) ^ 2) + 0.5)
		restText = (restCm < 100) and fmt("%d CM AWAY", restCm) or fmt("%.1f M AWAY", restCm / 100)
	end
	-- the pieces where they came to rest (landed)
	for _, it in ipairs(s.items) do
		local rb = res.bodies[it.id]
		if rb then
			it.x, it.y, it.z, it.qw, it.qx, it.qy, it.qz = rb.x, rb.y, rb.z, rb.qw, rb.qx, rb.qy, rb.qz
			it.toppled = rb.toppled
		end
	end
	if kubb then
		local rb = res.bodies[b.id]
		s.projItem = { id = b.id, kind = "kubb", x = rb.x, y = rb.y, z = rb.z, qw = rb.qw, qx = rb.qx,
			qy = rb.qy, qz = rb.qz, toppled = rb.toppled }
	else
		s.projItem = nil
	end
	if not kubb and not s.projectileId then
		local resting = res.bodies[b.id]
		resting.id = b.id
		s.items[#s.items + 1] = newItem(resting)
	end
	local flag
	if not legal and not s.kid then flag = "HELICOPTER"
	elseif drilling then flag = nil
	elseif down > 0 then flag = down .. " DOWN"
	else flag = "MISS" end

	-- the recording's bodies: every body that moved, from its first moving frame
	local K = 10 ^ wt.poseDecimals
	local bodies, items0 = {}, {}
	for i = 1, w.n do
		local bd = w.bodies[i]
		local r = pb.rec[i]
		if bd.kind ~= "stake" then
			items0[#items0 + 1] = itemOut(bd.id, bd.kind, r.x, r.y, r.z, r.qw, r.qx, r.qy, r.qz, bd.wasToppled)
		end
		if r.start >= 0 then
			local d, parts = r.data, {}
			for j = 1, #d do parts[j] = scaledInt(d[j], K) end
			bodies[#bodies + 1] = {
				id = bd.id, kind = bd.kind, team = teamOf(bd.id, bd.kind), start = r.start,
				frames = #d // 7,
				poses = tw.web.json.raw("[" .. table.concat(parts, ",") .. "]"),
				touchT = bd.touchT, toppleT = bd.toppleT,
				thrown = bd == w.projectile,
			}
		end
	end
	stakeItems(items0)

	-- the timeline: the hit, the knocks, the burst, the slow motion
	local function point(p)
		if not p then return nil end
		return { t = p.t, x = p.x, y = p.y, z = p.z, with = p.with }
	end
	local touches = {}
	local buf = {}
	local n = burstpick.touches(w, -1, math.huge, buf)
	for i = 1, n do touches[i] = { id = buf[i].id, kind = buf[i].kind, t = buf[i].touchT } end
	table.sort(touches, function(a, c) if a.t ~= c.t then return a.t < c.t end return a.id < c.id end)

	local function anchorOf(piece)
		local fh = w.firstHit
		if fh and fh.with == piece.id then return { x = fh.x, y = fh.y, z = fh.z } end
		local x, y, z = playback.poseAt(pb, piece.index, burstpick.hitTime(piece))
		return { x = x, y = y, z = z + wt.burstLift }
	end
	-- the bursts (render/burst with the whole throw known): the first as the
	-- picture reaches the first falling piece's impact, then the king's if
	-- the king falls later (it replaces whatever showed), each with its
	-- anchor; takenBack when the piece struck was left standing after all
	local bursts = {}
	if how == "baton" then
		local kind, a, b2, sure, sure2 = burstpick.pick(w, math.huge)
		if kind then
			-- the first burst: what the picture shows at the earliest impact
			local first = a
			for i = 1, w.n do
				local bd = w.bodies[i]
				if burstpick.falling(bd, w) and burstpick.hitTime(bd) < burstpick.hitTime(first) then first = bd end
			end
			local k1, a1, s1, sure1, sure21 = burstpick.pick(w, burstpick.hitTime(first))
			local function entry(k, p, second, sr, sr2)
				local e = { kind = k, id = p.id, start = burstpick.hitTime(p), anchor = anchorOf(p),
					sure = sr and true or false,
					takenBack = (not sr) and burstpick.stoodUp(p, true) or false }
				if second then
					e.second = { id = second.id, start = burstpick.hitTime(second), anchor = anchorOf(second),
						takenBack = (not sr2) and burstpick.stoodUp(second, true) or false }
				end
				return e
			end
			if k1 then bursts[1] = entry(k1, a1, s1, sure1, sure21) end
			if kind == "king" and (not k1 or k1 ~= "king") then bursts[#bursts + 1] = entry(kind, a, b2, sure, sure2) end
		end
	end
	local hitAt = w.firstHit and w.firstHit.t or nil
	local slow = nil
	if hitAt then
		local k = playback.slow
		slow = { hit = hitAt, from = max(0, hitAt - k.lead), full = hitAt + k.hold, to = hitAt + k.hold + k.ease,
			rate = k.rate }
	end
	local verdicts = nil
	if info.verdicts then
		-- side (PULLED LEFT, STRAIGHT, PULLED RIGHT) only when the throw
		-- recorded one: a match saved before the nerves has no sideV
		local pw, rl, sd = plan.verdictText(info.verdicts)
		local sideV = info.verdicts.sideV
		verdicts = { power = pw, release = rl, steady = sd, powerV = info.verdicts.powerV,
			releaseV = info.verdicts.releaseV, sideV = sideV, side = sideV and plan.sideText(sideV) or nil }
	end
	local rec = {
		frameDt = wt.frameDt, frames = pb.frames, duration = pb.frames * wt.frameDt,
		poseScale = K,
		projectile = { id = b.id, kind = b.kind, how = how },
		items = items0,
		bodies = bodies,
		launch = { x = s.playerX, y = s.playerY, speed = L.speed, loft = L.loft, swivel = L.swivel, tilt = tilt,
			tumble = tumble, legal = legal },
		landing = { x = fl.lx, y = fl.ly, T = fl.T },
		result = {
			flag = flag, legal = legal, down = down, toppled = res.toppled, hit = hit,
			distance = distance, landX = ex, landY = ey,
			restCm = restCm, restText = restText, restX = restX, restY = restY,
			verdicts = verdicts, back = info.back, stop = info.stop,
		},
		timeline = {
			firstContact = point(w.firstContact), firstHit = point(w.firstHit),
			touches = touches, bursts = bursts, slow = slow,
			contacts = contacts, batonLanding = batonLanding,
			impacts = impacts,
		},
		marker = drilling and { x = s.markerX, y = s.markerY, r = t.markerRadius } or nil,
	}
	-- what the playback camera needs (not in the recording)
	s.last = {
		pb = pb, w = w, fl = fl, b = b, aimCam = aimCamNow, rec = rec, bursts = bursts,
		hitAt = hitAt, side = (fl.lx > 0) and 1 or -1, kubb = kubb, drilling = drilling,
		markerX = s.markerX, markerY = s.markerY, res = res,
	}
	s.lastSlew = nil
	s.result = res
	s.lastDrilledBody = drilling and b.id or nil
	return rec, res, legal
end

-- Practice, once the throw is at rest (scenes/throw.lua throw.update's rest
-- branch): a drilled kubb becomes a piece (the oldest past drillKeep goes),
-- or all far base kubbs down stands the pitch up again; the circle stays on
-- its target while it stands, else the nearest one.
function throw.afterRest(s)
	resetSwing(s)
	if s.thisDrill then
		local it = s.projItem
		s.projItem = nil
		if it then
			it.drilled = true
			s.items[#s.items + 1] = it
			local n = 0
			for _, x in ipairs(s.items) do if x.drilled then n = n + 1 end end
			if n > throw.tune.drillKeep then
				for i, x in ipairs(s.items) do
					if x.drilled then table.remove(s.items, i) break end
				end
			end
		end
	else
		local any, all = false, true
		for _, it in ipairs(s.items) do
			if it.base then
				any = true
				if not it.toppled then all = false end
			end
		end
		if any and all then throw.standUp(s) end
	end
	s.thisDrill = false
	updateTargets(s)
	if not s.drill then retarget(s, true) end
	s.planDirty = true
	replan(s)
	aimCamera(s)
end

-- ---------- playback ----------

-- The impact camera's aim point slews toward the hit at focusSpeed m/s of
-- real time while the picture plays at playback.speed. On the Playdate it
-- moves a step each device frame; here it is integrated once, in fixed real
-- steps (tune.throw.slewDt), so the camera is a function of shown time.
local function slewTable(s)
	local L = s.last
	if L.slew then return L.slew end
	local t = throw.tune
	local dt = wtune().throw.slewDt
	local fl, w = L.fl, L.w
	local dur = L.pb.frames * L.pb.frameDt
	local ts, xs, ys = { 0 }, { fl.lx }, { fl.ly }
	local fx, fy, sh = fl.lx, fl.ly, 0
	local bursts = L.bursts
	local orbitFrom = nil
	if t.swingDeg ~= 0 and bursts[1] and not bursts[1].takenBack then orbitFrom = bursts[1].start end
	local n = 1
	for _ = 1, 20000 do
		sh = min(dur, sh + dt * playback.speed(sh, L.hitAt))
		local tx, ty = fl.lx, fl.ly
		local hit = w.firstHit
		if hit then tx, ty = hit.x, hit.y end
		if orbitFrom and sh >= orbitFrom then
			-- the half circle goes round the piece its burst is for (the latest started)
			local B = bursts[1]
			for i = 2, #bursts do if bursts[i].start <= sh then B = bursts[i] end end
			tx, ty = B.anchor.x, B.anchor.y
		end
		local dx, dy = tx - fx, ty - fy
		local d, step = sqrt(dx * dx + dy * dy), t.focusSpeed * dt
		if d > step then dx, dy = dx * step / d, dy * step / d end
		fx, fy = fx + dx, fy + dy
		n = n + 1
		ts[n], xs[n], ys[n] = sh, fx, fy
		if sh >= dur and d <= step then break end
	end
	L.slew = { t = ts, x = xs, y = ys, n = n, orbitFrom = orbitFrom }
	return L.slew
end

local function focusAt(sl, t)
	local ts = sl.t
	if t <= ts[1] then return sl.x[1], sl.y[1] end
	if t >= ts[sl.n] then return sl.x[sl.n], sl.y[sl.n] end
	local lo, hi = 1, sl.n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if ts[mid] <= t then lo = mid else hi = mid end
	end
	local t0, t1 = ts[lo], ts[hi]
	local a = (t1 > t0) and (t - t0) / (t1 - t0) or 1
	return sl.x[lo] + (sl.x[hi] - sl.x[lo]) * a, sl.y[lo] + (sl.y[hi] - sl.y[lo]) * a
end

-- The last throw at shown time t (s from the release): the camera, every
-- piece's pose, the playback speed there and the dial.
function throw.showAt(s, t)
	local L = s.last
	if not L then return nil end
	local tt = throw.tune
	local pb, w, fl = L.pb, L.w, L.fl
	local dur = pb.frames * pb.frameDt
	if t < 0 then t = 0 elseif t > dur then t = dur end
	local items = {}
	for i = 1, w.n do
		local bd = w.bodies[i]
		if bd.kind ~= "stake" then
			local x, y, z, qw, qx, qy, qz = playback.poseAt(pb, i, t)
			local toppled = bd.wasToppled or (bd.toppleT ~= nil and bd.toppleT <= t)
			items[#items + 1] = itemOut(bd.id, bd.kind, x, y, z, qw, qx, qy, qz, toppled)
		end
	end
	stakeItems(items)
	-- the cameras (scenes/throw.lua flightUpdate and the follow in throw.update)
	local sl = slewTable(s)
	local focusX, focusY = focusAt(sl, t)
	local orbit, open = 0, 0
	if sl.orbitFrom and t >= sl.orbitFrom then
		open = camera.smooth((t - sl.orbitFrom) / tt.swingTime)
		orbit = rad(tt.swingDeg) * open
	end
	local impactCam = camera.new()
	camera.impact(impactCam, focusX, focusY, fl.dx, fl.dy, L.side, orbit, open)
	local bx, by, bz = playback.poseAt(pb, L.b.index, t)
	local progress = (fl.T <= 0) and 1 or max(0, min(1, t / fl.T))
	local fc = w.firstContact
	if fc and t >= fc.t then
		local dx, dy = bx - focusX, by - focusY
		local d, R = sqrt(dx * dx + dy * dy), tt.frameRadius
		if d > R then bx, by = focusX + dx * R / d, focusY + dy * R / d end
	end
	local view = camera.new()
	camera.follow(view, L.aimCam, impactCam, progress, bx, by, bz)
	local burst = nil
	for _, e in ipairs(L.bursts) do
		if e.start <= t then burst = e.kind end
	end
	return {
		t = t, done = t >= dur, speed = playback.speed(t, L.hitAt),
		camera = view, items = items, burst = burst,
	}
end

tw.web.throw = throw
