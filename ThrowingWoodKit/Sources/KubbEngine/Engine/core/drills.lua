-- Practice drills (the Drills board): what each drill sets up, how a run is
-- scored and the records kept. Pure: no playdate.*.
--
-- A run is a fixed number of throws on its own pitch. drills.setup(d, run)
-- gives the next throw as a core/match-style setup (pieces in the view frame,
-- the line, the projectile, the targets) for scenes/throw's prepare;
-- drills.tally(d, run, res) takes what the throw did ({ toppled = {ids},
-- restCm = n, bodies = { [id] = rest pose } }) and says whether the run is
-- over; drills.record(rec, d, run) folds a finished run into the saved
-- records. drills.wall(kubbs, n, stakeX, stakeY, out) is THE WALL's test.
import "core/tw"
import "core/pitch"
import "core/rect"

local pitch, rect = tw.pitch, tw.rect
local abs, atan = math.abs, math.atan

local drills = {}

local function standing(id, kind, x, y)
	return { id = id, kind = kind, role = kind == "king" and "king" or "base", x = x, y = y,
		qw = 1, qx = 0, qy = 0, qz = 0, toppled = false }
end

local BASE_X <const> = { -2, -1, 0, 1, 2 }

-- the drills, in the board's order. score: what one point is; of: the
-- points a run can make; throws: per run.
drills.list = {
	{ id = "8m", name = "8 METERS", lines = { "SIX BATONS", "FIVE BASE KUBBS", "FROM THE BASELINE" },
		throws = 6, of = 5, kind = "base" },
	{ id = "house", name = "THE HOUSE", lines = { "SIX BATONS", "FIVE FIELD KUBBS", "BUNCHED UP AT 4 M" },
		throws = 6, of = 5, kind = "house" },
	{ id = "king", name = "KING SHOTS", lines = { "SIX BATONS", "AT THE KING ALONE", "FROM THE BASELINE" },
		throws = 6, of = 6, kind = "king" },
	{ id = "blast", name = "BLAST", lines = { "SIX KUBBS DRILLED", "TO THE MARKER", "WITHIN HALF A METER" },
		throws = 6, of = 6, kind = "blast" },
	{ id = "around", name = "AROUND THE PITCH", lines = { "FIVE BATONS", "ONE AT EACH BASE KUBB", "FROM IN FRONT OF IT" },
		throws = 5, of = 5, kind = "around" },
	-- of: every kubb of the six groups (14) plus a bonus for each baton (6)
	{ id = "doubles", name = "DOUBLES", lines = { "SIX BATONS, SIX GROUPS", "A POINT A KUBB DOWN", "+1 FOR TWO AT ONCE" },
		throws = 6, of = 20, kind = "doubles" },
	{ id = "wall", name = "THE WALL", lines = { "SIX KUBBS DRILLED", "INTO THE RIGHT STAKE", "A POINT A KUBB IN IT" },
		throws = 6, of = 6, kind = "wall" },
}

