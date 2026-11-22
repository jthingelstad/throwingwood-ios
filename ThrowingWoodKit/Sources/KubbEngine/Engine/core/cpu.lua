-- Choose: which play, and why (docs/notes/computer-player.md, "Four parts"). For a
-- match setup it reads the pitch (core/read), makes the choices the computer makes and
-- returns them as an intent the hand (core/autothrow) can throw, with the reason:
--
--   local d = cpu.decide(s, r, level)
--   -- d = { kind = "toss" | "baton",
--   --       intent = toss:  { tx, ty (the spot, view frame), basket (-1 left, 1 right),
--   --                         spin (taps, + right), arc, standY (the line stood on) }
--   --                baton: { on (the piece's id), tx, ty (the aim point), aimZ,
--   --                         standY, stance = { x, y }, arc },
--   --       why = { play = an id in core/plays (nil when no play covers it),
--   --               facts = { ... } } }
--   cpu.text(d.why)   -- the play's sentence with its facts in it
--
-- 0.11.1 cut it out of autothrow.choose with no change in play: the same choices in the
-- same order, and the same draws from r (the basket's coin on a tie, nothing else).
-- 0.12.0 adds two plays (cpu.tune: field.line, inkast.depth) and still draws nothing
-- else: a level knows a play or does not, so Choose needs no stream of its own yet (it
-- comes with the first play a level uses only some of the time).
-- cpu.last is the last decision made, for a host that wants the reason beside a throw;
-- autothrow.choose's result does not carry it, since that table reaches the session's
-- actions and recordings.
import "core/tw"
import "core/throwplan"
import "core/drill"
import "core/read"     -- before autothrow: read finishes loading it (core/read's note)
import "core/autothrow"
import "core/plays"
import "core/raising"

local plan, autothrow, read, plays = tw.plan, tw.autothrow, tw.read, tw.plays

local cpu = {}

-- The plays added in 0.12.0 (docs/notes/computer-player.md, "How a play gets in"), each
-- switched by level (1: the level knows it, 0: it does not) and off entirely by on = 0,
-- so the Gym can play a level with and without (`--set cpu.tune.line.pro=0`). A level
-- not named does not know the play. Each play's numbers sit beside its switches.
cpu.tune = {
	-- field.line: stand where the kubbs line up (core/cpu lineChoice)
	line = {
		on = 1, beginner = 0, club = 0, pro = 1,
		carry = 1,       -- a lane's worth: 1 + carry x (kubbs in it - 1), times the chance of
		                 -- hitting its front kubb: 1 counts every kubb in the lane as taken
		hitHalf = 0.06,  -- m either side of the front kubb's line that hits it (plan.tune.straightM)
		reach = 0.6,     -- m: a pair of kubbs further apart than laneDeep + this proposes no stance
		step = 0.35,     -- m along the line: the steps tried either way when straight behind is no good
		weigh = 1,       -- 1: count the kubbs behind the front one as raise.par weighs a pair
		                 -- (read.lineLane's w); 0: the lane's count less one
	},
	-- field.drive (built switched off in 0.16.0, on at club and pro in 0.18.0): every baton
	-- on a person's default line (plan.arcFor: the drive close in, as before at 8 m)
	-- instead of the line before (plan.sharedArcFor). Built first for a close group only
	-- (another standing field kubb within 45 cm, the front one within 5 m); the line for
	-- every baton beat that side against side, 56.0% at club and 55.0% at pro
	-- (docs/reference/plays/field.md field.drive). Beginner and kid do not know it
	drive = {
		on = 1, beginner = 0, club = 1, pro = 1,
	},
	-- inkast.depth: lay the kubbs one behind another down the baton's path (core/cpu depthSpot).
	-- Pro only: it made club stronger and moved club away from real play (longer games,
	-- more doubles), so club plays as 0.11.2 did until it is retuned as a whole (Jamie,
	-- 2026-11-21; docs/notes/gym.md, "The attacker's plays")
	depth = {
		on = 1, beginner = 0, club = 0, pro = 1,
		gap = 0.04,      -- m between a kubb's front face and the next kubb's back face
		run = 4,         -- kubbs in one column before the next starts beside it (laneDeep holds four)
		x = 0,           -- m from the middle the first column lies at; 0: the basket's (basketX)
		back = 0,        -- m past the basket the first kubb of an empty basket rests
		front = 4.35,    -- m from the baseline: no kubb of a column nearer the centre line than
		                 -- this, and an empty basket's first kubb rests deep enough that a full
		                 -- column fits behind it. The other team's columns stand in the
		                 -- thrower's own half by the same corner (the baskets face each other):
		                 -- two columns grown to the centre line stand a hand apart, and a baton
		                 -- at the far one's front kubb touches the near one (II.B.11, forfeit)
	},
}

-- Does level lname know play `name` of cpu.tune?
local function knows(name, lname)
	local p = cpu.tune[name]
	return p.on ~= 0 and (p[lname] or 0) ~= 0
end
cpu.knows = knows

-- The level a throw is made at: the one given, else the thrower's, else
-- autothrow.tune.level (and that when either is not a name).
function cpu.levelName(s, level)
	local t = autothrow.tune
	local lname = level or (s.thrower and s.thrower.level) or t.level
	if type(lname) ~= "string" then lname = t.level end
	return lname
end

-- inkast.corner: which basket a toss goes to, -1 (left, view frame) or 1 (right): the
-- one with more field kubbs of the far half within basketNear of it, so a turn's kubbs
-- group (Jamie, 2026-11-14). A tie is a coin from r, the only draw a decision makes.
-- Returns the side, the field kubbs near it and near the other, and whether it was the
-- coin.
function cpu.basket(s, r)
	local left, right = read.basketCounts(s)
	if left > right then return -1, left, right, false elseif right > left then return 1, right, left, false end
	return (r.next() < 0.5) and -1 or 1, left, right, true
end

-- inkast.roll, as 0.10 did it (2026-11-16, Jamie: "good drillers roll into other kubbs
-- because it is impossible to stop that much energy with just the ground and grass").
-- Once a kubb of the far half lies near the basket, a drill is aimed so that it would
-- rest intoShort in front of a lying kubb's near face, in that kubb's lane: the half of
-- the run-ons that would carry it on are stopped by the kubb, so the two end together.
-- A line (fewer than clusterFrom kubbs this turn): the front kubb of the group nearest
-- the basket, so the line grows toward the thrower. A cluster: in front of whichever
-- lying kubb leaves the aim nearest the group's middle, so the kubbs pile round it. nil
-- when no lying kubb is near the basket, or no aim in front of one is clear. Otherwise
-- x, y and the kubb it is aimed in front of.
local function intoSpot(s, t, bx, by, shortLying)
	local cluster = (s.of or 0) >= t.clusterFrom
	local n, cx, cy = read.lyingNear(s, bx, by)
	if n == 0 then return nil end
	local best, bestX, bestY, bestP
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and p.toppled and read.nearBasket(p, bx, by) then
			-- the kubb's half extent along the throw (it lies along its angle)
			local a = p.pose and p.pose.angle or 0
			local ca, sa = math.cos(a), math.sin(a)
			if ca < 0 then ca = -ca end
			if sa < 0 then sa = -sa end
			local ext = 0.075 * sa + 0.035 * ca
			local x, y = p.x, p.y - ext - t.intoShort
			-- clear of every other kubb (this one is the backstop: the aim
			-- sits in its own clear ellipse on purpose)
			if read.spotClear(s, x, y, shortLying, p) then
				local cost
				if cluster then
					local ex, ey = x - cx, y - cy
					cost = ex * ex + ey * ey
				else
					-- the front of the group: least y, then nearest the basket across
					local ex = x - bx
					cost = y * 100 + ex * ex
				end
				if not best or cost < best - 1e-9 then best, bestX, bestY, bestP = cost, x, y, p end
			end
		end
	end
	if not best then return nil end
	return bestX, bestY, bestP
end

-- inkast.depth (0.12.0; kn-drill-2012 p3.13, p4.13, p5.13; yt-Io-rxbSB3Ns 1:13, 1:30):
-- the kubbs lie one behind another down the baton's path, a column along the throw. A
-- drill flies nose first from straight behind its mark, so it lies along the throw, and a
-- defender can raise a lying kubb only onto one of its two ends, along its length: kubbs
-- lying end to end in one lane stand in that lane whichever ends the defender picks, a
-- shape raise.par cannot take apart (raising.parExposure counts each pair as one behind
-- the other, however it stands them). The first kubb rests in the basket (at depth.x
-- across when set, depth.back past it). Each later one is aimed to rest depth.gap in
-- front of the front kubb of a column, with the same dead landing and roll as the row
-- (inkast.roll: the spin toward the sideline, the plan aiming short of the spot by the
-- run on and to the side by the roll), so a kubb that runs on is stopped by the one
-- behind it. A column holds depth.run kubbs (four fill the computer's laneDeep); then the
-- next column starts flank to flank with the innermost column's back kubb, on its inner
-- side, and grows forward beside it. The column nearest the basket across is built first.

-- How far a kubb lying at angle a reaches across (x) and along (y) from its centre.
local function extents(p)
	if not p.toppled then return 0.035, 0.035 end
	local a = p.pose and p.pose.angle or 0
	local ca, sa = math.cos(a), math.sin(a)
	if ca < 0 then ca = -ca end
	if sa < 0 then sa = -sa end
	return 0.075 * ca + 0.035 * sa, 0.075 * sa + 0.035 * ca
end

-- Can a drill rest at (x, y), lying along the throw: inside the spot area, on no field
-- kubb of the far half, and with none lying in its lane within `short` in front of it
-- (where it comes down)?
local function depthFree(s, x, y, short, t)
	local ax = x < 0 and -x or x
	local minY = t.spotMinY
	if cpu.tune.depth.front > minY then minY = cpu.tune.depth.front end
	if ax > t.spotMaxX or y < s.lineY + minY then return false end
	for _, p in ipairs(s.pieces) do
		if read.farField(s, p) then
			local ex, ey = extents(p)
			local dx, dy = p.x - x, p.y - y
			if dx < 0 then dx = -dx end
			if dx < ex + 0.03 then
				if dy < ey + 0.07 and dy > -(ey + 0.07) then return false end
				if dy < 0 and -dy < ey + 0.075 + short then return false end
			end
		end
	end
	return true
end

local function depthSpot(s, side, ik, t)
	local dt = cpu.tune.depth
	local bx = side * ((dt.x ~= 0) and dt.x or t.basketX)
	local by = s.lineY + t.basketY + dt.back
	-- where a drill comes down in front of its rest: its run on at this spin, at least
	-- spotShortLying (a kubb lying there is in its way)
	local short = tw.drill.slideFor(plan.loftFor(plan.arcFor("drill")), s.surface, ik.spin * plan.tune.spinPerStep)
	if short < t.spotShortLying then short = t.spotShortLying end
	-- the turn's kubbs lying near the basket (within half a metre across, a metre along)
	local best, bestX, bestY, bestP
	local inner, n = nil, 0
	for _, p in ipairs(s.pieces) do
		if read.farField(s, p) and p.toppled and math.abs(p.x - bx) < 0.5 and math.abs(p.y - by) < 1 then
			n = n + 1
			if not inner or side * p.x < side * inner.x then inner = p end
			-- the column it heads: kubbs lying within 4 cm across of it
			local col = 0
			for _, q in ipairs(s.pieces) do
				if read.farField(s, q) and q.toppled and math.abs(q.x - p.x) < 0.04 and math.abs(q.y - by) < 1 then col = col + 1 end
			end
			if col < dt.run then
				local _, ey = extents(p)
				local x, y = p.x, p.y - ey - dt.gap - 0.075
				if depthFree(s, x, y, short, t) then
					-- the column nearest the basket across, then its front
					local cost = math.abs(x - bx) * 100 + y
					if not best or cost < best - 1e-9 then best, bestX, bestY, bestP = cost, x, y, p end
				end
			end
		end
	end
	if n == 0 then
		-- deep enough for a full column (of the kubbs in hand, up to run) in front of it
		local k = (s.of or 1) - (s.n or 1) + 1
		if k > dt.run then k = dt.run end
		local y0 = s.lineY + dt.front + (k - 1) * (0.15 + dt.gap)
		if y0 > by then by = y0 end
		return bx, by, "depth"
	end
	if best then return bestX, bestY, "depth", bestP end
	-- every column full: the next starts beside the innermost column's back kubb
	local back = inner
	for _, q in ipairs(s.pieces) do
		if read.farField(s, q) and q.toppled and math.abs(q.x - inner.x) < 0.04 and q.y > back.y and math.abs(q.y - by) < 1 then back = q end
	end
	local x, y = back.x - side * t.rowStep, back.y
	if depthFree(s, x, y, short, t) then return x, y, "column", back end
	return inner.x - side * t.rowStep, inner.y, "row", inner
end

-- Where a toss to basket `side` should rest (view frame), for the level's inkast entry
-- ik (autothrow.tune.inkast; nil for a level it does not name). Returns x, y, how it was
-- chosen ("basket", "row", "into", "clear") and the lying kubb it goes beside (row and
-- into).
--   group 0 (beginner): the basket itself.
--   row (club; pro too with inkast.depth off; 0.11): flank to flank with the innermost kubb lying by the basket.
--   otherwise (0.10, and a level ik does not name): into the group (intoSpot) when
--   tune.into is on, else the clear spot nearest the basket on a small grid (tune.spot*):
--   not on a kubb and with none in the lane it comes down and runs on in (a drill lands
--   short of its spot by its run on, so a kubb already down just past the spot is its
--   backstop). Nearest counts a step along the throw as little against one across (a
--   line along the throw) when the turn has fewer than clusterFrom kubbs to throw, else
--   the same (a cluster). The basket itself when every spot is taken.
function cpu.spot(s, side, ik, lname)
	local t = autothrow.tune
	local bx, by = side * t.basketX, s.lineY + t.basketY
	if ik and ik.group == 0 then return bx, by, "basket" end
	if ik and lname and knows("depth", lname) then return depthSpot(s, side, ik, t) end
	if ik and ik.row ~= 0 then
		-- inkast.roll: rest flank to flank with the innermost kubb lying by the basket, on
		-- its inner side. The plan lands it short of that across and its spin rolls it
		-- in (drill.rollFor)
		local best = read.innermostLying(s, side)
		if best then return best.x - side * t.rowStep, best.y, "row", best end
		return bx, by, "basket"
	end
	local best, bestX, bestY
	local costY = ((s.of or 0) >= t.clusterFrom) and t.spotCostYCluster or t.spotCostY
	local shortLying = tw.drill.slideFor(plan.loftFor(plan.arcFor("drill")), s.surface)
	if shortLying < t.spotShortLying then shortLying = t.spotShortLying end
	if t.into ~= 0 then
		local ix, iy, ip = intoSpot(s, t, bx, by, shortLying)
		if ix then return ix, iy, "into", ip end
	end
	for i = -t.spotCols, t.spotCols do
		for j = -t.spotRows, t.spotRows do
			local x, y = bx + i * t.spotStepX, by + j * t.spotStepY
			if read.spotClear(s, x, y, shortLying) then
				local cx, cy = i, j * costY
				local cost = cx * cx + cy * cy
				if not best or cost < best - 1e-9 then best, bestX, bestY = cost, x, y end
			end
		end
	end
	if not best then return bx, by, "basket" end
	return bestX, bestY, "clear"
end

local function decideToss(s, r, lname, t)
	local ik = t.inkast[lname]
	local side, near, other, coin = cpu.basket(s, r)
	local tx, ty, how, beside = cpu.spot(s, side, ik, lname)
	-- inkast.roll: spun to roll toward the sideline (the plan aims short of the spot by
	-- the roll); a level the inkast table does not name spins drillSpin
	local spin = ik and ik.spin * side or t.drillSpin
	-- from the line a kubb is thrown from: the baseline, or in a Kid match (s.kid, 0.15.0)
	-- the Kid line, which its setup's forwardY is
	local intent = { tx = tx, ty = ty, basket = side, spin = spin, arc = plan.arcFor("drill"),
		standY = (s.kid and s.forwardY) or s.lineY }
	-- a kubb aimed beside one already down carries out inkast.roll; one aimed at the
	-- basket or the clear spot nearest it, inkast.corner
	local play = (how == "row" or how == "into") and "inkast.roll" or "inkast.corner"
	if how == "depth" or how == "column" then play = "inkast.depth" end
	local facts = { basket = side < 0 and "left" or "right", near = near, other = other, coin = coin,
		spot = how, beside = beside and beside.id, spin = spin, inHand = s.of, kubb = s.n }
	return { kind = "toss", intent = intent, why = { play = play, facts = facts } }
end

-- The line a baton at piece p is thrown from: as far forward as allowed (the advantage
-- line), never nearer than minRange; the king from the baseline.
local function standY(s, p, t)
	local py = s.kingShot and s.lineY or (s.forwardY or s.lineY)
	if py > p.y - t.minRange then py = p.y - t.minRange end
	if py < s.lineY then py = s.lineY end
	return py
end

-- erf(x) to 1.5e-7 (Abramowitz and Stegun 7.1.26): the chance a normal miss stays inside
-- a half width.
local function erf(x)
	local sx = 1
	if x < 0 then sx, x = -1, -x end
	local u = 1 / (1 + 0.3275911 * x)
	local y = 1 - (((((1.061405429 * u - 1.453152027) * u) + 1.421413741) * u - 0.284496736) * u + 0.254829592) * u * math.exp(-x * x)
	return sx * y
end

-- field.line: the chance a baton thrown range m at level lname passes within hitHalf of
-- its line at the target. The angle's sd is the nerves' (plan.nervesSd at the reach the
-- throw needs, as plan.spread reads it) with the swing's pull added (a mean shake's
-- plan.tune.lateralDeg), so a longer throw from the side counts against a lane.
local function lineHit(range, lname, lt, t)
	local lv = autothrow.cpuLevel(lname)
	local nd = plan.nervesSd(lv, plan.backFor(range), 0, 1, false)
	local pd = plan.tune.lateralDeg * t.shakeMax * 0.5 * (t.swingScale[lname] or 1) * (lv.shakeGain or 1)
	local sd = math.tan(math.rad(math.sqrt(nd * nd + pd * pd))) * range
	if sd < 1e-6 then return 1 end
	return erf(lt.hitHalf / (sd * 1.4142135623730951))
end

-- field.line (ko-2017-blasting p1.17, p1.18, p1.20; yt-Io-rxbSB3Ns 1:30): a person moves
-- along the throwing line until two kubbs stand one behind the other, then throws
-- through the front one. For every standing field kubb f the stances tried on line py
-- (inside +/- halfWidth) are: straight behind f (field.roles' stance), and for every
-- other standing kubb g beyond f within laneDeep + reach of it, the point where the line
-- from g through f meets py; and when straight behind is no good, steps along the line
-- either way (`step`, twice). Each is scored by the lane along that line (read.lineLane)
-- and the chance of hitting f from there (lineHit): (1 + carry x behind) x hit, where
-- behind is the kubbs behind f weighed as raise.par weighs a pair (weigh = 1) or counted
-- (weigh = 0). At ten field kubbs that is at most 10 + 45 lane tests (a pair proposes a
-- stance only from the nearer kubb), plus 4 for each kubb whose straight stance is no
-- good, each over the ten kubbs and the pieces. Each front is thrown at from its own line
-- (standY). Returns the best front, its stance x and y, the lane's n, lo and hi (across
-- the line) and its score; nil when no stance is any good.
local function lineChoice(s, pos, lname, t)
	local lt = cpu.tune.line
	local hw = t.halfWidth
	local reach = t.laneDeep + lt.reach
	local best, bx, by, bn, blo, bhi, bscore
	local py
	local function try(f, sx)
		if sx < -hw or sx > hw then return false end
		local n, lo, hi, range, bad, w = read.lineLane(s, pos, f, sx, py)
		if bad or n == 0 then return false end
		local behind = (lt.weigh ~= 0) and w or (n - 1)
		local score = (1 + lt.carry * behind) * lineHit(range, lname, lt, t)
		if not bscore or score > bscore + 1e-9 then
			best, bx, by, bn, blo, bhi, bscore = f, sx, py, n, lo, hi, score
		end
		return true
	end
	for _, id in ipairs(s.targets) do
		local f = pos[id]
		if f and f.role == "field" then
			py = standY(s, f, t)
			local x0 = f.x
			if x0 < -hw then x0 = -hw elseif x0 > hw then x0 = hw end
			if not try(f, x0) then
				-- straight behind is no good (a kubb of its own half by the stance, the king
				-- on the line): a step or two along the line either way
				for k = 1, 2 do
					try(f, x0 - k * lt.step)
					try(f, x0 + k * lt.step)
				end
			end
			for _, id2 in ipairs(s.targets) do
				local g = pos[id2]
				if g and g ~= f and g.role == "field" and g.y > f.y and f.y > py + 1e-6 then
					local dx, dy = g.x - f.x, g.y - f.y
					if dx * dx + dy * dy <= reach * reach then
						-- back along g -> f to the line py
						try(f, f.x - dx * (f.y - py) / dy)
					end
				end
			end
		end
	end
	return best, bx, by, bn, blo, bhi, bscore
end

local function decideBaton(s, t, lname)
	local pos = read.byId(s)
	local target = pos[s.targets[1]]
	-- the nearest target to the line
	for _, id in ipairs(s.targets) do
		local p = pos[id]
		if p and p.y < target.y then target = p end
	end
	local tx = target.x
	local play, lane
	if target.role == "field" then
		-- field.roles: the lane with the most standing field kubbs; the nearest front on
		-- a tie. Aimed across at the middle of the lane, along at its front kubb
		play, lane = "field.roles", 0
		for _, id in ipairs(s.targets) do
			local f = pos[id]
			if f and f.role == "field" then
				local n, lo, hi = read.lane(s, pos, f)
				if n > lane or (n == lane and f.y < target.y) then
					lane, target, tx = n, f, (lo + hi) / 2
				end
			end
		end
	end
	-- field.line, at a level that knows it: the stance along the line and the front kubb
	-- the baton is likely to take the most from (lineChoice; straight behind each kubb is
	-- one of the stances it weighs). over: the lane field.roles found straight on
	local lx, ly, lscore, lfacts
	if target.role == "field" and knows("line", lname) then
		local f, sx, sy, n, lo, hi, score = lineChoice(s, pos, lname, t)
		if f then
			-- aimed at the front kubb, moved across the line to the middle of the lane
			local ux, uy = f.x - sx, f.y - sy
			local l = math.sqrt(ux * ux + uy * uy)
			local m = (lo + hi) / 2
			lfacts = { over = lane, stanceX = sx, range = l }
			target, lane, lx, ly, lscore = f, n, sx, sy, score
			tx = f.x + uy / l * m
			lfacts.aimY = f.y - ux / l * m
		end
	end
	local ty = lfacts and lfacts.aimY or (target.y - t.batonShort)
	local king = s.kingShot or target.role == "king"
	-- through the piece at its aim height (plan.tune.aimHeightShare), as a
	-- player's circle on a piece is
	local aimZ = plan.aimZFor(king and "king" or "kubb")
	-- as far forward as allowed, never nearer than minRange; the king from the baseline
	local py = standY(s, target, t)
	local st
	if lx then
		st = { x = lx, y = ly }
		-- field.line names itself only when it moved off straight behind the front kubb
		local x0 = target.x
		if x0 < -t.halfWidth then x0 = -t.halfWidth elseif x0 > t.halfWidth then x0 = t.halfWidth end
		if math.abs(lx - x0) > 0.01 then play = "field.line" end
	else
		st = plan.stance(tx, ty, s.lineY, py, t.halfWidth, {})
	end
	-- the default arc for the distance: the line a person's followed until 0.16 (plan.sharedArcFor)
	local dx, dy = tx - st.x, ty - st.y
	local dist = math.sqrt(dx * dx + dy * dy)
	local arc = plan.sharedArcFor(dist)
	-- field.drive, at a level that knows it: a person's default line. It names itself at a
	-- field kubb when the arc is a drive (under the knee), unless field.line moved the stance
	local drive = false
	if knows("drive", lname) and not king then
		arc = plan.arcFor("baton", dist)
		drive = target.role == "field" and not king and arc < plan.tune.driveKneeDeg
		if drive and play ~= "field.line" then play = "field.drive" end
	end
	local intent = { on = target.id, tx = tx, ty = ty, aimZ = aimZ, standY = py, stance = st, arc = arc }
	local facts = { on = target.id, target = king and "king" or target.role, targets = #s.targets, lane = lane }
	if lfacts then
		facts.over, facts.stanceX, facts.range, facts.score = lfacts.over, lx, lfacts.range, lscore
	end
	if drive then facts.drive = true end
	return { kind = "baton", intent = intent, why = { play = play, facts = facts } }
end

-- The decision for match setup s (view frame) at level (a tw.plan level name; default
-- the thrower's, then autothrow.tune.level). Tosses: the basket (inkast.corner) and the
-- spot in it (inkast.roll), drilled from the baseline (a Kid match's Kid line). Batons: the nearest live target,
-- at a field the lane with the most kubbs (field.roles), stood behind as far forward as
-- allowed. Draws from r only for the basket's coin.
function cpu.decide(s, r, level)
	local t = autothrow.tune
	local lname = cpu.levelName(s, level)
	local d
	if s.kind == "toss" then d = decideToss(s, r, lname, t) else d = decideBaton(s, t, lname) end
	cpu.last = d
	return d
end

-- ---------- raising (0.12.0) ----------

-- How the computer stands the other team's kubbs, by its level (raise.par; Q7 in
-- docs/reference/QUESTIONS.md, Jamie's decision of 2026-11-21). Pro counts the
-- attacker's batons. Club spreads the kubbs apart: what club players do. A beginner
-- stands them anyhow: `first` (the first end the rules list) stands in for a random end,
-- which needs Choose's own random stream, and that does not exist yet (the throw's stream
-- must not be drawn from for it: docs/notes/computer-player.md, "Rules this design
-- keeps"). A level not named here raises apart.
-- Kid (0.15.0, docs/notes/kid-mode.md) raises as simply as a beginner, `first`: never
-- `apart` or `par`, which spread or break up a child's kubbs on purpose.
cpu.raising = { kid = "first", beginner = "first", club = "apart", pro = "par" }

-- A person's side, when the engine raises for it (RAISING: AUTOMATIC) and as the end
-- offered first when the person raises by hand: the engine's best advice.
cpu.advice = "par"

-- The raising policy (a name in tw.raising.policies) of the computer at `level` (default
-- autothrow.tune.level, as a throw's).
function cpu.raisePolicy(level)
	return cpu.raising[cpu.levelName({}, level)] or "apart"
end

-- The computer raises: the choice for decision dec (raising.options) in context ctx
-- (Game:context) at `level`. Returns the index into dec.choices, as a raising policy
-- does, so `function(dec, ctx) return cpu.raise(dec, ctx, level) end` is one. Keeps the
-- decision in cpu.last, as cpu.decide does a throw's:
--   { kind = "raise", intent = { ["end"] = which (1 or 2), choice = the index },
--     why = { play = "raise.par" (nil for a policy that carries out no play),
--             facts = { level, policy, choices, exposure, over, tie } } }
-- exposure is how much the end chosen leaves in line (raising.parExposure, summed), over
-- the most another end would have; tie: they were within raising.tune.parTie, and apart
-- decided. Never on the game, an action or anything hashed.
function cpu.raise(dec, ctx, level)
	local lname = cpu.levelName({}, level)
	local name = cpu.raising[lname] or "apart"
	local i, info = tw.raising.choose(dec, ctx, name)
	local c = dec.choices[i]
	local facts = { level = lname, policy = name, choices = #dec.choices }
	if info then facts.exposure, facts.over, facts.tie = info.exposure, info.over, info.tie end
	cpu.last = { kind = "raise", intent = { ["end"] = c and c.which, choice = i },
		why = { play = (name == "par") and "raise.par" or nil, facts = facts } }
	return i
end

-- The sentence for a decision's reason (why), its {name}s filled from the facts; nil
-- when it names no play. A {name} with no fact of that name is left as it is.
function cpu.text(why)
	local p = why and why.play and plays[why.play]
	if not p then return nil end
	return (p.say:gsub("{(%w+)}", why.facts or {}))
end

tw.cpu = cpu
