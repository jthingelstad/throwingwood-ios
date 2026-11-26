-- Contact generation (narrow phase). Pure Lua: no playdate.*.
--
-- Contacts go into one reused buffer of parallel arrays (no tables per
-- contact). A contact is between body A and body B (B = false for the
-- ground), at world point P on A, with unit normal N pointing from B toward
-- A, and separation `sep` (negative = overlapping). Contacts are made a little
-- before touching (speculative, within `margin`), so fast pieces do not pass
-- through each other between steps.
--
-- Shapes (DESIGN 5):
--   box vs ground       the eight corners
--   capsule vs ground   the two end spheres (on a plane the lowest points of
--                       a capsule are always at its end spheres, so a baton
--                       lying flat rests on both and rolls about its axis)
--   capsule vs box      the closest points of the segment and the box, plus
--                       each end sphere, so a baton lying across a kubb rests
--   box vs box          corners of each box inside (or near) the other, plus
--                       edge on edge: the closest points of two crossing
--                       edges, and the points where crossed faces' edges
--                       cross (collide.boxBox)
--   capsule vs capsule  closest points of the two segments
import "core/tw"

local sqrt, abs = math.sqrt, math.abs

local collide = {}

-- The contact buffer.
local C = {
	n = 0,
	A = {}, B = {}, slot = {},
	px = {}, py = {}, pz = {},
	nx = {}, ny = {}, nz = {},
	sep = {},
}
collide.C = C

function collide.reset()
	C.n = 0
end

local cA, cB, cSlot = C.A, C.B, C.slot
local cPx, cPy, cPz, cNx, cNy, cNz, cSep = C.px, C.py, C.pz, C.nx, C.ny, C.nz, C.sep

local function add(a, b, px, py, pz, nx, ny, nz, sep, slot)
	local i = C.n + 1
	C.n = i
	cA[i], cB[i], cSlot[i] = a, b, slot
	cPx[i], cPy[i], cPz[i] = px, py, pz
	cNx[i], cNy[i], cNz[i] = nx, ny, nz
	cSep[i] = sep
end
collide.add = add

local SX = { -1, 1, 1, -1, -1, 1, 1, -1 }
local SY = { -1, -1, 1, 1, -1, -1, 1, 1 }
local SZ = { -1, -1, -1, -1, 1, 1, 1, 1 }
collide.SX, collide.SY, collide.SZ = SX, SY, SZ

-- The functions below run for every pair and corner of every step, so they
-- write out add, pointBox, the extents and math.abs instead of calling them
-- (on the device a Lua call costs about 9 us, a C call about 4 us; see
-- docs/notes/physics.md, "Physics"). The arithmetic is the same, term for term.

-- Box b against the ground plane z = 0: each corner below `margin`.
function collide.groundBox(b, margin)
	local hx, hy, hz = b.hx, b.hy, b.hz
	local r31, r32, r33 = b.r31, b.r32, b.r33
	local z0 = b.z
	local x0, y0 = b.x, b.y
	local az, bz, cz = r31 * hx, r32 * hy, r33 * hz
	-- quick reject: the lowest corner is above the margin
	local aaz, abz, acz = az, bz, cz
	if aaz < 0 then aaz = -aaz end
	if abz < 0 then abz = -abz end
	if acz < 0 then acz = -acz end
	if z0 - (aaz + abz + acz) >= margin then return end
	local ax, ay = b.r11 * hx, b.r21 * hx
	local bx, by = b.r12 * hy, b.r22 * hy
	local cx, cy = b.r13 * hz, b.r23 * hz
	local i = C.n
	for k = 1, 8 do
		local sx, sy, sz = SX[k], SY[k], SZ[k]
		local pz = z0 + sx * az + sy * bz + sz * cz
		if pz < margin then
			i = i + 1
			cA[i], cB[i], cSlot[i] = b, false, k
			cPx[i], cPy[i], cPz[i] = x0 + sx * ax + sy * bx + sz * cx, y0 + sx * ay + sy * by + sz * cy, pz
			cNx[i], cNy[i], cNz[i] = 0, 0, 1
			cSep[i] = pz
		end
	end
	C.n = i
end

-- Capsule b against the ground: its two end spheres.
function collide.groundCapsule(b, margin)
	local hl, r = b.hl, b.r
	local ax, ay, az = b.r13 * hl, b.r23 * hl, b.r33 * hl
	local z1, z2 = b.z - az - r, b.z + az - r
	if z1 < margin then add(b, false, b.x - ax, b.y - ay, z1, 0, 0, 1, z1, 1) end
	if z2 < margin then add(b, false, b.x + ax, b.y + ay, z2, 0, 0, 1, z2, 2) end
end

-- Closest point of box B to the world point p. Returns the distance from
-- the box surface (negative inside: minus the depth to the nearest face),
-- the world unit normal pointing out of the box toward p, and the box point.
-- (Written out again in cornersInto and sphereBox.)
local function pointBox(B, px, py, pz)
	local dx, dy, dz = px - B.x, py - B.y, pz - B.z
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 =
		B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
	local lx = r11 * dx + r21 * dy + r31 * dz
	local ly = r12 * dx + r22 * dy + r32 * dz
	local lz = r13 * dx + r23 * dy + r33 * dz
	local hx, hy, hz = B.hx, B.hy, B.hz
	local qx = lx > hx and hx or (lx < -hx and -hx or lx)
	local qy = ly > hy and hy or (ly < -hy and -hy or ly)
	local qz = lz > hz and hz or (lz < -hz and -hz or lz)
	local ex, ey, ez = lx - qx, ly - qy, lz - qz
	local d2 = ex * ex + ey * ey + ez * ez
	local nx, ny, nz, dist
	if d2 > 1e-14 then
		dist = sqrt(d2)
		nx, ny, nz = ex / dist, ey / dist, ez / dist
	else
		-- inside: the face of least penetration
		local px_, py_, pz_ = hx - abs(lx), hy - abs(ly), hz - abs(lz)
		if px_ <= py_ and px_ <= pz_ then
			nx, ny, nz, dist = (lx >= 0) and 1 or -1, 0, 0, -px_
			qx = nx * hx
		elseif py_ <= pz_ then
			nx, ny, nz, dist = 0, (ly >= 0) and 1 or -1, 0, -py_
			qy = ny * hy
		else
			nx, ny, nz, dist = 0, 0, (lz >= 0) and 1 or -1, -pz_
			qz = nz * hz
		end
	end
	return dist,
		r11 * nx + r12 * ny + r13 * nz, r21 * nx + r22 * ny + r23 * nz, r31 * nx + r32 * ny + r33 * nz,
		B.x + r11 * qx + r12 * qy + r13 * qz, B.y + r21 * qx + r22 * qy + r23 * qz, B.z + r31 * qx + r32 * qy + r33 * qz
