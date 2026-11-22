-- What lies on the pitch within a turn that the rules engine does not keep:
-- the batons already thrown and the kubbs they knocked down. In Kubb a
-- toppled kubb and a thrown baton stay where they came to rest until the
-- turn is over; a later baton can hit them, be deflected by them, or push
-- them into a standing kubb. The engine is still the judge (it has the
-- toppled kubbs in a hand already); this module only carries their poses
-- from throw to throw so the next throw's physics world has them as bodies.
-- Pure Lua: no playdate.*. Not a per-frame path: once per throw.
--
-- It also carries the exact body pose (tilt, height, which face is down) of
-- every lying kubb the engine does keep on the pitch: during the inkast the
-- tossed kubbs lie where they landed (in bounds or out) until they are raised
-- or picked up for a rethrow, and the engine's
-- pose ({x, y, angle}) would lay them flat on a face. An exact pose is used
-- only while the engine's pose is the one it was recorded with.
--
-- Standing kubbs and the king get the same: a piece a throw moved without
-- toppling stands as the throw left it (leaning on a neighbour, tilted on an
-- edge, raised on a piece), not stood up straight. These poses outlast the
-- turn (the pieces stay on the pitch); the turn's debris does not, so a new
-- turn marks them to be settled (d.settle): core/match runs the world to rest
-- once before the next throw, in case what propped a leaning piece has gone.
--
--   local d = debris.new()
--   debris.begin(d, turn)                  -- a new turn clears everything
--   local list = debris.pieces(d, side)    -- tw.world pieces, view frame
--   debris.applyExact(d, pieces, side)     -- exact poses onto outcome.pieces
--   ... the throw ...
--   debris.carry(d, res, side)             -- struck debris moves
--   debris.add(d, id, kind, res, side)     -- a baton or newly downed kubb
--   debris.recordExact(d, g, res, side)
--
-- Poses are kept in the world frame (core/frame) and handed out in the
-- thrower's view frame, so Team B's turned view is the same pitch.
import "core/tw"
import "core/frame"
import "core/body"

local frame, kinds = tw.frame, tw.body.kinds

local debris = {}

debris.tune = {
	matchEps = 1e-6,   -- m; an exact pose applies while the engine's x, y are these
}

function debris.new()
	return { turn = nil, list = {}, exact = {} }
end

