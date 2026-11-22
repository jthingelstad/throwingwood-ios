-- The wide view (docs/CLIENT.md "The wide view"): the whole pitch from one
-- fixed place, for watching the computer (Jamie, 2026-11-16: "It'd be fun to
-- actually do more with the camera on the web version because we could zoom
-- out. We have a lot more screen. We could see a lot more."). Pure Lua 5.4.
--
-- Two framings, by the shape of the screen:
--   * side (a landscape window): a broadcast camera high on the sideline,
--     square to the middle of the pitch. The pitch's 8 m run across the
--     window, both baselines the same size, neither team nearer.
--   * end (a tall window, a phone upright): high behind Team A's baseline,
--     the pitch running up the screen.
-- Either way the camera stands still for the whole match: a lawn chair.
--
-- THE FRAME. The session gives everything in the thrower's view frame
-- (core/frame): Team B's pitch is turned 180 degrees. A fixed view of the
-- pitch must not turn with it, so in the wide view the session's output is
-- un-turned here, in Lua, into the world frame (Team A's view frame) before
-- JavaScript sees it: the pieces, the aim, the advantage line and the
-- bursts. JavaScript still never flips anything; it draws what it is given
-- through the camera it is given. (Turning only the camera into Team B's
-- frame would show the same pitch, but the renderer's light and the rough's
-- texture are fixed in the frame it draws, so the shadows would swing round
-- and the grass would jump at every change of ends.)
--
-- The camera is fitted to a box in the 400 x 240 frame's coordinates that
-- the client passes (the whole window as the frame sees it, less the HUD's
-- margins), so on any window the pitch fills it.
import "core/tw"
import "core/camera"
import "core/frame"
import "core/pitch"

local camera, frame = tw.camera, tw.frame
local max, min, huge = math.max, math.min, math.huge

local wide = {}

wide.tune = {
	tallBelow = 1.05, -- box width / height under this: the end view
	side = {
		out = 6.5,     -- m from the pitch's long axis to the camera, on the +x side
		height = 7.0,  -- m above the ground (higher fills more of a 16:10 window)
		lookZ = 0.2,   -- m: the height it looks at, over the middle of the pitch
	},
	["end"] = {
		back = 6.0,    -- m behind Team A's baseline
		height = 12.0, -- m above the ground
		lookY = 4.4,   -- m: the ground point it looks at
	},
	padX = 0.35,     -- m kept beyond the sidelines
	padY = 0.7,      -- m kept beyond the baselines (a thrower stands there)
	pieceZ = 0.32,   -- m: the baselines' corners and the king kept at this height
	flightZ = 1.95,  -- m: a baton's highest point (measured: a computer match tops 1.94 m)
	fMax = 4000,     -- px: never longer (a tiny box)
}

-- The points the view keeps in its box, in the world frame.
local function fitPoints()
	local t = wide.tune
	local L = tw.pitch.length
	local hx = tw.pitch.halfWidth
	local pts = {}
	local function add(x, y, z) pts[#pts + 1] = { x, y, z } end
	for _, x in ipairs { -hx - t.padX, hx + t.padX } do
		for _, y in ipairs { -t.padY, L + t.padY } do
			add(x, y, 0)
			add(x, y, t.pieceZ)
		end
		-- a baton at the top of its flight, over the middle of the pitch
		add(x * 0.6, L / 2, t.flightZ)
	end
	add(0, L / 2, t.pieceZ + 0.1) -- the king's crown
	return pts
end

-- Which framing a box takes: "side" or "end".
function wide.kind(box)
	local w, h = box.right - box.left, box.bottom - box.top
	if h <= 0 or w / h < wide.tune.tallBelow then return "end" end
	return "side"
end

-- The wide camera for a box { left, top, right, bottom } (frame px), in the
-- world frame: core/camera's table, its lens and principal point fitted so
-- every fit point falls inside the box, centred in it.
function wide.camera(box, kind)
	local t = wide.tune
	kind = kind or wide.kind(box)
	local L = tw.pitch.length
	local c = camera.new()
	if kind == "end" then
		local e = t["end"]
		camera.lookAt(c, 0, -e.back, e.height, 0, e.lookY, 0)
	else
		local s = t.side
		camera.lookAt(c, s.out, L / 2, s.height, 0, L / 2, s.lookZ)
	end
	local umin, umax, vmin, vmax = huge, -huge, huge, -huge
	for _, p in ipairs(fitPoints()) do
		local r, u, d = camera.toView(c, p[1], p[2], p[3])
		if d >= camera.tune.near then
			local a, b = r / d, u / d
			umin, umax = min(umin, a), max(umax, a)
			vmin, vmax = min(vmin, b), max(vmax, b)
		end
	end
	local bw, bh = max(1, box.right - box.left), max(1, box.bottom - box.top)
	local f = min(t.fMax, bw / (umax - umin), bh / (vmax - vmin))
	c.f = f
	c.cx = (box.left + box.right) / 2 - f * (umin + umax) / 2
	c.cy = (box.top + box.bottom) / 2 + f * (vmin + vmax) / 2
	c.kind = kind
	return c
end

-- How tall the smallest base kubb stands in this camera, in frame px: the
-- client keeps the thrower's view where this would be too small to read (a
-- phone held upright).
function wide.smallest(c)
	local L, hx = tw.pitch.length, tw.pitch.halfWidth
	local px = huge
	for _, x in ipairs { -hx, hx } do
		for _, y in ipairs { 0, L } do px = min(px, camera.uprightPx(c, x, y, 0.15)) end
	end
	return px
end

-- ---------- un-turning: the thrower's view frame to the world frame ----------
-- (frame.point and frame.quat are their own inverses: the half turn twice is
-- no turn.) Each works on a copy where the session may keep the table.

local function item(side, it)
	local o = {}
	for k, v in pairs(it) do o[k] = v end
	o.x, o.y = frame.point(side, it.x, it.y)
	if it.qw then o.qw, o.qx, o.qy, o.qz = frame.quat(side, it.qw, it.qx, it.qy, it.qz) end
	return o
end

local function items(side, list)
	if not list then return nil end
	local out = {}
	for i, it in ipairs(list) do out[i] = item(side, it) end
	return out
end
wide.items = items

local function point(side, p)
	if not p then return nil end
	local o = {}
	for k, v in pairs(p) do o[k] = v end
	if p.x and p.y then o.x, o.y = frame.point(side, p.x, p.y) end
	return o
end

-- The aim (Session:aimView): the circle, the thrower, the arc, the lines.
-- The thrower's swivel and the wind keep their frame: the wide view draws
-- neither as an arrow of its own.
local function aim(side, a)
	if not a or side ~= "B" then return a end
	local o = {}
	for k, v in pairs(a) do o[k] = v end
	o.marker = point(side, a.marker)
	o.thrower = point(side, a.thrower)
	if o.thrower then o.thrower.facing = -1 end -- the arrow down the pitch points to -y here
	if a.arc then
		o.arc = {}
		for i, p in ipairs(a.arc) do o.arc[i] = point(side, p) end
	end
	for _, k in ipairs { "lineY", "forwardY", "advY", "kidY" } do
		if a[k] then o[k] = frame.y(side, a[k]) end
	end
	return o
end
wide.aim = aim

-- A recording's bursts' anchors (what the client draws from a recording), and since 0.7.2
-- its facts in world terms too: the result's landing and rest spots (landX, landY, restX,
-- restY), the landing, and the timeline's first contact and first hit (and since 0.14
-- its ground impacts).
local function recording(side, rec)
	if not rec or side ~= "B" or not rec.timeline then return rec end
	local o = {}
	for k, v in pairs(rec) do o[k] = v end
	if rec.result then
		local r = {}
		for k, v in pairs(rec.result) do r[k] = v end
		if r.landX and r.landY then r.landX, r.landY = frame.point(side, r.landX, r.landY) end
		if r.restX and r.restY then r.restX, r.restY = frame.point(side, r.restX, r.restY) end
		o.result = r
	end
	o.landing = point(side, rec.landing)
	local tl = {}
	for k, v in pairs(rec.timeline) do tl[k] = v end
	tl.firstContact = point(side, rec.timeline.firstContact)
	tl.firstHit = point(side, rec.timeline.firstHit)
	-- the ground impacts (setImpacts, since 0.14)
	if rec.timeline.impacts then
		tl.impacts = {}
		for i, e in ipairs(rec.timeline.impacts) do tl.impacts[i] = point(side, e) end
	end
	if rec.timeline.bursts then
		tl.bursts = {}
		for i, b in ipairs(rec.timeline.bursts) do
			local nb = {}
			for k, v in pairs(b) do nb[k] = v end
			nb.anchor = point(side, b.anchor)
			-- a double hit's second burst (session/throw entry) has its own anchor
			if b.second then
				local ns = {}
				for k, v in pairs(b.second) do ns[k] = v end
				ns.anchor = point(side, b.second.anchor)
				nb.second = ns
			end
			tl.bursts[i] = nb
		end
	end
	o.timeline = tl
	return o
