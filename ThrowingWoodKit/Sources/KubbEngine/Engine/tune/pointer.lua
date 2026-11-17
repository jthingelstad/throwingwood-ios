-- The pointer tune: a mouse or a finger on the web's dial (docs/SESSION.md
-- "Tunables"). Pure Lua. core/ is never edited for a client: a host changes how
-- the game plays by setting the core's own tune tables, once, at start-up
-- (tune.apply, run by session.useTune "pointer", which the host asks for
-- through the API's useTune call). It also holds the session's dial and throw
-- tables (read by session/throw). Every value here says what it was on the
-- Playdate and why the web's differs. They are a first fit from what a
-- pointer physically does; Jamie tunes them by play, here and only here.
--
-- What a pointer does (measured in browsers, not on a crank):
--   * frames are 1/60 s (the Playdate aims at 50 fps and its flick frames
--     came at about 41 ms on the device);
--   * a mouse or finger sweep round a dial reaches 1500 to 2500 deg/s in a
--     quick flick and 600 to 1000 deg/s in an easy one (a crank flick is
--     about 1000);
--   * pointer events are coalesced to one per frame, so a steady drag still
--     gives uneven per-frame steps (two events' worth one frame, one the
--     next): the per-frame speed is noisier than its average.
import "core/tw"
import "core/swing"
import "core/autothrow"
import "core/throwplan"

local swing, autothrow = tw.swing, tw.autothrow

local tune = {}

-- core/swing (the clock throw). Unlisted fields keep the core's value:
-- forwardSign (the sign only converts the pointer's angle; see session),
-- startBackDeg 30 (the dead zone from 6 to 7 o'clock: the same face on the
-- dial), backswingMaxDeg 200, skyDeg 180, cooldownS 0.3.
tune.swing = {
	-- Core 200. A pointer let down by hand is still quick (300 to 400 deg/s
	-- when it drifts back to 6), so the forward speed that starts the flick
	-- is higher, or every let-down would be a weak throw.
	swingStartDps = 300,
	-- Core 2 frames (about 80 ms on the device). At 60 fps two frames are
	-- 33 ms, and one coalesced empty pointer frame would read as a stop:
	-- three frames (50 ms) average it out.
	speedWindow = 3,
	-- Core 150 (3 degrees a 20 ms frame). Kept: 2.5 degrees a 1/60 s frame,
	-- well above a held pointer's jitter on a dial 200 px across and well
	-- below any real swing.
	releaseStopDps = 150,
	-- Core 1000. The flick speed for all of the backswing's power: a pointer
	-- flicks faster than a crank. First fit 1500; measured 2026-11-15 by
	-- scripted sweeps in the browser (docs/CLIENT.md "Swing feel"): at 1500
	-- an even 1000 deg/s sweep was SLOW and fell short and only 1400 and up
	-- read ON, so a comfortable flick lost its power. 1200 puts ON at about
	-- a 1100 deg/s sweep (210 degrees in a fifth of a second).
	fullFlickDps = 1200,
	-- Core 2 frames: "still speeding up into the stop" over the last 2
	-- frames of about 41 ms. Three 1/60 s frames are the same 50 ms or so.
	pullFrames = 3,
	-- Core 3.0. The roughness for smoothness 0. Coalesced pointer events
	-- make an honest drag look rougher frame to frame than a crank does, so
	-- only a clearly stuttered swing should cost steadiness: 4.0.
	roughFull = 4.0,
	-- Core 512 (10 s at 50 fps). 600 is 10 s at 60 fps.
	maxSamples = 600,
}

-- The web dial's own values (not core tables; read by session/throw).
tune.dial = {
	-- A press on the dial within this many degrees behind 6 o'clock (inside
	-- the dead zone) counts as starting at the bottom: the crank has to cross
	-- 6 going back to arm, and a finger put down at 6:30 has not crossed it.
	-- 0 turns it off (then the press must start at or ahead of 6).
	pressArmDeg = 30,
	-- Seconds of stopped frames fed to core/swing after a pointer-up while
	-- swinging forward (the release): far more than speedWindow frames needs.
	upFeedS = 0.25,
	-- The frame time the stopped frames are fed at.
	upFeedDt = 1 / 60,
}

-- The recording and the cameras (session/throw; scenes/throw.lua's tune on
-- the Playdate).
tune.throw = {
	-- s of simulated time between recorded poses. The Playdate records at
	-- its refresh rate (1/50); the web plays at 60 fps, so 1/60 gives a
	-- recorded pose for every displayed frame at real-time speed.
	frameDt = 1 / 60,
	-- s of real time per step of the impact camera's slew toward the hit
	-- (focusSpeed m/s, the Playdate's): the playback camera integrates it
	-- in these fixed steps so it is a function of shown time alone.
	slewDt = 1 / 60,
	-- m above a toppled piece's centre for its burst's anchor (render/burst's
	-- tune.lift on the Playdate; not a core table, so copied here).
	burstLift = 0.12,
	-- s the computer's aim shows before its arm starts (the match scene's
	-- cpuThink on the Playdate: 0.9).
	cpuThink = 0.9,
	-- times core/autothrow's scatter for the computer (cpuScatter: 1.0).
	cpuScatter = 1.0,
	-- decimals kept in the recording's poses: 0.01 mm and 1e-5 of a unit
	-- quaternion (far below a pixel). Every browser rounds the same.
	poseDecimals = 5,
}

-- Put the web's values into the core's tune tables. Idempotent: the
-- computer's flick speeds (core/autothrow, calibrated against the core's
-- swingStartDps..fullFlickDps) are mapped onto the web's range so that each
-- computer flick gives the same flickFrac, so the computer throws exactly
-- as it does on the Playdate.
local applied = false
function tune.apply()
	if applied then return end
	applied = true
	local st = swing.tune
	local s0, f0 = st.swingStartDps, st.fullFlickDps
	for k, v in pairs(tune.swing) do st[k] = v end
	local s1, f1 = st.swingStartDps, st.fullFlickDps
	local function map(d) return s1 + (d - s0) * (f1 - s1) / (f0 - s0) end
	local at = autothrow.tune
	at.flickDps = { map(at.flickDps[1]), map(at.flickDps[2]) }
	at.softDps = { map(at.softDps[1]), map(at.softDps[2]) }
end

tw.tune = tw.tune or {}
tw.tune.pointer = tune
