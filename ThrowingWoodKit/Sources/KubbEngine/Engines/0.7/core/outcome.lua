-- Physics <-> rules. Turns the rules engine's pitch (tw.rules poses, world
-- frame) into physics pieces in the thrower's view frame (core/frame), and a
-- finished physics throw (tw.world.result, view frame) back into the outcome
-- records the engine takes (docs/notes/rules-engine.md "Baton outcome", "Kubb-toss outcome").
-- Pure Lua: no playdate.*. Not a per-frame path: once per throw.
--
--   local pieces = outcome.pieces(g, side)        -- what is on the pitch now
--   local w = tw.world.new{ surface = s, pieces = pieces }
--   ... launch, run to rest ...
--   local res = tw.world.result(w)
--   g:throwBaton(outcome.baton(res, pieces, side, illegal))
--   g:toss(outcome.toss(res, pieces, side, kubbId))
--
-- A piece of outcome.pieces is a tw.world piece ({id, kind, x, y, qw..qz,
-- toppled} in the view frame) with what the conversion needs back:
-- role ("base" | "field" | "king"), half ("A" | "B") and pose (the engine's
-- pose, world frame).
import "core/tw"
import "core/frame"
import "core/quat"

local frame, quat = tw.frame, tw.quat
local sqrt, atan, cos, sin, pi = math.sqrt, math.atan, math.cos, math.sin, math.pi

local outcome = {}

outcome.tune = {
	standingCos = 0.7071, -- a kubb whose long axis is within 45 degrees of vertical stands on an end
	movedEps = 0.002,     -- m; a piece whose center moved more than this has moved
	turnedEps = 0.02,     -- rad of yaw (or tilt) change that also counts as moved
	onTopLying = 0.08,    -- m; a lying kubb's center higher than this rests on something
	                      -- (on the ground it is 0.035, flat on a lying kubb 0.105)
	onTopStanding = 0.11, -- m; the same for a kubb on an end (0.075 on the ground)
	onTopReach = 0.25,    -- m; the piece it rests on is the nearest within this
}

-- ---------- poses ----------

-- The engine pose of a body pose (any frame; the result is in the same
-- frame): standing when the long axis (column 3) is within 45 degrees of
-- vertical; angle is the yaw of the square when standing, else the long
-- axis direction. Returns the pose and the center height z.
function outcome.poseOf(x, y, z, qw, qx, qy, qz)
	local r11, _, r13, r21, _, r23, _, _, r33 = quat.toMatrix(qw, qx, qy, qz)
	local standing = r33 >= outcome.tune.standingCos or r33 <= -outcome.tune.standingCos
	local angle
	if standing then angle = atan(r21, r11) else angle = atan(r23, r13) end
	return { x = x, y = y, standing = standing, angle = angle }, z
end

-- The body orientation of an engine pose: standing upright turned by angle,
-- or lying on a face with the long axis along angle.
function outcome.quatOf(pose)
	local a = pose.angle or 0
	if pose.standing then return cos(a / 2), 0, 0, sin(a / 2) end
	local tw_, tx, ty, tz = quat.fromAxisAngle(1, 0, 0, -pi / 2)       -- local z -> +y, a face down
	local zw, zx, zy, zz = quat.fromAxisAngle(0, 0, 1, a - pi / 2)    -- +y -> the axis direction
	return quat.mul(zw, zx, zy, zz, tw_, tx, ty, tz)
end

-- ---------- the engine's pitch as physics pieces ----------

local function piece(id, kind, role, half, pose, side)
	local v = frame.pose(side, pose)
	local qw, qx, qy, qz = outcome.quatOf(v)
	return { id = id, kind = kind, role = role, half = half, pose = pose,
		x = v.x, y = v.y, qw = qw, qx = qx, qy = qy, qz = qz, toppled = not v.standing }
end