end
collide.pointBox = pointBox

-- Half extent of box b along the unit world axis (lx, ly, lz).
local function extent(b, lx, ly, lz)
	return b.hx * abs(b.r11 * lx + b.r21 * ly + b.r31 * lz)
		+ b.hy * abs(b.r12 * lx + b.r22 * ly + b.r32 * lz)
		+ b.hz * abs(b.r13 * lx + b.r23 * ly + b.r33 * lz)
end
collide.extent = extent

-- The pair's reference normal: of the six face axes of A and B, the one
-- along which they overlap least (separating-axis test), pointing from B
-- toward A. Corners that end up inside the other box use it, rather than
-- the nearest face of that box alone: identical kubbs side by side have
-- corners lying exactly on each other's side planes, and the nearest-face
-- rule then pushes sideways.
local refX, refY, refZ, refK
local REF_COS = math.cos(math.rad(25)) -- a corner's own normal further off than this uses the reference
-- Returns the least overlap (negative = the gap along that axis).
local function referenceAxis(A, B)
	local dx, dy, dz = A.x - B.x, A.y - B.y, A.z - B.z
	local a11, a12, a13, a21, a22, a23, a31, a32, a33 =
		A.r11, A.r12, A.r13, A.r21, A.r22, A.r23, A.r31, A.r32, A.r33
	local b11, b12, b13, b21, b22, b23, b31, b32, b33 =
		B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
	local ahx, ahy, ahz, bhx, bhy, bhz = A.hx, A.hy, A.hz, B.hx, B.hy, B.hz
	local best = math.huge
	for k = 1, 6 do
		local lx, ly, lz
		if k == 1 then lx, ly, lz = a11, a21, a31
		elseif k == 2 then lx, ly, lz = a12, a22, a32
		elseif k == 3 then lx, ly, lz = a13, a23, a33
		elseif k == 4 then lx, ly, lz = b11, b21, b31
		elseif k == 5 then lx, ly, lz = b12, b22, b32
		else lx, ly, lz = b13, b23, b33 end
		local d = dx * lx + dy * ly + dz * lz
		local e1 = a11 * lx + a21 * ly + a31 * lz
		local e2 = a12 * lx + a22 * ly + a32 * lz
		local e3 = a13 * lx + a23 * ly + a33 * lz
		if e1 < 0 then e1 = -e1 end
		if e2 < 0 then e2 = -e2 end
		if e3 < 0 then e3 = -e3 end
		local f1 = b11 * lx + b21 * ly + b31 * lz
		local f2 = b12 * lx + b22 * ly + b32 * lz
		local f3 = b13 * lx + b23 * ly + b33 * lz
		if f1 < 0 then f1 = -f1 end
		if f2 < 0 then f2 = -f2 end
		if f3 < 0 then f3 = -f3 end
		local ad = d
		if ad < 0 then ad = -ad end
		local o = (ahx * e1 + ahy * e2 + ahz * e3) + (bhx * f1 + bhy * f2 + bhz * f3) - ad
		if o < best then
			best = o
			if d < 0 then lx, ly, lz = -lx, -ly, -lz end
			refX, refY, refZ, refK = lx, ly, lz, k
		end
	end
	return best
end

