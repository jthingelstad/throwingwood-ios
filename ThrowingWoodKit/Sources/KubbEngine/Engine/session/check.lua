-- Checking a shared match's throws (docs/SESSION.md "What a server can prove").
--
--   check.throw(s, action)  could this throw action have come from this session's next
--                           throw as set up now? { ok, why, computer, levels, level }
--   check.same(a, b)        are two actions the same (every field, numbers exactly; the
--                           host's `at` time aside)?
--
-- The computer's throw is made again (Session:cpuAction, on a session restored from the
-- snapshot) and must be the same action. A person's throw cannot be made again: the
-- action keeps the swing's back and stop but not its flick, shake or pull, nor the nerves'
-- draws. So it is held to what the dial could give. Every bound below is worked out from
-- the code that makes the throw (session/throw playerLaunch, core/throwplan plan.launch
-- and plan.solve, core/swing release, core/drill), reading the tune tables as they are:
--
--   the plan     plan.solve again for the stance and the target in the action, with
--                every planned release the plan allows (releaseMinDeg..releaseMaxDeg,
--                continuous: the ARC slider is setArc), every planned tilt (a baton:
--                -tiltMaxDeg..tiltMaxDeg in tiltStepDeg) and every level (plan.LEVELS: a
--                player may change level mid-match, Session:setLevel)
--   loft         exactly loftFor of the release as the level forgives it (the stop is in
--                the action), so the planned release is pinned or bounded by it; a baton
--                planned under flight.tune.nearM keeps the plan's loftShare of it, plus
--                nearOverLoft x the backswing past the power target x nearShare (0.8.0)
--   tilt         the planned tilt plus the shake's tilt (shakeTiltDeg x the shake as it
--                counts), which pins the shake as it counts and the pull's sign
--   shake        that over shakeGain x the overpower multiplier: 0..1, and under
--                steadyBelow exactly when the verdict says steady
--   swivel       the plan's, plus the pull's lateralDeg x the shake, plus a nerves draw
--                of at most ZMAX sds (plan.rng's normal: its u1 never under 1e-12)
--   sideV        the side cell of that angle at the plan's distance (straightM)
--   speed        speedFor(the backswing as forgiven) x a flick of minFlickFrac..1 x
--                sqrt(1 + a length draw of at most ZMAX sds, never under lenMin)
--   powerV       what that flick gives against the power target (the -2 rule too)
--   tumble       a baton's: the plan's rate x the flick, plus at most ZMAX sds of turns
--                over the planned flight, never under tumbleMin. A kubb's is 0
--   kubb         noseDown, spin, wobble and rollLand exactly drill.body's for the shake,
--                the pull, the planned spin (-spinSteps..spinSteps) and the loft
--   swing        back startBackDeg..backswingMaxDeg; stop over 0; a sky ball (stop at or
--                past skyDeg) has releaseV 1, else releaseV is the stop against the window
--   stance       within halfWidth of the middle, backMax behind the line and no further
--                forward than the advantage line (a baton) or the baseline (a kubb); a
--                stance not set is plan.stance's, straight behind the target
--   target       inside drill.clampMarker's area, or on a piece of the pitch (a snap, the
--                nearest target, a kept marker); `on` names a piece standing there
--
-- Touch, the linear meter and STAND need no bounds of their own: they feed the same arm
-- degrees to the same swing (core/swing) and the same setStance.
import "core/tw"
import "core/throwplan"
import "core/flight"
import "core/swing"
import "core/drill"
import "session/json"
import "session/session"
import "session/throw"

local plan, swing, drill, flight = tw.plan, tw.swing, tw.drill, tw.flight
local json, session, throw = tw.web.json, tw.web.session, tw.web.throw

local abs, max, min, sqrt, floor = math.abs, math.max, math.min, math.sqrt, math.floor
local rad, deg, tan, pi, log = math.rad, math.deg, math.tan, math.pi, math.log

local check = {}

-- The largest nerves draw plan.rng's normal can give: sqrt(-2 ln u1) with u1 >= 1e-12.
check.ZMAX = sqrt(-2 * log(1e-12))

local EPS = 1e-9     -- slack at a boundary (a value exactly on an edge, as JSON keeps it)
local TOL = 1e-7     -- an exact value worked out again from a release found by inverting