-- Clear everything (the hand-off: the pitch is the engine's again).
function debris.clear(d)
	d.list, d.exact = {}, {}
end

-- Start (or continue) turn `turn`: a different turn clears the debris and
-- the lying poses. Standing pieces stay as they are; the debris that may
-- have propped them is gone, so they are to be settled.
function debris.begin(d, turn)
	if d.turn ~= turn then
		local keep = {}
		for id, e in pairs(d.exact) do
			if e.standing then keep[id] = e end
		end
		d.list, d.exact = {}, keep
		d.turn = turn
		d.settle = next(keep) ~= nil or nil
	end
end

function debris.count(d) return #d.list end

-- A world-frame pose from a result body (view frame of `side`).
local function fromBody(side, rb)
	local x, y = frame.point(side, rb.x, rb.y)
	local qw, qx, qy, qz = frame.quat(side, rb.qw, rb.qx, rb.qy, rb.qz)
	return x, y, rb.z, qw, qx, qy, qz
end

local function setFrom(e, side, rb)
	e.x, e.y, e.z, e.qw, e.qx, e.qy, e.qz = fromBody(side, rb)
end

local function find(d, id)
	for i, e in ipairs(d.list) do
		if e.id == id then return e, i end
	end
	return nil
end

-- Add (or move) piece `id` of `kind` ("kubb" | "baton") at its rest pose in
-- `res` (tw.world result, view frame of `side`). Returns the entry, or nil
-- when the result has no such body.
function debris.add(d, id, kind, res, side)
	local rb = res.bodies[id]
	if not rb then return nil end
	local e = find(d, id)
	if not e then
		e = { id = id, kind = kind }
		d.list[#d.list + 1] = e
	end
	setFrom(e, side, rb)
	return e
end

-- Move every debris piece to where this throw left it (struck or not: a
-- body that never woke rests where it started).
function debris.carry(d, res, side)
	for _, e in ipairs(d.list) do
		local rb = res.bodies[e.id]
		if rb then setFrom(e, side, rb) end
	end
end

-- The debris as tw.world pieces (full poses, already down) in `side`'s view
-- frame: { id, kind, x, y, z, qw..qz, toppled = true, debris = true }.
function debris.pieces(d, side)
	local out = {}
	for i, e in ipairs(d.list) do
		local x, y = frame.point(side, e.x, e.y)
		local qw, qx, qy, qz = frame.quat(side, e.qw, e.qx, e.qy, e.qz)
		out[i] = { id = e.id, kind = e.kind, x = x, y = y, z = e.z, qw = qw, qx = qx, qy = qy, qz = qz,
			toppled = true, debris = true }
	end
	return out
end

-- Would a standing body fall with its prop taken away (body.wouldFall from
-- a result body)? The engine may call such a piece standing (a thrown kubb
-- within 45 degrees of upright in the inkast, core/outcome); it is stood up
-- straight, as it always was, not carried leaning past its tipping point.
local function pastTipping(rb)
	local k = kinds[rb.kind]
	if not k or not k.hz then return false end
	local qw, qx, qy, qz = rb.qw, rb.qx, rb.qy, rb.qz
	local up = math.abs(1 - 2 * (qx * qx + qy * qy))
	return k.hz * math.abs(2 * (qx * qz - qw * qy)) > k.hx * up or k.hz * math.abs(2 * (qy * qz + qw * qx)) > k.hy * up
end

-- Remember the exact body pose of every kubb the engine has on the pitch
-- (lying or standing) and of the king, where the engine pose is where its
-- body came to rest. A piece whose body ended elsewhere (a throw put back, a
-- kubb raised where it was) keeps the pose it had.
local function record(d, keep, id, p, res, side, eps)
	local rb = res.bodies[id]
	local e
	if rb and not (p.standing and pastTipping(rb)) then
		local x, y = frame.point(side, rb.x, rb.y)
		if (x - p.x) ^ 2 + (y - p.y) ^ 2 <= eps * eps then
			e = { ex = p.x, ey = p.y, standing = p.standing or nil }
			setFrom(e, side, rb)
		end
	end
	if not e then
		local old = d.exact[id]
		if old and (old.ex - p.x) ^ 2 + (old.ey - p.y) ^ 2 <= eps * eps
			and (old.standing or false) == (p.standing or false) then e = old end
	end
	keep[id] = e
end

function debris.recordExact(d, g, res, side)
	local eps = debris.tune.matchEps
	local keep = {}
	for _, k in ipairs(g:onPitch()) do record(d, keep, k.id, k.pose, res, side, eps) end
	if g.king and g.king.pose then record(d, keep, "king", g.king.pose, res, side, eps) end
	d.exact = keep
end

-- Put the exact poses onto outcome.pieces (view frame of `side`): each piece
-- whose engine pose is the recorded one (lying or standing as recorded) gets
-- the body's pose and z.
function debris.applyExact(d, pieces, side)
	local eps = debris.tune.matchEps
	for _, p in ipairs(pieces) do
		local e = d.exact[p.id]
		if e and p.pose and (e.standing and true or false) == not p.toppled
			and (e.ex - p.pose.x) ^ 2 + (e.ey - p.pose.y) ^ 2 <= eps * eps then
			p.x, p.y = frame.point(side, e.x, e.y)
			p.qw, p.qx, p.qy, p.qz = frame.quat(side, e.qw, e.qx, e.qy, e.qz)
			p.z = e.z
		end
	end
end

tw.debris = debris