-- Corners of box A against box B (contacts on A, normals out of B).
-- (sx, sy, sz) is the reference normal from B toward A.
local function cornersInto(A, B, margin, sx_, sy_, sz_)
	local hx, hy, hz = A.hx, A.hy, A.hz
	local ax, ay, az = A.r11 * hx, A.r21 * hx, A.r31 * hx
	local bx, by, bz = A.r12 * hy, A.r22 * hy, A.r32 * hy
	local cx, cy, cz = A.r13 * hz, A.r23 * hz, A.r33 * hz
	local Ax, Ay, Az = A.x, A.y, A.z
	local Bx, By, Bz = B.x, B.y, B.z
	-- skip corners clearly outside B's bounding sphere plus margin
	local reach = B.radius + margin
	local reach2 = reach * reach
	local r11, r12, r13, r21, r22, r23, r31, r32, r33
	local Bhx, Bhy, Bhz
	local plane
	local i = C.n
	for k = 1, 8 do
		local sx, sy, sz = SX[k], SY[k], SZ[k]
		local px = Ax + sx * ax + sy * bx + sz * cx
		local py = Ay + sx * ay + sy * by + sz * cy
		local pz = Az + sx * az + sy * bz + sz * cz
		local ddx, ddy, ddz = px - Bx, py - By, pz - Bz
		if ddx * ddx + ddy * ddy + ddz * ddz < reach2 then
			if not r11 then
				r11, r12, r13, r21, r22, r23, r31, r32, r33 =
					B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
				Bhx, Bhy, Bhz = B.hx, B.hy, B.hz
			end
			-- pointBox(B, p), written out
			local lx = r11 * ddx + r21 * ddy + r31 * ddz
			local ly = r12 * ddx + r22 * ddy + r32 * ddz
			local lz = r13 * ddx + r23 * ddy + r33 * ddz
			local qx = lx > Bhx and Bhx or (lx < -Bhx and -Bhx or lx)
			local qy = ly > Bhy and Bhy or (ly < -Bhy and -Bhy or ly)
			local qz = lz > Bhz and Bhz or (lz < -Bhz and -Bhz or lz)
			local ex, ey, ez = lx - qx, ly - qy, lz - qz
			local d2 = ex * ex + ey * ey + ez * ez
			local lnx, lny, lnz, d
			if d2 > 1e-14 then
				d = sqrt(d2)
				lnx, lny, lnz = ex / d, ey / d, ez / d
			else
				-- inside: the face of least penetration
				local alx, aly, alz = lx, ly, lz
				if alx < 0 then alx = -alx end
				if aly < 0 then aly = -aly end
				if alz < 0 then alz = -alz end
				local px_, py_, pz_ = Bhx - alx, Bhy - aly, Bhz - alz
				if px_ <= py_ and px_ <= pz_ then
					lnx, lny, lnz, d = (lx >= 0) and 1 or -1, 0, 0, -px_
				elseif py_ <= pz_ then
					lnx, lny, lnz, d = 0, (ly >= 0) and 1 or -1, 0, -py_
				else
					lnx, lny, lnz, d = 0, 0, (lz >= 0) and 1 or -1, -pz_
				end
			end
			-- (a corner at margin or further adds nothing; a far corner can
			-- still lie on the reference plane, the back foot of a box leaning
			-- on another, but its distance is then margin too)
			if d < margin then
				local nx = r11 * lnx + r12 * lny + r13 * lnz
				local ny = r21 * lnx + r22 * lny + r23 * lnz
				local nz = r31 * lnx + r32 * lny + r33 * lnz
				if d <= 0 or nx * sx_ + ny * sy_ + nz * sz_ < REF_COS then
					-- inside, or near an edge of B: use the reference normal and
					-- the distance to B's face plane along it (never more than
					-- the true distance, so still a close contact). A corner
					-- outside B (d > 0) can lie behind that plane, past the face's
					-- edge, beside B: it is at most touching, never inside (1.0;
					-- a kubb propped on a lying kubb crept until such a corner read
					-- 3.1 mm deep while it was 2.4 mm clear, and the push for it
					-- kicked the pair awake every few tenths of a second, the Gym
					-- gate's unsettled throw at 15:101)
					if not plane then
						local e1 = r11 * sx_ + r21 * sy_ + r31 * sz_
						local e2 = r12 * sx_ + r22 * sy_ + r32 * sz_
						local e3 = r13 * sx_ + r23 * sy_ + r33 * sz_
						if e1 < 0 then e1 = -e1 end
						if e2 < 0 then e2 = -e2 end
						if e3 < 0 then e3 = -e3 end
						plane = Bx * sx_ + By * sy_ + Bz * sz_ + (Bhx * e1 + Bhy * e2 + Bhz * e3)
					end
					local dp = px * sx_ + py * sy_ + pz * sz_ - plane
					if d <= 0 and dp > 0 then dp = 0 end
					if d > 0 and dp < 0 then dp = 0 end
					d = dp
					nx, ny, nz = sx_, sy_, sz_
				end
				if d < margin then
					i = i + 1
					cA[i], cB[i], cSlot[i] = A, B, 0
					cPx[i], cPy[i], cPz[i] = px, py, pz
					cNx[i], cNy[i], cNz[i] = nx, ny, nz
					cSep[i] = d
				end
			end
		end
	end
	C.n = i
end

-- Edge on edge (2026-11-16, the physics audit): two boxes can touch where
-- an edge of each crosses the other's, with no corner of either inside the
-- other. Two kinds, both met by the standard separating-axis test (Ericson,
-- Real-Time Collision Detection 4.4 and 5.1.9; ODE's dBoxBox):
--   - the nine edge axes (an edge direction of A crossed with one of B). If
--     one of them parts the boxes by `margin` there is nothing to add; if the
--     boxes overlap least along one (by EDGE_TOL less than along any face
--     axis), they meet edge on edge: one contact at the closest points of
--     the two edges that face each other, normal along that axis
--   - face on face with the faces crossed (a kubb lying across a lying kubb):
--     the incident face (of the other box, the one turned most against the
--     reference face) is clipped to the reference face, and each point where
--     one of its edges crosses a side of the reference face is a contact
-- Corners stay as they were, so a crossing within CLIP_TOL of a corner is
-- left to that corner. Boxes standing square to each other (every axis of A
-- within ALIGN of one of B's, a row of kubbs) have no edge axis that is not
-- also a face axis, so the nine are skipped for them.
local EDGE_TOL = 0.0005 -- m: an edge axis must overlap this much less than the best face axis
local CLIP_TOL = 0.001  -- m: crossings this close to a corner are the corner's
local ALIGN = 0.9995    -- cos of about 1.8 degrees
local ABX, ABY, ABZ = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }

-- The incident face of box I clipped to face `rk` (1..3, an axis of box R)
-- of box R, the reference normal (nx, ny, nz) pointing out of that face
-- toward I: contacts on I where its edges cross the face's sides.
local function clipFace(I, R, rk, nx, ny, nz, margin)
	-- R's frame: U, V across the face (half sides hu, hv), the face plane
	local ux, uy, uz, vx, vy, vz, hu, hv, hw
	if rk == 1 then
		ux, uy, uz, vx, vy, vz = R.r12, R.r22, R.r32, R.r13, R.r23, R.r33
		hu, hv, hw = R.hy, R.hz, R.hx
	elseif rk == 2 then
		ux, uy, uz, vx, vy, vz = R.r11, R.r21, R.r31, R.r13, R.r23, R.r33
		hu, hv, hw = R.hx, R.hz, R.hy
	else
		ux, uy, uz, vx, vy, vz = R.r11, R.r21, R.r31, R.r12, R.r22, R.r32
		hu, hv, hw = R.hx, R.hy, R.hz
	end
	-- I's face turned most against the normal: its centre and two half edges
	local i11, i12, i13, i21, i22, i23, i31, i32, i33 =
		I.r11, I.r12, I.r13, I.r21, I.r22, I.r23, I.r31, I.r32, I.r33
	local d1 = i11 * nx + i21 * ny + i31 * nz
	local d2 = i12 * nx + i22 * ny + i32 * nz
	local d3 = i13 * nx + i23 * ny + i33 * nz
	local a1, a2, a3 = d1, d2, d3
	if a1 < 0 then a1 = -a1 end
	if a2 < 0 then a2 = -a2 end
	if a3 < 0 then a3 = -a3 end
	local fx, fy, fz, ex, ey, ez, gx, gy, gz
	if a1 >= a2 and a1 >= a3 then
		local s = (d1 > 0) and -I.hx or I.hx
		fx, fy, fz = i11 * s, i21 * s, i31 * s
		ex, ey, ez = i12 * I.hy, i22 * I.hy, i32 * I.hy
		gx, gy, gz = i13 * I.hz, i23 * I.hz, i33 * I.hz
	elseif a2 >= a3 then
		local s = (d2 > 0) and -I.hy or I.hy
		fx, fy, fz = i12 * s, i22 * s, i32 * s
		ex, ey, ez = i11 * I.hx, i21 * I.hx, i31 * I.hx
		gx, gy, gz = i13 * I.hz, i23 * I.hz, i33 * I.hz
	else
		local s = (d3 > 0) and -I.hz or I.hz
		fx, fy, fz = i13 * s, i23 * s, i33 * s
		ex, ey, ez = i11 * I.hx, i21 * I.hx, i31 * I.hx
		gx, gy, gz = i12 * I.hy, i22 * I.hy, i32 * I.hy
	end
	-- in R's frame (w: height above the face plane)
	local cx, cy, cz = I.x + fx - R.x, I.y + fy - R.y, I.z + fz - R.z
	local cu, cv = cx * ux + cy * uy + cz * uz, cx * vx + cy * vy + cz * vz
	local cw = cx * nx + cy * ny + cz * nz - hw
	local eu, ev, ew = ex * ux + ey * uy + ez * uz, ex * vx + ey * vy + ez * vz, ex * nx + ey * ny + ez * nz
	local gu, gv, gw = gx * ux + gy * uy + gz * uz, gx * vx + gy * vy + gz * vz, gx * nx + gy * ny + gz * nz
	-- the corners in order round the face: c + e + g, c - e + g, c - e - g, c + e - g
	local aew, agw = ew, gw
	if aew < 0 then aew = -aew end
	if agw < 0 then agw = -agw end
	if cw - aew - agw >= margin then return end -- the whole face is clear
	local aeu, agu, aev, agv = eu, gu, ev, gv
	if aeu < 0 then aeu = -aeu end
	if agu < 0 then agu = -agu end
	if aev < 0 then aev = -aev end
	if agv < 0 then agv = -agv end
	local au, av = cu, cv
	if au < 0 then au = -au end
	if av < 0 then av = -av end
	-- every corner within the face's sides: nothing crosses them
	if au + aeu + agu <= hu + CLIP_TOL and av + aev + agv <= hv + CLIP_TOL then return end
	local i = C.n
	for k = 1, 4 do
		local pu, pv, pw, qu, qv, qw
		if k == 1 then
			pu, pv, pw = cu + eu + gu, cv + ev + gv, cw + ew + gw
			qu, qv, qw = cu - eu + gu, cv - ev + gv, cw - ew + gw
		elseif k == 2 then
			pu, pv, pw = cu - eu + gu, cv - ev + gv, cw - ew + gw
			qu, qv, qw = cu - eu - gu, cv - ev - gv, cw - ew - gw
		elseif k == 3 then
			pu, pv, pw = cu - eu - gu, cv - ev - gv, cw - ew - gw
			qu, qv, qw = cu + eu - gu, cv + ev - gv, cw + ew - gw
		else
			pu, pv, pw = cu + eu - gu, cv + ev - gv, cw + ew - gw
			qu, qv, qw = cu + eu + gu, cv + ev + gv, cw + ew + gw
		end
		if pw < margin or qw < margin then
			-- the four sides: u = +hu, -hu, v = +hv, -hv. A crossing counts when
			-- one end is inside that side and the other outside, each by more
			-- than CLIP_TOL, and the point lies within the other two sides
			for side = 1, 4 do
				local ps, qs, h
				if side == 1 then ps, qs, h = pu, qu, hu
				elseif side == 2 then ps, qs, h = -pu, -qu, hu
				elseif side == 3 then ps, qs, h = pv, qv, hv
				else ps, qs, h = -pv, -qv, hv end
				local pin, qin = h - ps, h - qs -- > 0 inside
				if (pin > CLIP_TOL and qin < -CLIP_TOL) or (pin < -CLIP_TOL and qin > CLIP_TOL) then
					local t = pin / (pin - qin)
					local w = pw + t * (qw - pw)
					if w < margin then
						local u, v = pu + t * (qu - pu), pv + t * (qv - pv)
						local o, ho
						if side <= 2 then o, ho = v, hv else o, ho = u, hu end
						if o < 0 then o = -o end
						if o < ho - CLIP_TOL then
							local hn = hw + w
							i = i + 1
							cA[i], cB[i], cSlot[i] = I, R, 0
							cPx[i] = R.x + u * ux + v * vx + hn * nx
							cPy[i] = R.y + u * uy + v * vy + hn * ny
							cPz[i] = R.z + u * uz + v * vz + hn * nz
							cNx[i], cNy[i], cNz[i] = nx, ny, nz
							cSep[i] = w
						end
					end
				end
			end
		end
	end
	C.n = i
end

function collide.boxBox(A, B, margin)
	-- separated along a face axis by margin or more: no corner of either box
	-- can come within margin of the other (every corner's distance is at
	-- least that gap), so there is nothing to add
	local best = referenceAxis(A, B)
	if best <= -margin then return end
	local nx, ny, nz, rk = refX, refY, refZ, refK
	-- the nine edge axes, unless the boxes stand square to each other
	local a11, a12, a13, a21, a22, a23, a31, a32, a33 =
		A.r11, A.r12, A.r13, A.r21, A.r22, A.r23, A.r31, A.r32, A.r33
	local b11, b12, b13, b21, b22, b23, b31, b32, b33 =
		B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
	local edge = false
	local exx, eyy, ezz, ei, ej
	local square = true
	for i = 1, 3 do
		local ax, ay, az
		if i == 1 then ax, ay, az = a11, a21, a31
		elseif i == 2 then ax, ay, az = a12, a22, a32
		else ax, ay, az = a13, a23, a33 end
		local c1 = ax * b11 + ay * b21 + az * b31
		local c2 = ax * b12 + ay * b22 + az * b32
		local c3 = ax * b13 + ay * b23 + az * b33
		if c1 < 0 then c1 = -c1 end
		if c2 < 0 then c2 = -c2 end
		if c3 < 0 then c3 = -c3 end
		if c1 < ALIGN and c2 < ALIGN and c3 < ALIGN then square = false break end
	end
	if not square then
		local dx, dy, dz = A.x - B.x, A.y - B.y, A.z - B.z
		local ahx, ahy, ahz, bhx, bhy, bhz = A.hx, A.hy, A.hz, B.hx, B.hy, B.hz
		local eBest = best - EDGE_TOL
		for i = 1, 3 do
			local ax, ay, az
			if i == 1 then ax, ay, az = a11, a21, a31
			elseif i == 2 then ax, ay, az = a12, a22, a32
			else ax, ay, az = a13, a23, a33 end
			for j = 1, 3 do
				local bx, by, bz
				if j == 1 then bx, by, bz = b11, b21, b31
				elseif j == 2 then bx, by, bz = b12, b22, b32
				else bx, by, bz = b13, b23, b33 end
				local lx, ly, lz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
				local l2 = lx * lx + ly * ly + lz * lz
				if l2 > 1e-6 then
					-- the overlap along the axis left unnormalized (it is the true
					-- overlap times its length, at most 1): one no smaller than the
					-- best so far and not negative can be passed over without the
					-- square root
					local e1 = a11 * lx + a21 * ly + a31 * lz
					local e2 = a12 * lx + a22 * ly + a32 * lz
					local e3 = a13 * lx + a23 * ly + a33 * lz
					if e1 < 0 then e1 = -e1 end
					if e2 < 0 then e2 = -e2 end
					if e3 < 0 then e3 = -e3 end
					local f1 = b11 * lx + b21 * ly + b31 * lz
					local f2 = b12 * lx + b22 * ly + b32 * lz
					local f3 = b13 * lx + b23 * ly + b33 * lz
					if f1 < 0 then f1 = -f1 end
					if f2 < 0 then f2 = -f2 end
					if f3 < 0 then f3 = -f3 end
					local d = dx * lx + dy * ly + dz * lz
					local ad = d
					if ad < 0 then ad = -ad end
					local o = (ahx * e1 + ahy * e2 + ahz * e3) + (bhx * f1 + bhy * f2 + bhz * f3) - ad
					if o < 0 or o < eBest then
						local il = 1 / sqrt(l2)
						o = o * il
						if o <= -margin then return end -- parted along this edge axis
						if o < eBest then
							eBest = o
							if d < 0 then il = -il end
							exx, eyy, ezz, ei, ej = lx * il, ly * il, lz * il, i, j
							edge = true
						end
					end
				end
			end
		end
	end
	cornersInto(A, B, margin, nx, ny, nz)
	cornersInto(B, A, margin, -nx, -ny, -nz)
	if edge then
		-- edge on edge: A's edge along its axis ei nearest B, B's along ej nearest A
		local lx, ly, lz = exx, eyy, ezz
		ABX[1], ABY[1], ABZ[1] = a11, a21, a31
		ABX[2], ABY[2], ABZ[2] = a12, a22, a32
		ABX[3], ABY[3], ABZ[3] = a13, a23, a33
		local pax, pay, paz = A.x, A.y, A.z
		local h1, h2, h3 = A.hx, A.hy, A.hz
		for k = 1, 3 do
			if k ~= ei then
				local ax, ay, az = ABX[k], ABY[k], ABZ[k]
				local h = (k == 1) and h1 or ((k == 2) and h2 or h3)
				if ax * lx + ay * ly + az * lz > 0 then h = -h end
				pax, pay, paz = pax + ax * h, pay + ay * h, paz + az * h
			end
		end
		local dax, day, daz = ABX[ei], ABY[ei], ABZ[ei]
		local ha = (ei == 1) and h1 or ((ei == 2) and h2 or h3)
		ABX[1], ABY[1], ABZ[1] = b11, b21, b31
		ABX[2], ABY[2], ABZ[2] = b12, b22, b32
		ABX[3], ABY[3], ABZ[3] = b13, b23, b33
		local pbx, pby, pbz = B.x, B.y, B.z
		h1, h2, h3 = B.hx, B.hy, B.hz
		for k = 1, 3 do
			if k ~= ej then
				local bx, by, bz = ABX[k], ABY[k], ABZ[k]
				local h = (k == 1) and h1 or ((k == 2) and h2 or h3)
				if bx * lx + by * ly + bz * lz < 0 then h = -h end
				pbx, pby, pbz = pbx + bx * h, pby + by * h, pbz + bz * h
			end
		end
		local dbx, dby, dbz = ABX[ej], ABY[ej], ABZ[ej]
		local hb = (ej == 1) and h1 or ((ej == 2) and h2 or h3)
		-- closest points of the two edges (Ericson 5.1.9; both unit directions)
		local rx, ry, rz = pax - pbx, pay - pby, paz - pbz
		local b = dax * dbx + day * dby + daz * dbz
		local c = dax * rx + day * ry + daz * rz
		local f = dbx * rx + dby * ry + dbz * rz
		local s = (b * f - c) / (1 - b * b)
		if s < -ha then s = -ha elseif s > ha then s = ha end
		local t = f + s * b
		if t < -hb then t = -hb elseif t > hb then t = hb end
		s = t * b - c
		if s < -ha then s = -ha elseif s > ha then s = ha end
		local px, py, pz = pax + dax * s, pay + day * s, paz + daz * s
		local sep = (px - pbx - dbx * t) * lx + (py - pby - dby * t) * ly + (pz - pbz - dbz * t) * lz
		if sep < margin then add(A, B, px, py, pz, lx, ly, lz, sep, 0) end
	elseif rk <= 3 then
		-- A's face is the reference: B's face meets it (normal from A toward B)
		clipFace(B, A, rk, -nx, -ny, -nz, margin)
	else
		clipFace(A, B, rk - 3, nx, ny, nz, margin)
	end
end

-- How a baton meets a kubb or the king: the box's edges and corners rounded
-- to this radius (m). The box is met as one of half sides less this, swept
-- by a ball of this radius, so a baton that catches an edge gets a normal
-- between the two faces instead of the top face's straight up (Tyler's play
-- test, 2026-11-15: a baton clipping a kubb's top edge pressed it down
-- instead of tipping it, and seemed to pass through it). Wood is never a
-- knife edge; boxes still meet the ground and each other square.
collide.tune = {
	batonRound = 0.01,
}
local ROUND = collide.tune
-- a stretch's end this close to the closest point (as a share of the
-- segment) adds no contact of its own
local CLIP_GAP <const> = 0.04
-- the closest point is kept between both ends only when this much deeper than either (m)
local CLIP_TOL_IN <const> = 0.0002

