-- Read: the situation, with no decisions in it (docs/notes/computer-player.md, "Four
-- parts"). What the computer works out about the pitch before it chooses a play: the
-- field kubbs near each basket, the lying kubbs near one and the innermost of them,
-- whether a spot is clear for a drill, and how many standing field kubbs stand in a
-- front kubb's lane. Its words are docs/reference/SITUATIONS.md's. Nothing here draws
-- from a random stream or chooses; core/cpu does that.
--
-- The tune numbers it reads (basket*, spot*, lane*) stay in autothrow.tune, where the
-- Gym's --set autothrow.tune.* and the session's tune files have always found them;
-- they are read at each call, so a change to them takes effect at once.
--
--   read.basketAt(s, side)            -> x, y of basket side (-1 left, 1 right)
--   read.basketCounts(s)              -> field kubbs near the left and right baskets
--   read.lyingNear(s, bx, by)         -> n, mean x, mean y of lying kubbs near (bx, by)
--   read.innermostLying(s, side)      -> the lying kubb nearest the middle by basket side
--   read.spotClear(s, x, y, shortLying, except) -> can a drill be aimed at (x, y)?
--   read.inNow(p)                     -> is far-half kubb p in bounds as it lies (not out for now)?
--   read.byId(s)                      -> { [id] = piece }
--   read.lane(s, pos, f)              -> n, lo, hi: front kubb f's lane
import "core/tw"
import "core/raising"  -- field.line weighs a lane as raise.par weighs a pair

-- autothrow (for its tune) is imported at the end, once tw.read is set: autothrow
-- imports core/cpu, which needs core/read, so whichever of the three a host imports
-- first, each finds the others in place.
local autothrow

local read = {}

-- Is piece p a field kubb of the half s's thrower throws at (the far half)? Kubbs in
-- the thrower's own half never count.
function read.farField(s, p)
	return p.role == "field" and p.half ~= s.side
end

-- Is field kubb p in bounds as it lies: could it be raised in the far half (the rules'
-- own test, raising.canRaise in Game:_outNow)? A kubb thrown this turn that is out lies on
-- the pitch until the round is judged and is then thrown again (II.C.4), so the inkast
-- does not count it or build beside it (1.2.0). Read in the view frame, where the
-- thrower's baseline is y = 0 and the far half is the world's B half; a lying kubb with
-- no pose angle is taken to lie along the throw. autothrow.tune.inkastSkipOut = 0 counts
-- every kubb, as 1.1 did.
function read.inNow(p)
	if (autothrow.tune.inkastSkipOut or 0) == 0 then return true end
	local a = (p.pose and p.pose.angle) or math.pi / 2
	return tw.raising.canRaise({ x = p.x, y = p.y, standing = not p.toppled, angle = a }, "B")
end

-- Where basket `side` is (view frame): -1 left, 1 right.
function read.basketAt(s, side)
	local t = autothrow.tune
	return side * t.basketX, s.lineY + t.basketY
end

-- Is piece p within basketNear of (bx, by)?
function read.nearBasket(p, bx, by)
	local t = autothrow.tune
	local dx, dy = p.x - bx, p.y - by
	return dx * dx + dy * dy < t.basketNear * t.basketNear
end

-- How many field kubbs of the far half, lying or standing, lie within basketNear of
-- the left basket and of the right one (a kubb near both counts for both).
function read.basketCounts(s)
	local t = autothrow.tune
	local left, right = 0, 0
	local ky = s.lineY + t.basketY
	local near2 = t.basketNear * t.basketNear
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and read.inNow(p) then
			local dy = p.y - ky
			local dl, dr = p.x + t.basketX, p.x - t.basketX
			if dl * dl + dy * dy < near2 then left = left + 1 end
			if dr * dr + dy * dy < near2 then right = right + 1 end
		end
	end
	return left, right
end

-- The lying field kubbs of the far half within basketNear of (bx, by): how many, and
-- the middle of them (nil, nil when there are none).
function read.lyingNear(s, bx, by)
	local near2 = autothrow.tune.basketNear
	near2 = near2 * near2
	local n, cx, cy = 0, 0, 0
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and p.toppled and read.inNow(p) then
			local dx, dy = p.x - bx, p.y - by
			if dx * dx + dy * dy < near2 then n, cx, cy = n + 1, cx + p.x, cy + p.y end
		end
	end
	if n == 0 then return 0, nil, nil end
	return n, cx / n, cy / n
end

-- The innermost lying field kubb by basket `side`: of those within basketNear of it,
-- the one nearest the middle of the pitch (the first in s.pieces on a tie). nil when
-- none lies there.
function read.innermostLying(s, side)
	local t = autothrow.tune
	local bx, by = side * t.basketX, s.lineY + t.basketY
	local near2 = t.basketNear * t.basketNear
	local best
	for _, p in ipairs(s.pieces) do
		if p.role == "field" and p.half ~= s.side and p.toppled and read.inNow(p) then
			local dx, dy = p.x - bx, p.y - by
			if dx * dx + dy * dy < near2 and (not best or side * p.x < side * best.x) then best = p end
		end
	end
	return best
end

-- Is (x, y) a spot a drill can be aimed at: on the allowed part of the half, not on a
-- field kubb and with none in the lane it comes down and runs on in (a lying one within
-- shortLying short of it, a standing one within spotShortStanding)? Piece `except` (or
-- nil) is left out.
function read.spotClear(s, x, y, shortLying, except)
	local t = autothrow.tune
	local ax = x < 0 and -x or x
	if ax > t.spotMaxX or y < s.lineY + t.spotMinY then return false end
	for _, p in ipairs(s.pieces) do
		if p ~= except and p.role == "field" and p.half ~= s.side then
			local dx, dy = (p.x - x) / t.spotClearX, (p.y - y) / t.spotClearY
			if dx * dx + dy * dy < 1 then return false end
			local lx, short = p.x - x, y - p.y
			if lx < 0 then lx = -lx end
			if lx < t.spotLane and short > 0
				and short < (p.toppled and shortLying or t.spotShortStanding) then
				return false
			end
		end
	end
	return true
end

-- The setup's pieces by id: one table a throw.
function read.byId(s)
	local pos = {}
	for _, p in ipairs(s.pieces) do pos[p.id] = p end
	return pos
end

-- The lane (2026-11-16): a baton takes two kubbs when one stands behind the other along
-- its flight. For front kubb f, how many standing field kubbs (the targets, f among
-- them) stand within laneHalf across of it and within laneDeep behind it, and the least
-- and greatest x among them. pos is read.byId(s).
function read.lane(s, pos, f)
	local t = autothrow.tune
	local n, lo, hi = 0, f.x, f.x
	for _, id2 in ipairs(s.targets) do
		local p = pos[id2]
		if p and p.role == "field" then
			local dx, dy = p.x - f.x, p.y - f.y
			if dx < t.laneHalf and dx > -t.laneHalf and dy >= 0 and dy <= t.laneDeep then
				n = n + 1
				if p.x < lo then lo = p.x elseif p.x > hi then hi = p.x end
			end
		end
	end
	return n, lo, hi
end

-- field.line (0.12.0): the lane along the true line from a stance (sx, sy) through front
-- kubb f, as a person sees it who has moved along the throwing line (ko-2017-blasting
-- p1.17, p1.18). read.lane looks straight down the pitch; this looks down the line the
-- baton will fly. Of the standing field kubbs (s.targets), those within laneHalf across
-- that line and from level with f to laneDeep beyond it are in the lane (f among them).
-- Returns n, lo and hi (the least and greatest signed offset across the line among
-- them, + to the thrower's right, f's being 0), the range from the stance to f, and
-- whether the stance is no good: a standing field kubb in the lane short of f (more than
-- lineLevel nearer the stance: the baton meets it first, so f is not the front), or the
-- king within lineKing across of the line anywhere from the stance to lineKingPast beyond
-- f (a king toppled before the field is cleared loses the game), or a field kubb in the
-- thrower's own half within lineOwn of the line from just behind the stance on (II.B.11:
-- a baton that touches one is forfeit); and the lane weighed as
-- raise.par weighs it (w: the other kubbs' raising.parPair weights along this line,
-- summed). Makes no tables.
function read.lineLane(s, pos, f, sx, sy)
	local t = autothrow.tune
	local ux, uy = f.x - sx, f.y - sy
	local range = math.sqrt(ux * ux + uy * uy)
	if range < 1e-6 then return 0, 0, 0, range, true, 0 end
	ux, uy = ux / range, uy / range
	local half, deep, level = t.laneHalf, t.laneDeep, t.lineLevel
	local n, lo, hi = 0, 0, 0
	for _, id in ipairs(s.targets) do
		local p = pos[id]
		if p and p.role == "field" then
			local rx, ry = p.x - f.x, p.y - f.y
			local across = rx * uy - ry * ux
			if across < half and across > -half then
				local along = rx * ux + ry * uy
				if along >= -1e-9 and along <= deep then
					n = n + 1
					if across < lo then lo = across elseif across > hi then hi = across end
				elseif along < -level and along > -range then
					return n, lo, hi, range, true, 0
				end
			end
		end
	end
	-- the lane weighed as raise.par weighs a pair (raising.parPair along this line): how
	-- much each other standing kubb within its reach lies behind f, 0 to 1, summed
	local w = 0
	local rt, parPair = tw.raising.tune, tw.raising.parPair
	for _, id in ipairs(s.targets) do
		local p = pos[id]
		if p and p ~= f and p.role == "field" then
			local rx, ry = p.x - f.x, p.y - f.y
			if rx * ux + ry * uy >= -level then w = w + parPair(f.x, f.y, p.x, p.y, ux, uy, rt) end
		end
	end
	for _, p in ipairs(s.pieces) do
		local rx, ry = p.x - f.x, p.y - f.y
		local across = rx * uy - ry * ux
		local along = rx * ux + ry * uy
		if p.role == "king" then
			if across < t.lineKing and across > -t.lineKing and along > -range and along < t.lineKingPast then
				return n, lo, hi, range, true, w
			end
		elseif p.role == "field" and p.half == s.side then
			-- a field kubb in the thrower's own half (left by the other team: the advantage
			-- line stands on the nearest of them): a baton that touches it is forfeit
			-- (II.B.11), and from a stance beside one it starts out over it
			if across < t.lineOwn and across > -t.lineOwn and along > -range - t.lineOwn then
				return n, lo, hi, range, true, w
			end
		end
	end
	return n, lo, hi, range, false, w
end

tw.read = read

import "core/autothrow"
autothrow = tw.autothrow
