-- Which hit burst a baton throw shows, and when (docs/design/README.md "Hit
-- effects"). Pure: reads a core/world (its bodies' kind, toppleT and index)
-- and the time on screen.
--
-- A burst starts when the picture reaches the moment the first kubb or king
-- the throw knocks over was struck (Jamie: the burst and its knock at the
-- impact, not once the piece is down). World bodies carry touchT, the first
-- time something struck them, and toppleT, the time they went down; a piece
-- struck hard enough (falling, below) is taken as going down at its impact,
-- before the physics has run as far as its topple.
-- What kind: the king toppled within `window` s of the first topple, or by
-- now (whenever it fell), is "king" (the winning hit or the losing one); two
-- or more kubbs down within `window` s of the first is "double"; one is
-- "clean". So a king that falls well after a kubb turns the burst into the
-- king's when the picture reaches it (render/burst restarts it). A baton that touches a kubb and leaves it
-- standing, or a miss, gets nothing. Pieces already down when the throw
-- started have no toppleT and never count.
import "core/tw"

local burstpick = {}

burstpick.tune = {
	window = 0.4,     -- s after the first impact that a second one makes it a double
	-- A struck kubb is taken as falling at its impact when, just after the
	-- strike, it moves faster than this or turns faster than this: a 7 x 7 x 15
	-- cm kubb tips over with about 0.39 m/s or 4.1 rad/s about its edge, and a
	-- baton strike gives far more. On the device the physics cannot reach the
	-- topple before the picture reaches the impact (it was 260 ms of shown
	-- time late), so the burst cannot wait for it.
	fallV = 0.5,      -- m/s
	fallW = 5,        -- rad/s
	judgeFor = 0.5,   -- s after the strike the speeds are read (later, the topple or the rest decides)
	grazeFor = 1.0,   -- s: a topple this long after the first touch was a later blow (a slow tip
	                  -- from a hit takes well under a second), so the topple is the moment
}

-- The moment a body was struck: its first touch, unless it toppled more
-- than grazeFor after that (a graze, then a later blow that felled it: the
-- topple is the moment), or nothing recorded a touch.
local function hitTime(b)
	local t, tt = b.touchT, b.toppleT
	if not t or (tt and tt - t > burstpick.tune.grazeFor) then return tt end
	return t
end
burstpick.hitTime = hitTime

-- Is body b falling, as far as the physics knows at world time w.time?
-- Returns falling, sure: sure when it has toppled; a fast-moving struck
-- piece is falling but not sure (its burst may be taken back).
local function falling(b, w)
	if b.kind ~= "kubb" and b.kind ~= "king" then return false end
	if b.toppleT then return true, true end
	if b.toppled then return false end          -- down before this throw
	-- the king only once it has toppled: its burst inverts the screen and
	-- plays the game's end, so a king merely pushed must never get it (its
	-- burst may come up to the physics' lead late; Jamie can weigh that)
	if b.kind == "king" then return false end
	local ht = b.touchT
	if not ht or w.time - ht > burstpick.tune.judgeFor or not b.awake then return false end
	local t = burstpick.tune
	local v2 = b.vx * b.vx + b.vy * b.vy + b.vz * b.vz
	local w2 = b.wx * b.wx + b.wy * b.wy + b.wz * b.wz
	return (v2 >= t.fallV * t.fallV or w2 >= t.fallW * t.fallW), false
end
burstpick.falling = falling

-- The pieces first struck in world time (t0, t1]: kubbs, the king, batons
-- lying on the pitch and the stakes (Jamie, 2026-11-14: "if wood hits wood
-- play a sound"; the ground is not a body, so it never counts), not the
-- thrown piece itself (its own touch is the same blow): a knock each
-- (sound.lua). Fills out[1..count] and returns the count. A plain scan, no
-- tables.
function burstpick.touches(w, t0, t1, out)
	local n, bodies, proj = 0, w.bodies, w.projectile
	for i = 1, w.n do
		local b = bodies[i]
		local t = b.touchT
		if t and t > t0 and t <= t1 and b ~= proj then
			n = n + 1
			out[n] = b
		end
	end
	return n
end

-- Returns nil before the first falling piece's impact is on screen (or when
-- nothing is falling), else kind, first body, second body (the double's
-- second kubb) or nil, and whether the first is sure (toppled). No tables
-- are made.
function burstpick.pick(w, showTime)
	local bodies, n = w.bodies, w.n
	local first, ft, sure = nil, nil, false
	for i = 1, n do
		local b = bodies[i]
		local f, s = falling(b, w)
		if f then
			local ht = hitTime(b)
			if not ft or ht < ft then first, ft, sure = b, ht, s end
		end
	end
	if not first or ft > showTime then return nil end
	local limit = ft + burstpick.tune.window
	local second, king = nil, first.kind == "king" and first or nil
	for i = 1, n do
		local b = bodies[i]
		if b ~= first and falling(b, w) then
			local ht = hitTime(b)
			if b.kind == "king" then
				if ht <= limit or ht <= showTime then king = b end
			elseif ht <= limit and (not second or ht < hitTime(second)) then
				second = b
			end
		end
	end
	if king then
		-- the king's burst is anchored on the king: its own certainty, so a
		-- king struck hard that stays standing is taken back even after a
		-- kubb that surely fell
		if king ~= first then local _, ks = falling(king, w); sure = ks end
		return "king", king, nil, sure
	end
	if second then
		local _, s2 = falling(second, w)
		return "double", first, second, sure, s2
	end
	return "clean", first, nil, sure
end

-- Was a body taken as falling at its impact in the end left standing? (Its
-- burst is taken back.) True once it has gone to sleep, or the throw is
-- over, without toppling.
function burstpick.stoodUp(b, done)
	return not b.toppleT and (done or not b.awake)
end

tw.burstpick = burstpick