drills.tune = {
	blastCm = 50,          -- a drilled kubb resting this near the marker scores
	blastMarkerY = 6,      -- m from the baseline: BLAST's marker, fixed (scores stay comparable)
	house = { { 0.00, 4.20 }, { 0.10, 4.30 }, { -0.10, 4.32 }, { 0.03, 4.42 }, { -0.06, 4.52 } },
	lastN = 10,            -- the scores kept for LAST TEN
	-- DOUBLES: one group per baton, in this order, each stood fresh for its
	-- baton (the last group's kubbs are cleared), so every run faces the same
	-- six shots and bests compare. kind: "pair"/"triple" side by side (across
	-- the throw), "inline2"/"inline3" one behind the other (along it); gap:
	-- face to face in m (tools/compound.lua's 3, 7 and 15 cm); x, y: the
	-- group's center, field-kubb distances from the baseline (guesses, an
	-- easy first shot to a hard last one).
	doubles = {
		{ kind = "pair", gap = 0.03, x = 0.0, y = 4.6 },
		{ kind = "inline2", gap = 0.03, x = -0.8, y = 4.9 },
		{ kind = "triple", gap = 0.03, x = 0.8, y = 5.2 },
		{ kind = "pair", gap = 0.07, x = -0.5, y = 5.5 },
		{ kind = "inline3", gap = 0.07, x = 0.5, y = 5.8 },
		{ kind = "pair", gap = 0.15, x = 0.0, y = 6.0 },
	},
	doublesBonus = 1,      -- extra points when one baton takes down two or more of its group
	-- THE WALL: kubbs drilled into the centerline stake on the thrower's right
	-- (x = 2.5, y = 4 in the view frame; the marker moves freely)
	wallStake = 4,         -- index in pitch.stakes: the right-hand end of the centerline
	wallBand = 0.15,       -- m: a wall kubb's center within this of the centerline ...
	wallGap = 0.12,        -- m: ... and its footprint this near (edge to edge) the stake or a wall kubb
	wallLyingCos = 0.7071, -- lying: the long axis within 45 degrees of horizontal (|r33| under cos 45)
}

function drills.byId(id)
	for _, d in ipairs(drills.list) do if d.id == id then return d end end
	return nil
end

-- A new run of drill d.
function drills.newRun(d)
	-- kubbs: THE WALL's drilled kubbs at rest ({id, x, y, z, qw..qz, toppled});
	-- inWall: which of them are in the wall now; multi: DOUBLES batons that took two or more
	return { id = d.id, n = 0, score = 0, down = {}, done = false, kubbs = {}, inWall = {}, multi = 0 }
end

-- DOUBLES group g (a drills.tune.doubles entry) as standing field kubbs
-- "g<i>k1".. appended to out (a new table when nil). Kubb centers are a
-- kubb's side plus the gap apart, the group centered on (g.x, g.y).
function drills.group(g, i, out)
	out = out or {}
	local n = (g.kind == "triple" or g.kind == "inline3") and 3 or 2
	local step = pitch.kubbSide + g.gap
	local inline = g.kind == "inline2" or g.kind == "inline3"
	for k = 1, n do
		local o = (k - (n + 1) / 2) * step
		local x, y = g.x, g.y
		if inline then y = y + o else x = x + o end
		local p = standing("g" .. i .. "k" .. k, "kubb", x, y)
		p.role = "field"
		out[#out + 1] = p
	end
	return out
end

-- THE WALL's test over rest poses: kubbs[1..n] are { x, y, qw, qx, qy, qz }
-- (world meters, the view frame of the thrower). A kubb is in the wall when
--   1. it lies (long axis within 45 degrees of horizontal: wallLyingCos),
--   2. its center is on the pitch's width (|x| <= halfWidth) and within
--      wallBand of the centerline (|y - 4| <= wallBand), and its footprint
--      reaches the far half (touches or crosses y = 4),
--   3. its footprint (an oriented 15 x 7 cm rectangle) is within wallGap,
--      edge to edge, of the stake's circle at (stakeX, stakeY), or of a kubb
--      already in the wall: the chain grows from the stake.
-- Fills out[i] = true/false and returns how many are in. The score is the
-- wall as it stands: a kubb knocked out of it (or cut off from the stake)
-- stops counting. Once per throw, not per frame (rect makes tables).
function drills.wall(kubbs, n, stakeX, stakeY, out)
	local t = drills.tune
	local hl, hw = pitch.kubbLong / 2, pitch.kubbSide / 2
	local cy = pitch.center
	local rects, cand = {}, {}
	for i = 1, n do
		out[i] = false
		local k = kubbs[i]
		-- the long axis: column 3 of the rotation matrix
		local ax = 2 * (k.qx * k.qz + k.qw * k.qy)
		local ay = 2 * (k.qy * k.qz - k.qw * k.qx)
		local az = 1 - 2 * (k.qx * k.qx + k.qy * k.qy)
		if abs(az) < t.wallLyingCos and abs(k.x) <= pitch.halfWidth and abs(k.y - cy) <= t.wallBand then
			local r = rect.new(k.x, k.y, atan(ay, ax), hl, hw)
			local top = -math.huge
			for _, c in ipairs(rect.corners(r)) do if c[2] > top then top = c[2] end end
			if top >= cy then
				rects[i], cand[#cand + 1] = r, i
			end
		end
	end
	-- the chain: from the stake, then from every kubb found in the wall
	local count, queue, head = 0, {}, 1
	for _, i in ipairs(cand) do
		if rect.pointDistance(rects[i], stakeX, stakeY) - pitch.stakeRadius <= t.wallGap then
			out[i], count = true, count + 1
			queue[#queue + 1] = i
		end
	end
	while head <= #queue do
		local a = rects[queue[head]]
		head = head + 1
		for _, i in ipairs(cand) do
			if not out[i] and rect.distance(a, rects[i]) <= t.wallGap then
				out[i], count = true, count + 1
				queue[#queue + 1] = i
			end
		end
	end
	return count
end

-- The pieces standing for this run now (kubbs knocked down stay down; the
-- king is stood back up after each throw).
local function pieces(d, run)
	local out = {}
	if d.kind == "base" or d.kind == "around" then
		for i, x in ipairs(BASE_X) do
			local id = "b" .. i
			if not run.down[id] then out[#out + 1] = standing(id, "kubb", x, pitch.length) end
		end
	elseif d.kind == "house" then
		for i, p in ipairs(drills.tune.house) do
			local id = "f" .. i
			if not run.down[id] then
				local k = standing(id, "kubb", p[1], p[2])
				k.role = "field" -- field kubbs: the aim takes the field-kubb arc (4 o'clock)
				out[#out + 1] = k
			end
		end
	elseif d.kind == "doubles" then
		-- this baton's group only, standing fresh
		local g = drills.tune.doubles[run.n + 1]
		if g then drills.group(g, run.n + 1, out) end
		return out
	elseif d.kind == "wall" then
		-- every kubb drilled so far, lying where it came to rest (no king:
		-- it stands on the centerline the wall runs along)
		for i = 1, #run.kubbs do
			local k = run.kubbs[i]
			out[#out + 1] = { id = k.id, kind = "kubb", role = "field", x = k.x, y = k.y, z = k.z,
				qw = k.qw, qx = k.qx, qy = k.qy, qz = k.qz, toppled = k.toppled }
		end
		return out
	end
	if d.kind ~= "blast" then out[#out + 1] = standing("king", "king", pitch.king.x, pitch.king.y) end
	return out
end

-- The next throw's setup, or nil when the run is over.
function drills.setup(d, run)
	if run.done then return nil end
	local ps = pieces(d, run)
	local s = { kind = "baton", side = "A", pieces = ps, lineY = 0, forwardY = 0, projectile = "baton",
		n = run.n + 1, of = d.throws, batonId = "baton" }
	local targets = {}
	for _, p in ipairs(ps) do
		if p.kind == "kubb" then targets[#targets + 1] = p.id end
	end
	if d.kind == "king" or #targets == 0 then targets = { "king" } end
	s.targets = targets
	if d.kind == "blast" then
		s.kind, s.projectile, s.kubb, s.targets = "toss", "kubb", "d1", nil
		s.markerX, s.markerY = 0, drills.tune.blastMarkerY   -- fixed: the d-pad does not move it
	elseif d.kind == "wall" then
		-- each drilled kubb its own piece (w1 .. w6), kept on the pitch; the
		-- marker is free (no markerY: throw keeps it where the last throw left it)
		s.kind, s.projectile, s.kubb, s.targets = "toss", "kubb", "w" .. (run.n + 1), nil
	elseif d.kind == "around" then
		-- from in front of the kubb whose turn it is (the next standing one)
		s.playerX = BASE_X[run.n + 1]
	end
	return s
end

-- What a throw did: res.toppled (ids), res.restCm (a drilled kubb's rest
-- from the marker). Returns true when the run is over.
function drills.tally(d, run, res)
	run.n = run.n + 1
	if d.kind == "blast" then
		if res.restCm and res.restCm <= drills.tune.blastCm then run.score = run.score + 1 end
	elseif d.kind == "doubles" then
		-- a point for every kubb of this baton's group down, and a bonus when
		-- one baton took two or more
		local prefix, n = "g" .. run.n .. "k", 0
		for _, id in ipairs(res.toppled or {}) do
			if id:sub(1, #prefix) == prefix and not run.down[id] then
				run.down[id] = true
				n = n + 1
			end
		end
		run.score = run.score + n
		if n >= 2 then
			run.score = run.score + drills.tune.doublesBonus
			run.multi = run.multi + 1
		end
	elseif d.kind == "wall" then
		-- every wall kubb where this throw left it (res.bodies: the throw's
		-- world result, rest poses by id), then the wall as it stands
		local bodies = res.bodies or {}
		local id = "w" .. run.n
		if bodies[id] then run.kubbs[#run.kubbs + 1] = { id = id } end
		for i = 1, #run.kubbs do
			local k, b = run.kubbs[i], bodies[run.kubbs[i].id]
			if b then
				k.x, k.y, k.z, k.qw, k.qx, k.qy, k.qz, k.toppled = b.x, b.y, b.z, b.qw, b.qx, b.qy, b.qz, b.toppled
			end
		end
		local st = pitch.stakes[drills.tune.wallStake]
		run.score = drills.wall(run.kubbs, #run.kubbs, st.x, st.y, run.inWall)
	elseif d.kind == "king" then
		for _, id in ipairs(res.toppled or {}) do
			if id == "king" then run.score = run.score + 1 break end
		end
	else
		for _, id in ipairs(res.toppled or {}) do
			if id ~= "king" and not run.down[id] then
				run.down[id] = true
				run.score = run.score + 1
			end
		end
	end
	-- over after its throws, or when nothing is left standing to knock down
	if run.n >= d.throws or ((d.kind == "base" or d.kind == "house" or d.kind == "around") and run.score >= d.of) then
		run.done = true
	end
	return run.done
end

-- Records: { [id] = { best, runs, points, possible, last = {...} } }.
-- Folds a finished run in; returns the drill's record and whether it is a
-- new best.
function drills.record(rec, d, run)
	local r = rec[d.id]
	if not r then
		r = { best = 0, runs = 0, points = 0, possible = 0, last = {} }
		rec[d.id] = r
	end
	local best = run.score > r.best
	if best then r.best = run.score end
	r.runs, r.points, r.possible = r.runs + 1, r.points + run.score, r.possible + d.of
	r.last[#r.last + 1] = run.score
	while #r.last > drills.tune.lastN do table.remove(r.last, 1) end
	return r, best
end

-- A record's rate (whole percent of the points possible), or nil.
function drills.rate(r)
	if not r or r.possible == 0 then return nil end
	return math.floor(100 * r.points / r.possible + 0.5)
end

tw.drills = drills