-- Sphere (center c, radius r) belonging to capsule A against box B
-- (pointBox written out), B's edges rounded by ROUND.batonRound (not for a
-- stake). The contact point is on the sphere, as before. The normal in B's
-- frame is left in SNX, SNY, SNZ (capsuleBox clips with it).
local SNX, SNY, SNZ = 0, 0, 0
local function sphereBox(A, B, cx, cy, cz, r, margin)
	local Bx, By, Bz = B.x, B.y, B.z
	local dx, dy, dz = cx - Bx, cy - By, cz - Bz
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 =
		B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
	local lx = r11 * dx + r21 * dy + r31 * dz
	local ly = r12 * dx + r22 * dy + r32 * dz
	local lz = r13 * dx + r23 * dy + r33 * dz
	-- (a stake is a capsule too: it meets boxes square, so a wall of drilled
	-- kubbs against it is as measured)
	local br = ROUND.batonRound
	if A.static then br = 0 end
	local hx, hy, hz = B.hx - br, B.hy - br, B.hz - br
	local qx = lx > hx and hx or (lx < -hx and -hx or lx)
	local qy = ly > hy and hy or (ly < -hy and -hy or ly)
	local qz = lz > hz and hz or (lz < -hz and -hz or lz)
	local ex, ey, ez = lx - qx, ly - qy, lz - qz
	local d2 = ex * ex + ey * ey + ez * ez
	local lnx, lny, lnz, d
	if d2 > 1e-14 then
		d = sqrt(d2)
		lnx, lny, lnz = ex / d, ey / d, ez / d
	else
		local alx, aly, alz = lx, ly, lz
		if alx < 0 then alx = -alx end
		if aly < 0 then aly = -aly end
		if alz < 0 then alz = -alz end
		local px_, py_, pz_ = hx - alx, hy - aly, hz - alz
		if px_ <= py_ and px_ <= pz_ then
			lnx, lny, lnz, d = (lx >= 0) and 1 or -1, 0, 0, -px_
		elseif py_ <= pz_ then
			lnx, lny, lnz, d = 0, (ly >= 0) and 1 or -1, 0, -py_
		else
			lnx, lny, lnz, d = 0, 0, (lz >= 0) and 1 or -1, -pz_
		end
	end
	local sep = d - r - br
	SNX, SNY, SNZ = lnx, lny, lnz
	if sep < margin then
		local nx = r11 * lnx + r12 * lny + r13 * lnz
		local ny = r21 * lnx + r22 * lny + r23 * lnz
		local nz = r31 * lnx + r32 * lny + r33 * lnz
		local i = C.n + 1
		C.n = i
		cA[i], cB[i], cSlot[i] = A, B, 0
		cPx[i], cPy[i], cPz[i] = cx - nx * r, cy - ny * r, cz - nz * r
		cNx[i], cNy[i], cNz[i] = nx, ny, nz
		cSep[i] = sep
		return true
	end
	return false