end
wide.recording = recording

-- The minimap's pieces and lines.
local function minimap(side, m)
	if not m or side ~= "B" then return m end
	local o = {}
	for k, v in pairs(m) do o[k] = v end
	o.pieces = items(side, m.pieces)
	if m.aim then
		local x0, y0 = frame.point(side, m.aim.x0, m.aim.y0)
		local x1, y1 = frame.point(side, m.aim.x1, m.aim.y1)
		o.aim = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
	end
	if m.advY then o.advY = frame.y(side, m.advY) end
	if m.lineY then o.lineY = frame.y(side, m.lineY) end
	if m.kidY then o.kidY = frame.y(side, m.kidY) end -- the Kid line (0.15.1: it was left unturned)
	return o
end

-- A setup whose settled list is turned into the world frame (a copy; the session keeps
-- its own).
local function settled(setup)
	local o = {}
	for k, v in pairs(setup) do o[k] = v end
	local st = {}
	for k, v in pairs(setup.settled) do st[k] = v end
	st.list = {}
	for i, e in ipairs(setup.settled.list) do
		local n = {}
		for k, v in pairs(e) do n[k] = v end
		for _, f in ipairs { "lying", "standing", "pose", "king" } do
			if e[f] then n[f] = frame.pose(e.side, e[f]) end
		end
		-- (0.17.0) the surroundings too
		if e.others then
			n.others = {}
			for j, x in ipairs(e.others) do n.others[j] = { id = x.id, pose = frame.pose(e.side, x.pose) } end
		end
		n.frame = "world"
		st.list[i] = n
	end
	o.settled = st
	return o
