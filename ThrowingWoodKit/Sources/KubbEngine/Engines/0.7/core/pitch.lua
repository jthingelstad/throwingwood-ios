-- Pitch constants and half/bounds tests (DESIGN.md section 2, Rules V4.0 I.B).
-- Pure Lua: no playdate.*. World meters: x across (-2.5 to 2.5), y downfield
-- (0 = Team A's baseline, 8 = Team B's), centerline at y = 4.
import "core/tw"

local floor, abs = math.floor, math.abs

local pitch = {
	halfWidth = 2.5,        -- sidelines at x = -2.5 and 2.5
	length = 8,
	center = 4,             -- centerline y
	kubbLong = 0.15,        -- kubb 7 x 7 x 15 cm
	kubbSide = 0.07,
	kingSide = 0.09,        -- king 9 x 9 x 30 cm
	batonLength = 0.30,     -- punishment kubbs keep one baton length from king and stakes
	stakeRadius = 0.0095,   -- m: a 3/4 inch stake (Jamie, 2026-11-14); a small circle for obstruction
	baseline = { A = 0, B = 8 },
	-- Six stakes: the four corners and the two ends of the centerline.
	stakes = {
		{ x = -2.5, y = 0 }, { x = 2.5, y = 0 },
		{ x = -2.5, y = 4 }, { x = 2.5, y = 4 },
		{ x = -2.5, y = 8 }, { x = 2.5, y = 8 },
	},
	-- Base kubb x positions on each baseline (as drawn in stage 1).
	baseX = { -2, -1, 0, 1, 2 },
	king = { x = 0, y = 4 },
}

function pitch.other(side)
	return side == "A" and "B" or "A"
end

-- Is the point (a piece's center) inside `side`'s half? Lines count as in
-- (a center on the line is 50% in, which is in: II.C.6).
function pitch.inHalf(side, x, y)
	if abs(x) > pitch.halfWidth then return false end
	if side == "A" then return y >= 0 and y <= pitch.center end
	return y >= pitch.center and y <= pitch.length
end

-- Is the point on the pitch at all (either half)?
function pitch.onPitch(x, y)
	return abs(x) <= pitch.halfWidth and y >= 0 and y <= pitch.length
end

-- Distance of y from `side`'s own baseline.
function pitch.fromBaseline(side, y)
	return abs(y - pitch.baseline[side])
end

-- The `nA` number: whole meters from the attacker's own baseline, rounded
-- down, 0 to 4 (DESIGN.md section 7).
function pitch.advantageMeters(side, lineY)
	local m = floor(pitch.fromBaseline(side, lineY) + 1e-9)
	if m < 0 then m = 0 elseif m > 4 then m = 4 end
	return m
end

tw.pitch = pitch