end

-- The contact just added (the last) and the one at mid are the same contact: keep the
-- deeper in mid's slot and drop the last (capsuleBox). No tables.
local function keepDeeper(mid)
	local j = C.n
	if cSep[j] < cSep[mid] then
		cA[mid], cB[mid], cSlot[mid] = cA[j], cB[j], cSlot[j]
		cPx[mid], cPy[mid], cPz[mid] = cPx[j], cPy[j], cPz[j]
		cNx[mid], cNy[mid], cNz[mid] = cNx[j], cNy[j], cNz[j]
		cSep[mid] = cSep[j]
	end
	C.n = j - 1
end

-- Capsule A against box B: the closest points of the segment and the box,
-- then the stretch of the segment that lies along the same feature of the
-- box (its face or edge) is clipped to that feature's extent, and each end
-- of the stretch is a contact too (Physics fuzz, 2026-11-16: with one point
-- a baton lying along a kubb's face or edge turned about it and sank in,
-- up to 66 mm). A feature is the box's axes the normal does not lean
-- along: a face extends along two of them, an edge along one, a corner
-- along none, so for a corner the stretch is the whole segment and its ends
-- are the baton's end spheres, as before.
function collide.capsuleBox(A, B, margin)
	local hl, r = A.hl, A.r
	local ax, ay, az = A.r13 * hl, A.r23 * hl, A.r33 * hl
	local x1, y1, z1 = A.x - ax, A.y - ay, A.z - az
	local x2, y2, z2 = A.x + ax, A.y + ay, A.z + az
	-- the segment in B's local frame
	local r11, r12, r13, r21, r22, r23, r31, r32, r33 =
		B.r11, B.r12, B.r13, B.r21, B.r22, B.r23, B.r31, B.r32, B.r33
	local dx, dy, dz = x1 - B.x, y1 - B.y, z1 - B.z
	local p1x = r11 * dx + r21 * dy + r31 * dz
	local p1y = r12 * dx + r22 * dy + r32 * dz
	local p1z = r13 * dx + r23 * dy + r33 * dz
	dx, dy, dz = x2 - B.x, y2 - B.y, z2 - B.z
	local ux = r11 * dx + r21 * dy + r31 * dz - p1x
	local uy = r12 * dx + r22 * dy + r32 * dz - p1y
	local uz = r13 * dx + r23 * dy + r33 * dz - p1z
	local uu = ux * ux + uy * uy + uz * uz
	-- the box as sphereBox meets it: its half sides less the rounding
	local br = ROUND.batonRound
	if A.static then br = 0 end
	local hx, hy, hz = B.hx - br, B.hy - br, B.hz - br
	-- closest points by alternating projection (segment <-> box), starting
	-- from the segment point nearest the box center
	local t = -(p1x * ux + p1y * uy + p1z * uz) / uu
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	for _ = 1, 6 do
		local sx, sy, sz = p1x + ux * t, p1y + uy * t, p1z + uz * t
		local qx = sx > hx and hx or (sx < -hx and -hx or sx)
		local qy = sy > hy and hy or (sy < -hy and -hy or sy)
		local qz = sz > hz and hz or (sz < -hz and -hz or sz)
		local nt = ((qx - p1x) * ux + (qy - p1y) * uy + (qz - p1z) * uz) / uu
		if nt < 0 then nt = 0 elseif nt > 1 then nt = 1 end
		local dt_ = nt - t
		if dt_ < 1e-4 and dt_ > -1e-4 then t = nt break end
		t = nt
	end
	-- the projection creeps when the baton lies nearly parallel to the box,
	-- so an end can be nearer than where it stopped: take the nearest of
	-- the three (Codex on PR #139: an end 2.3 mm into the king's rounded
	-- edge, the projected point 5.9 mm clear)
	local sx, sy, sz = p1x + ux * t, p1y + uy * t, p1z + uz * t
	local qx = sx > hx and hx or (sx < -hx and -hx or sx)
	local qy = sy > hy and hy or (sy < -hy and -hy or sy)
	local qz = sz > hz and hz or (sz < -hz and -hz or sz)
	local best = (sx - qx) * (sx - qx) + (sy - qy) * (sy - qy) + (sz - qz) * (sz - qz)
	if t > 0 then
		qx = p1x > hx and hx or (p1x < -hx and -hx or p1x)
		qy = p1y > hy and hy or (p1y < -hy and -hy or p1y)
		qz = p1z > hz and hz or (p1z < -hz and -hz or p1z)
		local d2 = (p1x - qx) * (p1x - qx) + (p1y - qy) * (p1y - qy) + (p1z - qz) * (p1z - qz)
		if d2 < best then best, t = d2, 0 end
	end
	if t < 1 then
		sx, sy, sz = p1x + ux, p1y + uy, p1z + uz
		qx = sx > hx and hx or (sx < -hx and -hx or sx)
		qy = sy > hy and hy or (sy < -hy and -hy or sy)
		qz = sz > hz and hz or (sz < -hz and -hz or sz)
		if (sx - qx) * (sx - qx) + (sy - qy) * (sy - qy) + (sz - qz) * (sz - qz) < best then t = 1 end
	end
	-- the closest pair as the projection found it. Its miss is not the pair's: the
	-- projection can stop on a point just over the margin while the stretch's end at
	-- the feature's edge is inside (1.0: a kubb lying on a long edge against a sleeping
	-- baton lost that contact one step in four, 0.56 mm in, and the step without it reset
	-- its sleep, the Gym gate's unsettled throw at 20:332), so the stretch's ends are
	-- tried either way
	local hitMid = sphereBox(A, B, x1 + 2 * ax * t, y1 + 2 * ay * t, z1 + 2 * az * t, r, margin)
	local mid = C.n
	-- the stretch [lo, hi] of the segment within the feature's extent
	local lo, hi = 0, 1
	if SNX == 0 then
		local e = hx
		if ux > 1e-12 or ux < -1e-12 then
			local ta, tb = (-e - p1x) / ux, (e - p1x) / ux
			if ta > tb then ta, tb = tb, ta end
			if ta > lo then lo = ta end
			if tb < hi then hi = tb end
		end
	end
	if SNY == 0 then
		local e = hy
		if uy > 1e-12 or uy < -1e-12 then
			local ta, tb = (-e - p1y) / uy, (e - p1y) / uy
			if ta > tb then ta, tb = tb, ta end
			if ta > lo then lo = ta end
			if tb < hi then hi = tb end
		end
	end
	if SNZ == 0 then
		local e = hz
		if uz > 1e-12 or uz < -1e-12 then
			local ta, tb = (-e - p1z) / uz, (e - p1z) / uz
			if ta > tb then ta, tb = tb, ta end
			if ta > lo then lo = ta end
			if tb < hi then hi = tb end
		end
	end
	-- each end of the stretch that is not the closest point already. An end within
	-- CLIP_GAP of it is the same contact, so the two are one: the deeper of them (1.0;
	-- the projection can stop short of the end, and a kubb on a long edge against a
	-- sleeping baton had its load-bearing end, 1.7 mm deeper than the projected point,
	-- dropped and kept by turns as the stretch's end crossed t - CLIP_GAP, the Gym gate's
	-- unsettled throw at 22:400 of seed 5). With no closest contact every end is tried
	local ends = 0
	if lo < t then
		if lo < t - CLIP_GAP or not hitMid then
			if sphereBox(A, B, x1 + 2 * ax * lo, y1 + 2 * ay * lo, z1 + 2 * az * lo, r, margin) then ends = ends + 1 end
		elseif sphereBox(A, B, x1 + 2 * ax * lo, y1 + 2 * ay * lo, z1 + 2 * az * lo, r, margin) then
			keepDeeper(mid)
		end
	end
	if hi > t then
		if hi > t + CLIP_GAP or not hitMid then
			if sphereBox(A, B, x1 + 2 * ax * hi, y1 + 2 * ay * hi, z1 + 2 * az * hi, r, margin) then ends = ends + 1 end
		elseif sphereBox(A, B, x1 + 2 * ax * hi, y1 + 2 * ay * hi, z1 + 2 * az * hi, r, margin) then
			keepDeeper(mid)
		end
	end
	-- (0.18) both ends met: the stretch is a line contact, and its two ends carry it.
	-- The closest point between them adds nothing a rigid line contact needs (it is
	-- a mix of the two ends) but the sequential solver met it first and held the blow
	-- there: a baton upright against a kubb's back face pushed it at 7.5 cm up
	-- (the closest point to the box's centre) and 14, its blow 10.9 cm up the face
	-- where the line from 4.5 to 14 cm puts it at 11.7 as MuJoCo does, and the kubb
	-- left with a tenth less speed and turn (docs/notes/physics.md "The baton's blow").
	-- Kept when it is deeper than both ends by more than CLIP_TOL_IN (a stretch over a
	-- rounded edge, not flat), so nothing sinks where the ends stand clear.
	if ends == 2 and hitMid then
		local j = C.n
		local s1, s2, sm = cSep[j - 1], cSep[j], cSep[mid]
		if s2 < s1 then s1 = s2 end
		if sm >= s1 - CLIP_TOL_IN then
			cA[mid], cB[mid], cSlot[mid] = cA[j], cB[j], cSlot[j]
			cPx[mid], cPy[mid], cPz[mid] = cPx[j], cPy[j], cPz[j]
			cNx[mid], cNy[mid], cNz[mid] = cNx[j], cNy[j], cNz[j]
			cSep[mid] = cSep[j]
			C.n = j - 1
		end
	end
	return hitMid or ends > 0
end

-- Capsule A against capsule B: closest points of two segments (Ericson,
-- Real-Time Collision Detection 5.1.9).
function collide.capsuleCapsule(A, B, margin)
	local ax, ay, az = A.r13 * A.hl, A.r23 * A.hl, A.r33 * A.hl
	local bx, by, bz = B.r13 * B.hl, B.r23 * B.hl, B.r33 * B.hl
	local p1x, p1y, p1z = A.x - ax, A.y - ay, A.z - az
	local p2x, p2y, p2z = B.x - bx, B.y - by, B.z - bz
	local d1x, d1y, d1z = 2 * ax, 2 * ay, 2 * az
	local d2x, d2y, d2z = 2 * bx, 2 * by, 2 * bz
	local rx, ry, rz = p1x - p2x, p1y - p2y, p1z - p2z
	local a = d1x * d1x + d1y * d1y + d1z * d1z
	local e = d2x * d2x + d2y * d2y + d2z * d2z
	local f = d2x * rx + d2y * ry + d2z * rz
	local c = d1x * rx + d1y * ry + d1z * rz
	local b = d1x * d2x + d1y * d2y + d1z * d2z
	local den = a * e - b * b
	local s = 0
	if den > 1e-12 then
		s = (b * f - c * e) / den
		if s < 0 then s = 0 elseif s > 1 then s = 1 end
	end
	local t = (b * s + f) / e
	if t < 0 then
		t = 0
		s = -c / a
		if s < 0 then s = 0 elseif s > 1 then s = 1 end
	elseif t > 1 then
		t = 1
		s = (b - c) / a
		if s < 0 then s = 0 elseif s > 1 then s = 1 end
	end
	local cax, cay, caz = p1x + d1x * s, p1y + d1y * s, p1z + d1z * s
	local cbx, cby, cbz = p2x + d2x * t, p2y + d2y * t, p2z + d2z * t
	local nx, ny, nz = cax - cbx, cay - cby, caz - cbz
	local d = sqrt(nx * nx + ny * ny + nz * nz)
	if d < 1e-9 then
		nx, ny, nz, d = 0, 0, 1, 0
	else
		nx, ny, nz = nx / d, ny / d, nz / d
	end
	local sep = d - A.r - B.r
	if sep < margin then
		add(A, B, cax - nx * A.r, cay - ny * A.r, caz - nz * A.r, nx, ny, nz, sep, 0)
		return true
	end
	return false
end

tw.collide = collide