-- Every piece the engine has on the pitch (kubbs in id order, then the king),
-- in `side`'s view frame.
function outcome.pieces(g, side)
	local out = {}
	for _, k in ipairs(g:onPitch()) do
		out[#out + 1] = piece(k.id, "kubb", k.kind, k.half, k.pose, side)
	end
	out[#out + 1] = piece("king", "king", "king", nil, g.king.pose, side)
	return out
end

-- ---------- results back to outcome records ----------

-- Did this body move from where its piece started?
local function movedFrom(p, rb)
	local t = outcome.tune
	local dx, dy = rb.x - p.x, rb.y - p.y
	if dx * dx + dy * dy > t.movedEps * t.movedEps then return true end
	-- turned or tilted: compare the rotation (|dot| of the quaternions)
	local d = rb.qw * p.qw + rb.qx * p.qx + rb.qy * p.qy + rb.qz * p.qz
	if d < 0 then d = -d end
	return d < cos(t.turnedEps / 2)
end

-- The world-frame pose of a body result (view frame) for `side`.
local function worldPose(side, rb)
	local p, z = outcome.poseOf(rb.x, rb.y, rb.z, rb.qw, rb.qx, rb.qy, rb.qz)
	return frame.pose(side, p), z
end

-- moved = { [id] = world pose } of every piece that moved.
local function movedPoses(res, pieces, side)
	local moved = {}
	for _, p in ipairs(pieces) do
		local rb = res.bodies[p.id]
		if rb and movedFrom(p, rb) then moved[p.id] = (worldPose(side, rb)) end
	end
	return moved
end

local function byId(pieces)
	local m = {}
	for _, p in ipairs(pieces) do m[p.id] = p end
	return m
end

-- The baton outcome. `res` is tw.world.result of a world built from
-- `pieces` (outcome.pieces for `side`), `illegal` the swing's verdict
-- (a helicopter).
--   toppled      every kubb and the king that toppled (world.result)
--   kingToppled
--   moved        rest pose (world frame) of every piece that moved
--   ownHalfHit   field kubbs in the thrower's own half that anything touched
--                (in practice the baton: they stand far from everything else)
function outcome.baton(res, pieces, side, illegal)
	local o = { illegal = illegal and true or false, toppled = {}, kingToppled = res.kingToppled and true or false,
		moved = movedPoses(res, pieces, side), ownHalfHit = {} }
	for i, id in ipairs(res.toppled) do o.toppled[i] = id end
	local info = byId(pieces)
	for _, id in ipairs(res.touched) do
		local p = info[id]
		if p and p.role == "field" and p.half == side then o.ownHalfHit[#o.ownHalfHit + 1] = id end
	end
	table.sort(o.ownHalfHit)
	return o
end

-- The piece a kubb body rests on: when its center sits clearly above the
-- ground, the nearest other piece where it ended (nil otherwise).
local function restingOn(res, pieces, rb, id, standing, z, extraId)
	local t = outcome.tune
	if (standing and z <= t.onTopStanding) or (not standing and z <= t.onTopLying) then return nil end
	local best, bd = nil, t.onTopReach
	for _, p in ipairs(pieces) do
		local b = res.bodies[p.id]
		if b and p.id ~= id then
			local dx, dy = b.x - rb.x, b.y - rb.y
			local d = sqrt(dx * dx + dy * dy)
			if d < bd then best, bd = p.id, d end
		end
	end
	-- the thrown kubb is not one of `pieces` (it is the projectile body)
	local b = extraId and extraId ~= id and res.bodies[extraId]
	if b then
		local dx, dy = b.x - rb.x, b.y - rb.y
		if sqrt(dx * dx + dy * dy) < bd then best = extraId end
	end
	return best
end

-- The kubb-toss outcome for kubb `kubbId` (the projectile body, id kubbId).
--   rest         its rest pose (world frame); onTop = the id of the piece it
--                rests on when its center sits clearly above the ground
--   moved        rest poses of every other piece that moved; a field kubb
--                left resting on another gets onTop too (the engine lowers
--                it when the round is judged, II.D.6)
--   kingToppled
--   ownHalfHit   pieces in the thrower's own half that anything touched
-- Every kubb thrown this turn is one of `pieces` (outcome.pieces), in or
-- out, so a kubb may rest on any of them.
function outcome.toss(res, pieces, side, kubbId)
	local rb = assert(res.bodies[kubbId], "no body " .. tostring(kubbId))
	local rest, z = worldPose(side, rb)
	local on = restingOn(res, pieces, rb, kubbId, rest.standing, z)
	if on then rest.onTop, rest.standing = on, false end
	local o = { rest = rest, moved = {}, kingToppled = res.kingToppled and true or false, ownHalfHit = {} }
	for _, p in ipairs(pieces) do
		local b = res.bodies[p.id]
		if b and p.id ~= kubbId and movedFrom(p, b) then
			local pose, pz = worldPose(side, b)
			if p.role == "field" then
				local under = restingOn(res, pieces, b, p.id, pose.standing, pz, kubbId)
				if under then pose.onTop, pose.standing = under, false end
			end
			o.moved[p.id] = pose
		end
	end
	local info = byId(pieces)
	for _, id in ipairs(res.touched) do
		local p = info[id]
		if p and p.role ~= "king" and p.half == side then o.ownHalfHit[#o.ownHalfHit + 1] = id end
	end
	table.sort(o.ownHalfHit)
	return o
end

tw.outcome = outcome