local function num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- ---------- the same action ----------

local function same(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not same(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

function check.same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if k ~= "at" and not same(v, b[k]) then return false end end
	for k in pairs(b) do if k ~= "at" and a[k] == nil then return false end end
	return true
end

-- The first field where two actions differ ("launch.speed"), for a report.
local function firstDiff(a, b, path)
	if type(a) ~= "table" or type(b) ~= "table" then
		if a ~= b then return path end
		return nil
	end
	local keys = {}
	for k in pairs(a) do keys[#keys + 1] = k end
	for k in pairs(b) do if a[k] == nil then keys[#keys + 1] = k end end
	table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
	for _, k in ipairs(keys) do
		if not (path == nil and k == "at") then
			local d = firstDiff(a[k], b[k], path and (path .. "." .. tostring(k)) or tostring(k))
			if d then return d end
		end
	end
	return nil
end
check.firstDiff = firstDiff

-- ---------- the computer's throw ----------

local NOBODY = { sides = {}, cpu = false }

-- The computer's throw the engine makes from this session's snapshot.
function check.cpuAction(s)
	local c = session.restore(s:snapshot(), NOBODY)
	return c:cpuAction()
end

-- ---------- a person's throw ----------

local function side3(v, lo, hi)
	if v < lo then return -1 end
	if v > hi then return 1 end
	return 0
end

-- Does verdict v fit value x against [lo, hi], allowing a value on an edge either way?
local function sideFits(v, x, lo, hi)
	if side3(x, lo, hi) == v then return true end
	if abs(x - lo) <= EPS * max(1, abs(lo)) and (v == -1 or v == 0) then return true end
	if abs(x - hi) <= EPS * max(1, abs(hi)) and (v == 0 or v == 1) then return true end
	return false
end

-- The smallest flick in [0, 1] whose power (backForSpeed of speedFor(back) x flick)
-- reaches `target` (2 when even a full flick does not).
local function flickFor(back, target)
	local sp = plan.speedFor(back)
	local function got(f) return plan.backForSpeed(sp * f) end
	if got(1) < target then return 2 end
	if got(0) >= target then return 0 end
	local lo, hi = 0, 1
	for _ = 1, 60 do
		local mid = (lo + hi) / 2
		if got(mid) >= target then hi = mid else lo = mid end
	end
	return hi
end

-- The flicks [lo, hi] that give power verdict pv for backswing `back` against sol.
local function flicksForPower(pv, back, sol)
	local fLo, fHi = flickFor(back, sol.powerLo), flickFor(back, sol.powerHi)
	-- got < powerLo below fLo; within [powerLo, powerHi] from fLo to fHi; over powerHi
	-- past fHi (a got exactly on powerHi is still on: side() is strict)
	if pv == 1 then return fHi, 1 end
	if pv == 0 then return fLo, fHi end
	local short = back >= sol.powerLo and -2 or -1
	if pv ~= short then return 1, 0 end
	return 0, fLo
end

local CHECKED = { "speed", "loft", "swivel", "tilt", "tumble" }

-- One plan (level, planned release, planned tilt or spin taps) against the throw, with
-- the plan solved (sol). Returns true, or false, the stage it failed at and why.
local function tryTilt(ctx, levelName, sol, ptilt, taps)
	local t, L, v = plan.tune, ctx.L, ctx.v
	local kubb = ctx.kubb
	local lv = plan.level(levelName)
	local back = ctx.back
	local loft = L.loft
	-- the power as it counts and the overpower
	local effBack = sol.back + plan.shrink(back - sol.back, lv.powerHalf, lv.inGain)
	local past = back - sol.powerHi
	local m = 1 + lv.overGain * (past > 0 and past or 0) / t.overPerDeg
	-- the shake from the tilt
	local d = kubb and L.tilt or (L.tilt - ptilt)
	local se = abs(d) / t.shakeTiltDeg
	local pull = d < 0 and -1 or 1
	local shake = se / (lv.shakeGain * m)
	if shake > 1 + EPS then return false, 3, "the tilt needs more shake than a swing has" end
	local steady = shake < t.steadyBelow
	if steady ~= (v.steady == true) and abs(shake - t.steadyBelow) > EPS then
		return false, 3, "the steady verdict does not fit the shake the tilt shows"
	end
	-- sideways
	local sdSide, sdLen = plan.nervesSd(lv, effBack, shake, m, kubb)
	local sideDeg = deg(L.swivel - sol.swivel)
	local zs = (sideDeg - pull * t.lateralDeg * se) / sdSide
	if abs(zs) > check.ZMAX + EPS then return false, 4, "the swivel is off the line by more than the nerves give" end
	local sideM = tan(rad(sideDeg)) * (sol.dist or 0)
	if not sideFits(v.sideV, sideM, -t.straightM, t.straightM) then
		return false, 4, "the side verdict does not fit the swivel"
	end
	-- a kubb's body
	if kubb then
		local body = drill.body(1 - se, pull, (taps or 0) * t.spinPerStep, {}, loft - (sol.loft or loft))
		if abs(body.noseDown - L.noseDown) > TOL or abs(body.spin - L.spin) > TOL or L.rollLand ~= 0
			or abs(body.wobble - L.wobble) > TOL then
			return false, 5, "the kubb's nose, spin, roll or wobble is not what the drill gives"
		end
	end
	-- the flick: what the power verdict allows, the length's draw and the tumble's
	local lo, hi = swing.tune.minFlickFrac, 1
	local base = plan.speedFor(effBack)
	if base <= 0 then
		if L.speed > EPS then return false, 6, "no power, yet a speed" end
	else
		local ratio = L.speed / base
		local lenLo = max(t.lenMin, -check.ZMAX * sdLen)
		local lenHi = check.ZMAX * sdLen
		lo = max(lo, ratio / sqrt(1 + lenHi))
		hi = min(hi, ratio / sqrt(1 + lenLo))
	end
	if not kubb then
		local rate0, T = sol.tumble, sol.flightT
		local rangeFactor = min(1.5, max(0.5, (sol.dist or 8) / 8))
		local sdT = (lv.tumbleSd or 0) * rangeFactor * (1 + t.roughGain * shake) * m
		local k = (T and T > 0) and sdT * 2 * pi / T or 0
		-- plan.launch clamps every rate to tumbleMin: none is ever under it
		if L.tumble < t.tumbleMin - EPS then return false, 6, "a tumble under the least the throw gives" end
		if rate0 and rate0 > 0 then
			if L.tumble > t.tumbleMin + EPS then
				lo = max(lo, (L.tumble - check.ZMAX * k) / rate0)
				hi = min(hi, (L.tumble + check.ZMAX * k) / rate0)
			else
				hi = min(hi, (t.tumbleMin + check.ZMAX * k) / rate0)
			end
		elseif rate0 == 0 then
			-- no planned rate: the nerves' turns alone, clamped to tumbleMin
			if L.tumble > max(t.tumbleMin, check.ZMAX * k) + EPS then
				return false, 6, "a tumble faster than the nerves give with no planned rate"
			end
		elseif abs(L.tumble - max(t.tumbleMin, 0)) > TOL then
			return false, 6, "a tumble with no planned rate"
		end
	elseif L.tumble ~= 0 then
		return false, 6, "a kubb does not tumble"
	end
	if lo > hi * (1 + EPS) + EPS then return false, 6, "the speed and tumble need a flick the swing cannot give" end
	if not sol.flicks then sol.flicks = { flicksForPower(v.powerV, back, sol) } end
	lo, hi = max(lo, sol.flicks[1]), min(hi, sol.flicks[2])
	if lo > hi * (1 + 1e-6) + 1e-6 then return false, 7, "the power verdict does not fit the speed" end
	return true
end

-- The loft plan.launch gives a baton from the release's loft: a short baton's share of
-- it (sol.loftShare) and its overpower heave (flight.tune.nearOverLoft); a kubb's as is.
local function launchLoft(sol, loft, back, kubb)
	if kubb then return loft end
	if sol.loftShare and sol.loftShare ~= 1 then loft = loft * sol.loftShare end
	local past = back - sol.powerHi
	if past > 0 and sol.nearShare and sol.nearShare > 0 then
		loft = loft + flight.tune.nearOverLoft * past * sol.nearShare
	end
	return loft
end

-- The plan at one level and planned release: solved once, its release verdict and loft
-- checked, then each planned tilt.
local function tryPlan(ctx, levelName, rel, tilts, taps)
	local t, L, v = plan.tune, ctx.L, ctx.v
	local kubb = ctx.kubb
	local q = {
		projectile = kubb and "kubb" or "baton", px = ctx.px, py = ctx.py, tx = ctx.tx, ty = ctx.ty,
		release = rel, level = levelName, surface = ctx.surface, spin = kubb and taps or 0, aimZ = ctx.aimZ,
	}
	local sol = plan.solve(q, {})
	local lv = plan.level(levelName)
	local stop = ctx.stop
	-- the release verdict and the loft
	if ctx.sky then
		if v.releaseV ~= 1 then return false, 1, "a sky ball's release verdict is HIGH" end
	elseif not sideFits(v.releaseV, stop, sol.releaseLo, sol.releaseHi) then
		return false, 1, "the release verdict does not fit the stop"
	end
	local relA = stop
	if ctx.sky then relA = max(stop, 180) + t.skyExtraDeg end
	if relA < 0 then relA = 0 end
	local effRel = sol.release + plan.shrink(relA - sol.release, lv.releaseHalf, lv.inGain)
	if abs(launchLoft(sol, plan.loftFor(effRel), ctx.back, kubb) - L.loft) > TOL then
		return false, 2, "the loft is not one the stop gives"
	end
	local bestStage, bestWhy = 0, nil
	for _, p in ipairs(tilts) do
		local ok, stage, why = tryTilt(ctx, levelName, sol, p, taps)
		if ok then return true end
		if stage > bestStage then bestStage, bestWhy = stage, why end
	end
	return false, bestStage, bestWhy
end

-- The planned releases to try: the one the loft pins when the stop is inside the window
-- (a short baton's: every one whose launch loft is the throw's), the arcs a plan starts
-- on and steps to, and a fine grid for the ARC slider.
local function releases(ctx, levelName)
	local t, lv = plan.tune, plan.level(levelName)
	local out, seen = {}, {}
	local function add(r)
		if r >= t.releaseMinDeg - EPS and r <= t.releaseMaxDeg + EPS then
			r = plan.clampRelease(r)
			if not seen[r] then seen[r] = true; out[#out + 1] = r end
		end
	end
	local L = ctx.L
	local _, _, _, near = flight.handAt(sqrt((ctx.tx - ctx.px) ^ 2 + (ctx.ty - ctx.py) ^ 2))
	if not ctx.kubb and near > 0 then
		-- a baton planned under nearM: its loft (launchLoft) depends on the planned release
		-- through the release's loft and through the power target the heave counts from,
		-- and outside the window only through the latter. Find every release whose loft
		-- is the throw's: a scan on arcStepDeg, then bisection inside each crossing
		local q = { projectile = "baton", px = ctx.px, py = ctx.py, tx = ctx.tx, ty = ctx.ty,
			level = levelName, surface = ctx.surface, spin = 0, aimZ = ctx.aimZ }
		local relA = ctx.stop
		if ctx.sky then relA = max(relA, 180) + t.skyExtraDeg end
		if relA < 0 then relA = 0 end
		local function gap(rel)
			q.release = rel
			local sol = plan.solve(q, {})
			local effRel = sol.release + plan.shrink(relA - sol.release, lv.releaseHalf, lv.inGain)
			return launchLoft(sol, plan.loftFor(effRel), ctx.back, false) - L.loft
		end
		local r0, g0 = t.releaseMinDeg, gap(t.releaseMinDeg)
		local r1 = r0
		while r1 < t.releaseMaxDeg do
			r1 = min(t.releaseMaxDeg, r0 + t.arcStepDeg)
			local g1 = gap(r1)
			if g0 == 0 then add(r0) end
			if (g0 < 0) ~= (g1 < 0) and g0 ~= 0 and g1 ~= 0 then
				local lo, hi, glo = r0, r1, g0
				for _ = 1, 60 do
					local mid = (lo + hi) / 2
					local gm = gap(mid)
					if (gm < 0) == (glo < 0) then lo, glo = mid, gm else hi = mid end
				end
				add(lo); add(hi)
			end
			r0, g0 = r1, g1
		end
		if g0 == 0 then add(r0) end
	elseif not ctx.sky and L.loft > t.loftMinDeg and L.loft < t.loftMaxDeg and lv.inGain < 1 then
		local effRel = plan.releaseFor(L.loft)
		add((effRel - lv.inGain * ctx.stop) / (1 - lv.inGain))
	end
	-- a kubb's nose pins the plan's loft: noseDown is noseDownDeg less the loft over the plan's
	if ctx.kubb and num(L.noseDown) then
		add(plan.releaseFor(L.loft - (drill.tune.noseDownDeg - L.noseDown)))
	end
	for _, r in pairs(t.arc) do add(r) end
	for r = t.releaseMinDeg, t.releaseMaxDeg, t.arcStepDeg do add(r) end
	for r = t.releaseMinDeg, t.releaseMaxDeg, 0.25 do add(r) end
	add(t.releaseMaxDeg)
	return out
end

local function fail(why) return { ok = false, why = why } end

-- A person's throw against the session's set-up (s: in the throw phase, before it).
local function personThrow(s, a)
	local ts, setup = s.ts, s.setup
	local t, tt, st = plan.tune, throw.tune, swing.tune
	if a.scripted then return fail("a scripted throw on a person's side") end
	local kubb = ts.projectile == "kubb"
	if a.how ~= (kubb and "drill" or "baton") then return fail("the throw's kind is not the set-up's") end
	local L, sw, v = a.launch, a.swing, a.verdicts
	if type(L) ~= "table" or type(sw) ~= "table" or type(v) ~= "table" then
		return fail("a person's throw has its launch, swing and verdicts")
	end
	for _, k in ipairs(CHECKED) do
		if not num(L[k]) then return fail("launch." .. k .. " is not a number") end
	end
	if not (num(sw.back) and num(sw.stop)) then return fail("the swing's back and stop are numbers") end
	if not (v.powerV == -2 or v.powerV == -1 or v.powerV == 0 or v.powerV == 1) then return fail("powerV") end
	if not (v.releaseV == -1 or v.releaseV == 0 or v.releaseV == 1) then return fail("releaseV") end
	if not (v.sideV == -1 or v.sideV == 0 or v.sideV == 1) then return fail("sideV") end
	if type(v.steady) ~= "boolean" then return fail("steady") end
	-- legal: a helicopter is a baton tilted past legalTiltDeg; a kubb always counts
	local legal = kubb or abs(L.tilt) <= t.legalTiltDeg
	if (L.legal ~= false) ~= legal then return fail("launch.legal does not fit the tilt") end
	if kubb then
		for _, k in ipairs { "noseDown", "rollLand", "spin", "wobble" } do
			if not num(L[k]) then return fail("a kubb's launch." .. k .. " is not a number") end
		end
	else
		for _, k in ipairs { "noseDown", "rollLand", "spin", "wobble" } do
			if L[k] ~= nil then return fail("a baton has no launch." .. k) end
		end
	end
	-- the swing
	if sw.back < st.startBackDeg - EPS or sw.back > st.backswingMaxDeg + EPS then
		return fail("the backswing is outside what the swing records")
	end
	if not (sw.stop > 0) then return fail("a throw leaves only on a forward swing") end
	-- the stance
	local stance, target = a.stance or {}, a.target or {}
	if not (num(stance.x) and num(stance.y) and num(target.x) and num(target.y)) then
		return fail("the stance and target are numbers")
	end
	local lineY = ts.lineY
	local fwd = throw.forwardLimit(ts)
	if abs(stance.x) > tt.halfWidth + EPS or stance.y < lineY - tt.backMax - EPS or stance.y > fwd + EPS then
		return fail("the stance is off the ground the rules allow")
	end
	if not stance.set then
		local o = plan.stance(target.x, target.y, lineY, fwd, tt.halfWidth, {})
		if abs(o.x - stance.x) > EPS or abs(o.y - stance.y) > EPS then
			return fail("a stance not set stands straight behind the target")
		end
	end
	-- the target
	local dt = drill.tune
	local inArea = abs(target.x) <= dt.markerXMax + EPS and target.y - lineY >= dt.markerNear - EPS
		and target.y - lineY <= dt.markerFar + EPS
	local onPiece = nil
	for _, it in ipairs(ts.items or {}) do
		if abs(it.x - target.x) <= EPS and abs(it.y - target.y) <= EPS then onPiece = it; break end
	end
	if not inArea and not onPiece then return fail("the target is off the pitch") end
	if target.on ~= nil then
		local found = false
		for _, it in ipairs(ts.items or {}) do
			if it.id == target.on and abs(it.x - target.x) <= EPS and abs(it.y - target.y) <= EPS then found = true end
		end
		if not found then return fail("the target names a piece that is not there") end
	end
	-- a baton's aim height: its circle on a standing target (throw replan)
	local aimZ = 0
	if not kubb and ts.snaps then
		local on = plan.snap(target.x, target.y, ts.snaps, #ts.snaps, tt.snapRadius)
		if on then aimZ = plan.aimZFor(on.kind == "king" and "king" or "kubb") end
	end
	local ctx = {
		a = a, L = L, v = v, kubb = kubb, px = stance.x, py = stance.y, tx = target.x, ty = target.y,
		surface = ts.surface, aimZ = aimZ, back = sw.back, stop = sw.stop, sky = sw.stop >= st.skyDeg,
	}
	-- a kubb's planned spin, from its spin
	local tapsList = { 0 }
	if kubb then
		local taps = floor((L.spin - dt.spiral) / t.spinPerStep + 0.5)
		if abs(taps) > t.spinSteps or abs(taps * t.spinPerStep + dt.spiral - L.spin) > TOL then
			return fail("the kubb's spin is not a planned spin")
		end
		tapsList = { taps }
	end
	local tilts = { 0 }
	if not kubb then
		tilts = {}
		for p = -t.tiltMaxDeg, t.tiltMaxDeg, t.tiltStepDeg do tilts[#tilts + 1] = p end
		-- the nearest planned tilt first: the least shake
		table.sort(tilts, function(x, y)
			local dx, dy = abs(L.tilt - x), abs(L.tilt - y)
			if dx ~= dy then return dx < dy end
			return x < y
		end)
	end
	-- every level, the thrower's first
	local own = throw.levelFor(ts)
	if setup and setup.thrower and setup.thrower.level then own = setup.thrower.level end
	if not plan.levels[own] then own = t.defaultLevel end -- plan.level's fallback
	local order = { own }
	for _, l in ipairs(plan.LEVELS) do if l ~= own then order[#order + 1] = l end end
	local fits, bestStage, bestWhy = {}, 0, "no plan fits"
	for _, lname in ipairs(order) do
		local found = false
		for _, rel in ipairs(releases(ctx, lname)) do
			local ok, stage, why = tryPlan(ctx, lname, rel, tilts, tapsList[1])
			if ok then found = true; break end
			if stage > bestStage then bestStage, bestWhy = stage, why end
		end
		if found then fits[#fits + 1] = lname end
	end
	if #fits == 0 then return fail(bestWhy) end
	table.sort(fits)
	local atOwn = false
	for _, l in ipairs(fits) do if l == own then atOwn = true end end
	return { ok = true, levels = fits, level = own, atLevel = atOwn }
end

-- Could `a` be the next throw of session s as it is set up now? Returns { ok, why,
-- computer, levels, level, atLevel }: for the computer's throw ok means the very action
-- it makes (why names the first field that differs); for a person's, levels lists the
-- levels at which the dial could make it (ok when there is one), level is the thrower's
-- and atLevel whether that is among them.
function check.throw(s, a)
	if type(a) ~= "table" or a.type ~= "throw" then return fail("not a throw") end
	if s.kind ~= "match" or s.phase ~= "throw" or not s.setup then return fail("no throw set up") end
	if a.seq == nil or math.tointeger(a.seq) ~= s.throws then return fail("throw out of step") end
	if session.isCpu(s, s.setup.side) then
		local want = check.cpuAction(s)
		if check.same(a, want) then return { ok = true, computer = true } end
		return { ok = false, computer = true, why = "not the computer's throw: " .. tostring(firstDiff(a, want)) }
	end
	local ok, r = pcall(personThrow, s, a)
	if not ok then return fail("not a throw this engine can read: " .. tostring(r)) end
	r.computer = false
	return r
end

tw.web.check = check
