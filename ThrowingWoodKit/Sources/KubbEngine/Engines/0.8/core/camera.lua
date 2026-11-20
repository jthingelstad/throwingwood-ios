-- Pinhole cameras in the world frame of DESIGN.md section 2 (meters; x across,
-- y downfield, z up) projecting onto the 400x240 screen.
-- Pure Lua: no playdate.*.
--
-- A camera is a plain table (see camera.new). It is filled in place by
-- camera.lookAt / camera.aim / camera.impact / camera.follow so the game can
-- keep one table per camera and make no garbage per frame. camera.project
-- returns plain numbers (sx, sy, depth), never a table.
--
-- Every number that sets the framing is in camera.tune.
import "core/tw"

local sqrt, sin, cos, max, min, abs = math.sqrt, math.sin, math.cos, math.max, math.min, math.abs

local camera = {}

camera.SCREEN_W = 400
camera.SCREEN_H = 240

camera.tune = {
	near = 0.05,           -- m; points closer than this along the view axis are not projected
	aim = {
		back = 3.0,          -- m behind the throwing line (DESIGN 3), measured along the aim
		height = 3.4,        -- m above the ground (DESIGN 3)
		lookDist = 7.5,      -- m from the thrower, along the aim, to the ground point at screen center x
		cy = 110,            -- screen row of that ground point (the principal point)
		minTargetPx = 12.5,  -- farthest live target (a standing 0.15 m kubb) at least this tall
		fMin = 880,          -- px; the long lens of DESIGN 3 (about 26 degrees wide) ...
		fMax = 1000,         -- ... to about 23 degrees wide
		stepBackRef = 11,    -- m from the camera to the far baseline with the player on the line;
		                     -- the lens limit grows by stepBack / this when the player steps back
		lookBeyond = 1.5,    -- m past the nearest live target the match camera looks (lookDistFor)
		lookMin = 3.0,       -- m; lookDistFor never looks nearer than this
		side = 0,            -- m the crane stands to the thrower's right, still looking at the
		                     -- same ground point. 0: first person, straight behind (Jamie,
		                     -- 2026-11-15: "return to the first person view"); the over-the-
		                     -- shoulder view is camera.shoulder, while B is held
		circleBeyond = 1.5,  -- m past the target circle the first-person camera looks
		                     -- (camera.lookDistAt), between lookMin and lookDist: the circle
		                     -- stays on screen wherever the d-pad puts it
		-- A target close in front of the thrower (an advantage line near the
		-- middle: Codex on #96) projects under the screen at the long lens:
		-- camera.fitNear lifts it above fitBottom, first by raising the
		-- principal row (as far as fitCyMin), then by widening the lens (never
		-- wider than fitFMin).
		fitBottom = 200,     -- px: the near edge of the circle stays above this row
		fitCyMin = 40,       -- px: the principal row may rise this far
		fitFMin = 360,       -- px: the widest lens the fit may use
	},
	-- The plan view (Jamie, 2026-11-15: "when we hold down B to adjust loft we
	-- should move the camera to that over the shoulder view to see the loft
	-- ... it moves position and zooms out"): while B is held the aim camera
	-- swings from first person to a crane over the thrower's right shoulder,
	-- standing back and up, turned to the middle of the target half, its
	-- lens as long as keeps the whole target half, the planned arc and the
	-- circle in the box below (camera.shoulder). Guesses, tuned by eye on the
	-- Simulator's frames.
	shoulder = {
		side = 2.6,          -- m to the thrower's right
		back = 3.6,          -- m behind the thrower, along the aim
		height = 3.4,        -- m above the ground (first person: 3.4)
		lookY = 6.0,         -- m out from the line to the ground point it turns to (x = 0): the
		                     -- target half's middle
		farX = 2.7,          -- m either side of the middle kept in view on the far baseline (the
		                     -- pitch is 2.5: its corners and the base kubbs)
		nearX = 1.0,         -- m either side kept on the centerline (the king and the middle;
		                     -- the whole width there would need a much wider lens)
		pad = 0.3,           -- m kept beyond the far baseline and short of the centerline
		cornerZ = 0.3,       -- m: the far corners are kept at this height too (a kubb's top)
		left = 12,           -- px: the box everything is fitted into (lens shift: the principal
		right = 388,         -- point moves so the box is filled evenly)
		top = 24,            -- under the rail
		bottom = 200,        -- the arc and the half's near corners may come this low (the minimap
		                     -- and the clock sit below the clear band's 156)
		fMin = 300,          -- px: never wider (a far base kubb about 4 px tall)
		fMax = 880,          -- px: never longer than the first-person lens
		time = 0.4,          -- s for the swing out or back (eased: camera.smooth)
		refit = 0.15,        -- s: the time constant a new fit (a tap of the arc) is eased in with
	},
	impact = {
		dist = 2.75,         -- m, horizontal, from the predicted landing point (DESIGN 3: 2.5 to 3)
		height = 0.9,        -- m (DESIGN 3: low, about 0.9)
		yaw = 0.42,          -- rad the camera sits off the line of flight, toward the pitch center
		lookUp = 0.08,       -- m above the landing point it looks at
		f = 700,             -- px; a standing kubb at the landing point is about 35 px tall
		cy = 104,            -- px row of the look point: high enough that a kubb there stands clear
		                     -- of the throw gauge and its label (stage 2: the hit happens there)
		-- the half circle round a hit (throw.tune.swingDeg) also opens the view
		-- by its end, so the pitch round the piece shows: guesses
		openHeight = 1.6,    -- m
		openDist = 3.4,      -- m
		openF = 420,         -- px
	},
	follow = {
		marginX = 30,        -- px kept between the baton's center and the screen edge while following
		marginTop = 60,
		marginBottom = 40,
		catchBy = 0.25,      -- fraction of the flight by which the baton must be in frame; before
		                     -- that it may still be below the frame (it rises into the aim view
		                     -- from the thrower's hand) and the camera does not chase it
		slack = 600,         -- px it may be below the frame at release, shrinking to 0 by catchBy
		midZoomOut = 0.45,   -- the lens widens by up to this fraction mid-flight, so the high
		                     -- baton and the pitch below it fit in one frame
	},
}

local KUBB_H <const> = 0.15

function camera.new()
	return {
		px = 0, py = 0, pz = 0,      -- position
		fx = 0, fy = 1, fz = 0,      -- forward (unit)
		rx = 1, ry = 0, rz = 0,      -- right (unit, horizontal)
		ux = 0, uy = 0, uz = 1,      -- up (unit)
		f = 900, cx = 200, cy = 120, -- focal length in px and principal point
		lx = 0, ly = 1, lz = 0,      -- the point looked at
	}
end

-- Point the camera at (tx, ty, tz) from (px, py, pz). The right vector stays
-- horizontal, so the horizon is level. Not for looking straight down.
function camera.lookAt(c, px, py, pz, tx, ty, tz)
	c.px, c.py, c.pz = px, py, pz
	c.lx, c.ly, c.lz = tx, ty, tz
	local fx, fy, fz = tx - px, ty - py, tz - pz
	local n = sqrt(fx * fx + fy * fy + fz * fz)
	fx, fy, fz = fx / n, fy / n, fz / n
	local rx, ry = fy, -fx
	local rn = sqrt(rx * rx + ry * ry)
	rx, ry = rx / rn, ry / rn
	c.fx, c.fy, c.fz = fx, fy, fz
	c.rx, c.ry, c.rz = rx, ry, 0
	-- up = right x forward
	c.ux = ry * fz
	c.uy = -rx * fz
	c.uz = rx * fy - ry * fx
	return c
end

-- Camera-space coordinates: right, up, depth (along the view axis).
function camera.toView(c, x, y, z)
	local dx, dy, dz = x - c.px, y - c.py, z - c.pz
	return dx * c.rx + dy * c.ry + dz * c.rz,
		dx * c.ux + dy * c.uy + dz * c.uz,
		dx * c.fx + dy * c.fy + dz * c.fz
end

-- Screen position of a world point: sx, sy, depth. Returns nil when the
-- point is behind the near plane.
function camera.project(c, x, y, z)
	local dx, dy, dz = x - c.px, y - c.py, z - c.pz
	local d = dx * c.fx + dy * c.fy + dz * c.fz
	if d < camera.tune.near then return nil end
	local s = c.f / d
	return c.cx + s * (dx * c.rx + dy * c.ry + dz * c.rz),
		c.cy - s * (dx * c.ux + dy * c.uy + dz * c.uz),
		d
end

-- Screen size in px of a standing upright segment of height h at (x, y):
-- the distance between its projected base and top.
function camera.uprightPx(c, x, y, h)
	local ax, ay = camera.project(c, x, y, 0)
	local bx, by = camera.project(c, x, y, h)
	if not ax or not bx then return 0 end
	return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- Unit aim direction for a swivel angle in radians (0 = straight downfield,
-- positive = to the right, toward +x).
function camera.aimDir(swivel)
	return sin(swivel), cos(swivel)
end

-- The aim camera (DESIGN 3): a crane behind the thrower standing at
-- (playerX, lineY), looking along the swivel. `targets` is an array of
-- {x=, y=} live targets (standing kubbs): the focal length is the smallest in
-- [fMin, fMax] that shows the farthest of them at least minTargetPx tall.
-- `stepBack` (m, optional) is how far behind the throwing line the player
-- stands: the lens limit grows in proportion, so stepping back does not
-- shrink the targets below minTargetPx.
-- `lookDist` (m, optional, default tune.aim.lookDist) moves the ground point
-- at screen center nearer the thrower (the match: field kubbs close by).
function camera.aim(c, playerX, lineY, swivel, targets, stepBack, lookDist)
	local t = camera.tune.aim
	local dx, dy = camera.aimDir(swivel)
	local ld = lookDist or t.lookDist
	local sd = t.side
	camera.lookAt(c,
		playerX - dx * t.back + dy * sd, lineY - dy * t.back - dx * sd, t.height,
		playerX + dx * ld, lineY + dy * ld, 0)
	c.cx, c.cy = camera.SCREEN_W / 2, t.cy
	c.f = 1
	local need = t.fMin
	if targets then
		for i = 1, #targets do
			local k = targets[i]
			local px = camera.uprightPx(c, k.x, k.y, KUBB_H)
			if px > 0 then need = max(need, t.minTargetPx / px) end
		end
	end
	local fMax = t.fMax * (1 + (stepBack or 0) / t.stepBackRef)
	c.f = min(fMax, max(t.fMin, need))
	return c
end

-- Keep the ground point (x, y) (the near edge of the target circle) above
-- tune.aim.fitBottom on camera c: raise the principal row, then widen the
-- lens, within fitCyMin and fitFMin. Nothing changes when it is already
-- above. Returns c.
function camera.fitNear(c, x, y)
	local t = camera.tune.aim
	local _, sy = camera.project(c, x, y, 0)
	if not sy or sy <= t.fitBottom then return c end
	local lift = sy - t.fitBottom
	local cy = c.cy - lift
	if cy < t.fitCyMin then cy = t.fitCyMin end
	sy = sy - (c.cy - cy)
	c.cy = cy
	if sy > t.fitBottom then
		-- the point sits (sy - cy) under the principal row; scale the lens so
		-- it sits (fitBottom - cy) under it
		local f = c.f * (t.fitBottom - cy) / (sy - cy)
		if f < t.fitFMin then f = t.fitFMin end
		c.f = f
	end
	return c
end

-- The look distance that frames the live targets (n of them, {x=, y=}) for a
-- thrower at (playerX, playerY): lookBeyond past the nearest, between lookMin
-- and the default lookDist. Base kubbs on the far baseline give the default.
function camera.lookDistFor(playerX, playerY, targets, n)
	local t = camera.tune.aim
	local best = nil
	for i = 1, n or #targets do
		local k = targets[i]
		local dx, dy = k.x - playerX, k.y - playerY
		local d = sqrt(dx * dx + dy * dy)
		if not best or d < best then best = d end
	end
	if not best then return t.lookDist end
	return max(t.lookMin, min(t.lookDist, best + t.lookBeyond))
end

-- The first-person look distance for a target circle at (x, y) and a thrower
-- at (playerX, playerY): circleBeyond past the circle, between lookMin and
-- lookDist (the far baseline gives the default framing).
function camera.lookDistAt(playerX, playerY, x, y)
	local t = camera.tune.aim
	local dx, dy = x - playerX, y - playerY
	return max(t.lookMin, min(t.lookDist, sqrt(dx * dx + dy * dy) + t.circleBeyond))
end

-- The plan view (tune.shoulder): a crane over the right shoulder of the
-- thrower at (playerX, playerY) facing `swivel`, turned to (0, lineY +
-- lookY), with the lens and principal point that fit the target half
-- (lineY + 4 to lineY + 8 padded, farX either side on the far baseline and
-- nearX on the centerline; the far corners also at cornerZ) and the n extra points xs, ys, zs (the planned arc, the circle)
-- into the box left..right, top..bottom: the longest lens that does, between
-- fMin and fMax, and the principal point that centres them in the box (a lens
-- shift: verticals stay vertical). The first `across` of the extra points
-- (default 0) are kept inside the sides only (the arc's first rise, near the
-- hand: it may come in from the lower edge). Points behind the camera are
-- left out. No tables.
function camera.shoulder(c, playerX, playerY, swivel, lineY, n, xs, ys, zs, across)
	local t = camera.tune.shoulder
	local dx, dy = camera.aimDir(swivel)
	camera.lookAt(c,
		playerX - dx * t.back + dy * t.side, playerY - dy * t.back - dx * t.side, t.height,
		0, lineY + t.lookY, 0)
	local near = camera.tune.near
	local umin, umax, vmin, vmax = math.huge, -math.huge, math.huge, -math.huge
	local px, py, pz = c.px, c.py, c.pz
	local rx, ry = c.rx, c.ry
	local ux, uy, uz = c.ux, c.uy, c.uz
	local fx, fy, fz = c.fx, c.fy, c.fz
	local y0, y1 = lineY + 4 - t.pad, lineY + 8 + t.pad
	local onlyTo = 6 + (across or 0)
	for i = 1, 6 + (n or 0) do
		local x, y, z
		if i <= 6 then
			-- the half: near left, near right (nearX), far left, far right
			-- (farX), then the far ones again at cornerZ
			local hx = (i <= 2) and t.nearX or t.farX
			x = (i % 2 == 1) and -hx or hx
			y = (i <= 2) and y0 or y1
			z = (i >= 5) and t.cornerZ or 0
		else
			x, y, z = xs[i - 6], ys[i - 6], zs and zs[i - 6] or 0
		end
		local ax, ay, az = x - px, y - py, z - pz
		local d = ax * fx + ay * fy + az * fz
		if d >= near then
			local u = (ax * rx + ay * ry) / d
			local v = (ax * ux + ay * uy + az * uz) / d
			if u < umin then umin = u end
			if u > umax then umax = u end
			if i <= 6 or i > onlyTo then
				if v < vmin then vmin = v end
				if v > vmax then vmax = v end
			end
		end
	end
	local f = t.fMax
	if umax > umin then
		local fw = (t.right - t.left) / (umax - umin)
		if fw < f then f = fw end
	end
	if vmax > vmin then
		local fh = (t.bottom - t.top) / (vmax - vmin)
		if fh < f then f = fh end
	end
	if f < t.fMin then f = t.fMin end
	c.f = f
	if umax >= umin then
		c.cx = (t.left + t.right) / 2 - f * (umin + umax) / 2
		c.cy = (t.top + t.bottom) / 2 + f * (vmin + vmax) / 2
	else
		c.cx, c.cy = camera.SCREEN_W / 2, camera.SCREEN_H / 2
	end
	return c
end

-- Camera c between cameras a (e = 0) and b (e = 1): position, the point
-- looked at and the principal point straight, the lens in log space (the
-- zoom feels even). e is already eased. c may not be a or b.
function camera.blend(c, a, b, e)
	if e <= 0 then e = 0 elseif e >= 1 then e = 1 end
	c.f = a.f * (b.f / a.f) ^ e
	c.cx = a.cx + (b.cx - a.cx) * e
	c.cy = a.cy + (b.cy - a.cy) * e
	return camera.lookAt(c,
		a.px + (b.px - a.px) * e, a.py + (b.py - a.py) * e, a.pz + (b.pz - a.pz) * e,
		a.lx + (b.lx - a.lx) * e, a.ly + (b.ly - a.ly) * e, a.lz + (b.lz - a.lz) * e)
end

-- The impact camera (DESIGN 3): low and close to the predicted landing point
-- (lx, ly), set back along the line of flight (dirX, dirY, unit horizontal)
-- and turned off it by tune.impact.yaw toward the pitch center. `side`
-- (1 or -1) fixes which way it turns; by default it is chosen from lx, so a
-- caller that moves the point during a throw passes the side it started with
-- (otherwise the camera jumps across when the point crosses x = 0).
-- `orbit` (radians, default 0) carries the camera further round the point
-- the same way: the half circle of the slow motion after a hit.
-- `open` (0 to 1, default 0) blends height, distance and lens toward the
-- tune's open view as the half circle goes round.
function camera.impact(c, lx, ly, dirX, dirY, side, orbit, open)
	local t = camera.tune.impact
	side = side or ((lx > 0) and 1 or -1)       -- swing the camera toward x = 0
	local a = (t.yaw + (orbit or 0)) * side
	local ca, sa = cos(a), sin(a)
	-- rotate the backwards direction (-dir) by a about z
	local bx, by = -dirX, -dirY
	bx, by = bx * ca - by * sa, bx * sa + by * ca
	local dist, height, f = t.dist, t.height, t.f
	if open and open > 0 then
		dist = dist + (t.openDist - dist) * open
		height = height + (t.openHeight - height) * open
		f = f * (t.openF / f) ^ open        -- in log space, like the follow's zoom
	end
	camera.lookAt(c, lx + bx * dist, ly + by * dist, height, lx, ly, t.lookUp)
	c.f, c.cx, c.cy = f, camera.SCREEN_W / 2, t.cy
	return c
end

local function smooth(s)
	if s <= 0 then return 0 elseif s >= 1 then return 1 end
	return s * s * (3 - 2 * s)
end
camera.smooth = smooth

-- Is the screen point inside the frame less the follow margins? `slack`
-- extends the bottom edge downward.
local function inFrame(sx, sy, slack)
	local m = camera.tune.follow
	return sx and sx >= m.marginX and sx <= camera.SCREEN_W - m.marginX
		and sy >= m.marginTop and sy <= camera.SCREEN_H - m.marginBottom + slack
end

-- The follow camera: blends from camera a (aim) to camera b (impact) as s
-- goes 0 -> 1 over the flight, eased. The baton at (bx, by, bz) is kept in
-- frame: if it would fall outside, the look point is pulled toward it just
-- far enough (found by bisection). Right after release the baton is still
-- below the aim view; it is allowed to rise into frame on its own until
-- tune.follow.catchBy of the flight, so the shot starts as the aim view.
function camera.follow(c, a, b, s, bx, by, bz)
	local e = smooth(s)
	local px = a.px + (b.px - a.px) * e
	local py = a.py + (b.py - a.py) * e
	local pz = a.pz + (b.pz - a.pz) * e
	local lx = a.lx + (b.lx - a.lx) * e
	local ly = a.ly + (b.ly - a.ly) * e
	local lz = a.lz + (b.lz - a.lz) * e
	-- focal length blends in log space so the zoom feels even
	local f = a.f * (b.f / a.f) ^ e
	f = f * (1 - camera.tune.follow.midZoomOut * math.sin(math.pi * e))
	c.f = f
	c.cx = a.cx + (b.cx - a.cx) * e   -- (the aim camera's is off centre while the plan view shows)
	c.cy = a.cy + (b.cy - a.cy) * e
	camera.lookAt(c, px, py, pz, lx, ly, lz)
	if not bx then return c end
	local m = camera.tune.follow
	local slack = m.slack * (1 - min(1, s / m.catchBy))
	local sx, sy = camera.project(c, bx, by, bz)
	if not inFrame(sx, sy, slack) then
		local lo, hi = 0, 1
		for _ = 1, 12 do
			local w = (lo + hi) / 2
			camera.lookAt(c, px, py, pz, lx + (bx - lx) * w, ly + (by - ly) * w, lz + (bz - lz) * w)
			sx, sy = camera.project(c, bx, by, bz)
			if inFrame(sx, sy, slack) then hi = w else lo = w end
		end
		camera.lookAt(c, px, py, pz, lx + (bx - lx) * hi, ly + (by - ly) * hi, lz + (bz - lz) * hi)
	end
	return c
end

-- Clip a ground-plane (z = 0) or general polygon against the near plane and
-- project it. `xs, ys, zs` hold n world points; the screen polygon is written
-- as x1, y1, x2, y2, ... into `out` (reused). Returns the number of screen
-- points (0 when it is all behind the camera).
local vx, vy, vd = {}, {}, {}
function camera.projectPoly(c, n, xs, ys, zs, out)
	local near = camera.tune.near
	for i = 1, n do
		vx[i], vy[i], vd[i] = camera.toView(c, xs[i], ys[i], zs and zs[i] or 0)
	end
	local m = 0
	local f, cx, cy = c.f, c.cx, c.cy
	for i = 1, n do
		local j = (i % n) + 1
		local ai, aj = vd[i] >= near, vd[j] >= near
		if ai then
			m = m + 1
			out[2 * m - 1] = cx + f * vx[i] / vd[i]
			out[2 * m] = cy - f * vy[i] / vd[i]
		end
		if ai ~= aj then
			local t = (near - vd[i]) / (vd[j] - vd[i])
			m = m + 1
			out[2 * m - 1] = cx + f * (vx[i] + (vx[j] - vx[i]) * t) / near
			out[2 * m] = cy - f * (vy[i] + (vy[j] - vy[i]) * t) / near
		end
	end
	return m
end

-- Clip a segment against the near plane and project it. Returns
-- x1, y1, x2, y2 on screen, or nil when it is all behind the camera.
function camera.projectSegment(c, x1, y1, z1, x2, y2, z2)
	local near = camera.tune.near
	local ax, ay, ad = camera.toView(c, x1, y1, z1)
	local bx, by, bd = camera.toView(c, x2, y2, z2)
	if ad < near and bd < near then return nil end
	if ad < near then
		local t = (near - ad) / (bd - ad)
		ax, ay, ad = ax + (bx - ax) * t, ay + (by - ay) * t, near
	elseif bd < near then
		local t = (near - bd) / (ad - bd)
		bx, by, bd = bx + (ax - bx) * t, by + (ay - by) * t, near
	end
	local f = c.f
	return c.cx + f * ax / ad, c.cy - f * ay / ad, c.cx + f * bx / bd, c.cy - f * by / bd
end

-- The minimap (DESIGN 3): a 45 x 72 px top-down pitch at 9 px per meter with
-- the far baseline (y = 8) at the top. ox, oy is its top-left pixel: the
-- bottom left of the screen, inside a 2 px frame at 4 162 49 76 (docs/design).
camera.minimap = { scale = 9, w = 45, h = 72, ox = 6, oy = 164 }

-- The HUD's clear area (docs/design "HUD" 7): under the rail (y rail) the
-- full width down to y top, then x x0 to x1 down to y bottom (the box
-- 58 16 188 222). What the camera has to keep in view belongs in it.
camera.clear = { rail = 14, top = 156, x0 = 58, x1 = 246, bottom = 238 }

function camera.toMinimap(x, y)
	local m = camera.minimap
	return m.ox + (x + 2.5) * m.scale, m.oy + (8 - y) * m.scale
end

tw.camera = camera
