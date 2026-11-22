-- HOW TO THROW, the walkthrough of the clock throw (DESIGN 4). Jamie,
-- 2026-11-14, of the first one: "an interactive thing that walks the player
-- through the different steps and meaning of the crank for the throw"; the
-- clock throw replaced that one (2026-11-15) and this is it again for the new
-- throw. Pure: no playdate.*. The throw scene runs it over the practice pitch
-- (scenes/throw: throw.showHowTo), so every step is the real thing: the real
-- crank, the real dial, real throws at the far base kubbs.
--
-- Each step says what to do; when the player has done it, the step says what
-- it meant (the "after" lines, with the throw's verdicts after a throw) and A
-- goes on. A quick tap of B (no d-pad while it was down) skips a step; the
-- last step's A or B tap ends it.
--
--   steps   clock   the crank to the bottom (6 o'clock)
--           throw   point and throw: any throw (the verdicts explained)
--           power   how far back is how far: a throw with the power ON, or
--                   tune.tries throws
--           arc     where it stops is the arc: a throw with the release ON,
--                   or tune.tries throws
--           circle  the d-pad moves the circle: moved circleMove from where
--                   it was when the step began
--           walk    A + d-pad walks: moved walkMove
--           plan    B + up/down the arc, B + left/right tilt or spin: both
--           done    A: play
--
--   howto.new()            a walkthrough at its first step
--   howto.update(h, o)     one aiming frame; "close" when it ends. o is an
--                          observation the scene fills each frame (reused):
--     arm        the crank as the arm (swing.armAngle: 0 = 6 o'clock), or nil
--     docked     the crank is docked
--     thrown     a throw of the player's has just come back to aiming
--     powerV, releaseV, steady   that throw's verdicts (plan.launch)
--     markerX, markerY, playerX, playerY, release, tilt, spin   the aim
--     pressA     A pressed this frame
--     tapB       B tapped (released this frame, quick, no d-pad meanwhile)
--   howto.lines(h)         title, three lines and the footer to show now
--   h.rev                  bumped whenever what howto.lines says changes
import "core/tw"

local howto = {}

howto.tune = {
	bottomDeg = 20,    -- the crank counts as at 6 o'clock within this of the bottom
	tries = 3,         -- throws before the power and arc steps go on without an ON
	circleMove = 0.3,  -- m the circle must move in the circle step
	walkMove = 0.5,    -- m the thrower must walk in the walk step
}

-- What each step says: a title, the lines while it is to be done, and the
-- lines once it is done ("after"; for the power and arc steps "afterOn" when
-- the throw was ON, "after" when the tries ran out). Three lines at most,
-- each short enough for the panel. A throw step keeps its third line free
-- for the last throw's verdicts (render/howto; test_howto checks the
-- length, the howto self-test the width in the label font).
local STEPS = {
	{ id = "clock", title = "1  THE CRANK IS YOUR ARM",
		say = { "READ IT AS A CLOCK: 6 IS YOUR ARM HANGING DOWN.",
			"TURN THE CRANK DOWN TO 6 O'CLOCK." },
		after = { "THE DIAL BOTTOM RIGHT IS YOUR CRANK. WIND BACK",
			"UP THE LEFT FOR POWER, FLICK UP THE RIGHT AND",
			"WHERE YOU STOP IS WHERE YOU LET GO." } },
	{ id = "throw", title = "2  POINT AND THROW",
		say = { "THE CIRCLE IS ON A KUBB. WIND BACK INTO THE LEFT",
			"MARK, THEN FLICK FORWARD FAST AND STOP AT 3." },
		after = { "POWER: SHORT, ON OR LONG. SLOW: FLICK FASTER.",
			"RELEASE: LOW, ON OR HIGH. STEADY OR SHAKY." } },
	{ id = "power", title = "3  HOW FAR BACK IS HOW FAR",
		say = { "9 O'CLOCK IS ABOUT 4 M, 10 O'CLOCK 8 M, PAST 11 IS",
			"OVERPOWERED. WIND UNTIL THE DIAL SAYS FLICK!" },
		afterOn = { "POWER ON. THE LEFT MARK IS THE POWER THIS THROW",
			"NEEDS: IT MOVES WITH THE DISTANCE." },
		after = { "THE LEFT MARK IS THE POWER THIS THROW NEEDS: IT",
			"MOVES WITH THE DISTANCE. THE DRILLS TEACH IT." } },
	{ id = "arc", title = "4  WHERE YOU STOP IS THE ARC",
		say = { "STOP AT 5 O'CLOCK FOR LOW, 4 FOR FIELD KUBBS,",
			"3 FOR BASE KUBBS, HALF PAST 3 FOR THE KING." },
		afterOn = { "RELEASE ON. STOP EARLY AND IT FLIES LOW, LATE",
			"AND IT FLIES HIGH." },
		after = { "STOP EARLY AND IT FLIES LOW, LATE AND IT FLIES",
			"HIGH. THE RIGHT-HAND MARK IS WHERE TO STOP." } },
	{ id = "circle", title = "5  THE D-PAD AIMS",
		say = { "THE D-PAD MOVES THE CIRCLE, WHERE A CLEAN THROW",
			"COMES DOWN. MOVE IT OFF THE KUBB." },
		after = { "IT STAYS WHERE YOU LEAVE IT: IN A WIND, AIM",
			"INTO IT. THE MARKS ON THE DIAL MOVE WITH IT." } },
	{ id = "walk", title = "6  HOLD A TO WALK",
		say = { "HOLD A AND USE THE D-PAD: ALONG THE LINE, OR",
			"DOWN TO STEP BACK. YOU ALWAYS FACE THE CIRCLE." },
		after = { "IN A MATCH, UP WALKS TO THE ADVANTAGE LINE",
			"WHEN THERE IS ONE." } },
	{ id = "plan", title = "7  HOLD B TO PLAN",
		say = { "HOLD B: UP AND DOWN MOVE THE ARC, AND THE CAMERA",
			"SWINGS OUT TO SHOW IT. LEFT AND RIGHT TILT A",
			"BATON, OR SPIN A DRILLED KUBB." },
		after = { "TILT STEERS A BATON THROUGH A GROUP. SPIN KEEPS",
			"A DRILLED KUBB STEADY IN THE AIR." },
		-- one line kept on screen while B holds the camera out (the panel folds
		-- to a strip then; the RC review of 2026-11-15: its words went with it)
		held = "B HELD: UP/DOWN THE ARC, LEFT/RIGHT TILT OR SPIN" },
	{ id = "done", title = "THAT'S THE THROW",
		say = { "A AND B ARE EXTRAS: POINT AND THROW IS ENOUGH.",
			"THE DRILLS ARE WHERE YOU GET GOOD." } },
}
howto.STEPS = STEPS

local POWER = { [-2] = "SLOW", [-1] = "SHORT", [0] = "ON", [1] = "LONG" }
local RELEASE = { [-1] = "LOW", [0] = "ON", [1] = "HIGH" }

function howto.new()
	return {
		step = 1, phase = "do", tries = 0, on = false, rev = 1,
		started = false,
		x0 = 0, y0 = 0, px0 = 0, py0 = 0, rel0 = 0,   -- the aim when the step began
		powerV = nil, releaseV = nil, steady = nil,     -- the last throw's verdicts
	}
end

-- The aim as the step begins (what the circle, walk and plan steps measure from).
local function snapshot(h, o)
	h.x0, h.y0 = o.markerX or 0, o.markerY or 0
	h.px0, h.py0 = o.playerX or 0, o.playerY or 0
	h.rel0 = o.release or 0
end

local function nextStep(h, o)
	if h.step >= #STEPS then return "close" end
	h.step, h.phase, h.tries, h.on = h.step + 1, "do", 0, false
	h.powerV, h.releaseV, h.steady = nil, nil, nil
	h.rev = h.rev + 1
	snapshot(h, o)
	return nil
end

local function moved(ax, ay, bx, by, d)
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy >= d * d
end

-- Has the player done step `id` this frame?
local function passed(h, id, o)
	local t = howto.tune
	if id == "clock" then
		local a = o.arm
		return a ~= nil and not o.docked and a >= -t.bottomDeg and a <= t.bottomDeg
	elseif id == "throw" then
		return o.thrown
	elseif id == "power" then
		return o.thrown and (o.powerV == 0 or h.tries >= t.tries)
	elseif id == "arc" then
		return o.thrown and (o.releaseV == 0 or h.tries >= t.tries)
	elseif id == "circle" then
		return moved(o.markerX or 0, o.markerY or 0, h.x0, h.y0, t.circleMove)
	elseif id == "walk" then
		return moved(o.playerX or 0, o.playerY or 0, h.px0, h.py0, t.walkMove)
	elseif id == "plan" then
		return (o.release or 0) ~= h.rel0 and ((o.tilt or 0) ~= 0 or (o.spin or 0) ~= 0)
	end
	return false
end

function howto.update(h, o)
	if not h.started then
		snapshot(h, o)
		h.started = true
	end
	local st = STEPS[h.step]
	if st.id == "done" then
		if o.pressA or o.tapB then return "close" end
		return nil
	end
	if o.tapB then return nextStep(h, o) end
	if h.phase == "after" then
		if o.pressA then return nextStep(h, o) end
		return nil
	end
	if o.thrown then
		h.tries = h.tries + 1
		h.powerV, h.releaseV, h.steady = o.powerV, o.releaseV, o.steady
		h.rev = h.rev + 1
	end
	if passed(h, st.id, o) then
		h.phase = "after"
		h.on = (st.id == "power" and o.powerV == 0) or (st.id == "arc" and o.releaseV == 0)
		h.rev = h.rev + 1
	end
	return nil
end

-- The last throw's verdicts as one line ("THAT ONE: ON  HIGH  STEADY"), or nil.
function howto.verdictLine(h)
	if h.powerV == nil then return nil end
	return "THAT ONE: " .. (POWER[h.powerV] or "?") .. "  " .. (RELEASE[h.releaseV] or "?") .. "  "
		.. (h.steady and "STEADY" or "SHAKY")
end

-- What to show now: the title, three lines (nil for none) and the footer.
-- Strings only (render/howto draws them, once per h.rev).
-- The step's one line for the folded panel while B holds the camera out
-- (nil: the title strip alone).
function howto.heldLine(h)
	return STEPS[h.step].held
end

function howto.lines(h)
	local st = STEPS[h.step]
	local L
	if h.phase == "after" then
		L = (h.on and st.afterOn) or st.after
	else
		L = st.say
	end
	local a, b, c = L[1], L[2], L[3]
	-- after a throw step, the throw's own verdicts come first
	local v = (h.phase == "after" or h.tries > 0) and howto.verdictLine(h) or nil
	if v and (st.id == "throw" or st.id == "power" or st.id == "arc") then
		if h.phase == "after" then
			a, b, c = v, L[1], L[2]
		elseif not c then
			c = v
		end
	end
	local foot
	if st.id == "done" then
		foot = "A: PLAY"
	elseif h.phase == "after" then
		foot = "A: NEXT"
	else
		foot = "TAP B: SKIP"
	end
	return st.title, a, b, c, foot
end

tw.howto = howto
