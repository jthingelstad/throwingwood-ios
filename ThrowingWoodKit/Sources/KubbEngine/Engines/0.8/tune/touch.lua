-- A finger on the pendulum. Both host tunes use the same physics and CPU
-- calibration, so the dial and the swipe can share a match and a Lua state.
import "tune/pointer"
local pointer = tw.tune.pointer
tw.tune.touch = {
	apply = pointer.apply, dial = pointer.dial, throw = pointer.throw,
	hz = 120,             -- fixed crank samples per second, independent of the display
	degrees = 600,        -- one short screen edge; a fifth of it winds to 10 o'clock
	sideWeight = 0.5,     -- sideways excursions take up travel in the stroke
	precision = 1024,     -- subdivisions of a degree; identical interpolants round alike
	maxGap = 30,          -- seconds between samples before abandoning a stale contact
}