end

-- A call's result in the wide view. side: the frame the session's pitch is
-- in (Session.frameSide); recSide: the frame of its last recording. Replaces
-- every camera with the wide one and un-turns what is in a thrower's frame.
-- `r` is a fresh table from the session (its items and aim are made per
-- call); only its own fields are replaced.
function wide.out(r, cam, side, recSide)
	if type(r) ~= "table" then return r end
	if r.camera then r.camera = cam end
	if side == "B" then
		if r.items then r.items = items(side, r.items) end
		if r.aim then r.aim = aim(side, r.aim) end
		if r.minimap then r.minimap = minimap(side, r.minimap) end
	end
	if r.recording then r.recording = recording(recSide, r.recording) end
	-- a need's setup.settled (0.16.0): each kubb's poses are in its raiser's view frame;
	-- here every one goes to the world frame (Team A's), whoever raised
	if r.setup and r.setup.settled and r.setup.settled.list then r.setup = settled(r.setup) end
	if type(r.need) == "table" and r.need.setup and r.need.setup.settled and r.need.setup.settled.list then
		local n = {}
		for k, v in pairs(r.need) do n[k] = v end
		n.setup = settled(r.need.setup)
		r.need = n
	end
	r.wide = cam.kind
	return r
end

tw.web = tw.web or {}
tw.web.wide = wide
