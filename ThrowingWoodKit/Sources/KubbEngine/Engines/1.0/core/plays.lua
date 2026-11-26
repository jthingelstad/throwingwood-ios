-- The plays the computer can carry out (docs/notes/computer-player.md, "A decision"),
-- keyed by the ids in docs/reference/plays/*.md, where each play's sources are. A
-- decision from core/cpu names one in why.play, with its facts in why.facts; `say` is
-- one plain sentence a game can show as it is, its {name}s filled from those facts
-- (cpu.text). `levels` are the levels that use the play today, `phase` the phase of
-- SITUATIONS.md it belongs to.
--
-- It held what 0.11.0 already did and grows one play at a time, by "How a play gets
-- in" (raise.par: 0.12.0). `make refcheck` fails on an id here that is not a play in
-- docs/reference/plays/. A choice that carries out no play there (a baton at the
-- nearest base kubb, the king from the baseline) has no why.play.
import "core/tw"

local plays = {
	["inkast.corner"] = {
		phase = "inkast",
		levels = { "beginner", "club", "pro" },
		say = "Into the {basket} basket: {near} field kubbs by it, {other} by the other.",
	},
	["inkast.roll"] = {
		phase = "inkast",
		levels = { "club", "pro" },
		say = "Laid beside the kubb lying by the {basket} basket, to roll in beside it.",
	},
	["field.roles"] = {
		phase = "field",
		levels = { "beginner", "club", "pro" },
		say = "At the lane with the most kubbs: {lane} in line from the front one.",
	},
	-- core/cpu lineChoice (0.12.0): named only when the stance moved off straight behind
	-- the front kubb; levels: cpu.tune.line
	["field.line"] = {
		phase = "field",
		levels = { "pro" },
		say = "Stood off to the side so {lane} kubbs line up behind the front one.",
	},
	-- core/cpu decideBaton (0.18.0): a person's default line, the drive close in; named
	-- when the arc is a drive at a field kubb; levels: cpu.tune.drive
	["field.drive"] = {
		phase = "field",
		levels = { "club", "pro" },
		say = "Driven low and hard into the field kubb, the way the line throws close in.",
	},
	-- core/cpu depthSpot (0.12.0); levels: cpu.tune.depth
	["inkast.depth"] = {
		phase = "inkast",
		levels = { "pro" },
		say = "Laid one behind another down the baton's path, in the {basket} basket.",
	},
	-- core/cpu.raise (0.12.0); also a person's automatic raising and the end offered
	-- first by hand (cpu.advice), which are not the computer's and give no reason
	["raise.par"] = {
		phase = "raise",
		levels = { "pro" },
		say = "Stood on the end that leaves the batons the fewest kubbs one behind another.",
	},
}

tw.plays = plays
