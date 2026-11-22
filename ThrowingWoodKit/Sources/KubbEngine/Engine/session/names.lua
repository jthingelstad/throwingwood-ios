-- Generated names behind the session's door (docs/SESSION.md "Names", docs/NAMES.md):
-- kubbCall("names.<name>", argsJson) -> resultJson, for the web and the iPhone. Pure like
-- the core: the client passes a seed, and every draw comes from the engine's own seeded
-- stream (plan.rng), so the same seed gives the same name on every client.
--
--   names.roll    { kind, seed, keep? }          -> { text, parts }
--   names.step    { kind, parts, slot, dir? }    -> { text, parts, moved }
--   names.choices { kind, parts, slot }          -> { words }
--   names.make    { kind, parts }                -> { text, why }
--   names.valid   { kind, text }                 -> { ok, parts, default }
--   names.words   {}                             -> { version, hash, rules, max, lists, shapes, never, defaults }
--   names.all     { kind }                       -> { names }
--
-- parts is { shape, words = [word, ...] }: the shape's id (namegen.shapes) and a word per
-- slot, in order. slot is 0-based (a JSON array's index). A kind that is not "player" or
-- "team", a shape the kind does not have, a slot out of range or a seed that is not an
-- integer is an error ({"error": "..."}, as for every session call); a name that cannot be
-- made is not: its text comes back null.
--
-- Needs no session, tune or match: a client may call these before or without `new`.
import "core/tw"
import "core/namegen"
import "core/namewords"
import "core/throwplan"
import "session/json"
import "pitch/lobby"

local namegen, words, plan, json, lobby = tw.namegen, tw.namewords, tw.plan, tw.web.json, tw.shared.lobby
local object, NULL = json.object, json.null

local names = {}

-- A refused argument, as {"error": "names.<call>: ..."} with no file and line in it.
local function check(ok, why)
	if not ok then error(why, 0) end
	return ok
end

-- The rules a name is checked by beyond its words, as a number: namegen.parse and
-- namegen.make's exact spacing, the length (max), the never pairs and a word that begins
-- with the one before it ("Pine Pinecones"). Bump it with any change to those rules, so a
-- check written outside Lua from names.words can tell it is out of date. The words
-- themselves are namewords.version.
names.RULES = 1

local LISTS = { "adjectives", "woods", "teams" }

-- The names the engine itself gives when there is no name: the computer's side and its
-- player, a side with no name ("Team A"), a player with none ("Player n", n up to the
-- pitch's TEAM_MAX). Not generated, but made by the engine and never typed, so a
-- boundary takes them (docs/NAMES.md section 6) as well as generated names.
local function defaultNames()
	local out = { "Computer", "Team A", "Team B" }
	for i = 1, lobby.TEAM_MAX do out[#out + 1] = "Player " .. i end
	return out
end
local DEFAULTS = defaultNames()
local isDefault = {}
for _, s in ipairs(DEFAULTS) do isDefault[s] = true end

local function kindOf(call, a)
	local k = a.kind
	check(k == "player" or k == "team", call .. ": kind is \"player\" or \"team\"")
	return k
end

local function shapeOf(kind, id)
	for _, s in ipairs(namegen.shapes(kind)) do
		if s.id == id then return s end
	end
end

local function setOf(list)
	local s = {}
	for _, w in ipairs(words[list]) do s[w] = true end
	return s
end
local SETS = {}
for _, list in ipairs(LISTS) do SETS[list] = setOf(list) end

-- JSON parts { shape, words = [...] } -> namegen's { shape = id, [i] = word }. Words that are
-- not strings are left out (an open slot).
local function partsIn(call, kind, p, need)
	check(type(p) == "table", call .. ": parts is { shape, words }")
	local shape = shapeOf(kind, p.shape)
	check(shape, call .. ": " .. kind .. " has no shape " .. tostring(p.shape))
	local ws = p.words
	check(ws == nil or type(ws) == "table", call .. ": parts.words is a list")
	local out = { shape = shape.id }
	for i = 1, #shape.slots do
		local w = ws and ws[i]
		if type(w) == "string" then out[i] = w end
		if need then check(out[i], call .. ": parts.words needs a word for each of the shape's " .. #shape.slots .. " slots") end
	end
	return out, shape
end

local function partsOut(kind, p)
	local shape = shapeOf(kind, p.shape)
	local ws = {}
	for i = 1, #shape.slots do ws[i] = p[i] end
	return object { shape = p.shape, words = ws }
end

-- 0-based slot -> 1-based index into the shape's slots.
local function slotOf(call, shape, a)
	local s = a.slot
	check(math.type(s) == "integer" or (type(s) == "number" and s == math.floor(s)), call .. ": slot is a whole number")
	s = math.tointeger(s)
	check(s >= 0 and s < #shape.slots, call .. ": slot " .. s .. " is not one of the shape's 0 to " .. (#shape.slots - 1))
	return s + 1
end

-- The client's seed as plan.rng's stream, and namegen's draw from it: rand(n) is 1..n.
local function draw(call, seed)
	check(type(seed) == "number" and seed == math.floor(seed) and math.abs(seed) < 2 ^ 53,
		call .. ": seed is a whole number")
	local r = plan.rng(seed)
	return function(n)
		local k = math.floor(r.next() * n) + 1
		if k > n then k = n end
		return k
	end
end

-- FNV-1a 32 of a text, 8 hex digits (session.fnv, the snapshot's hash).
local function fnv(text)
	local h = 0x811c9dc5
	for i = 1, #text do h = ((h ~ text:byte(i)) * 0x01000193) & 0xffffffff end
	return string.format("%08x", h)
end

local R = {}

-- A name from the client's seed. keep = { shape, words = [word | null, ...] }: the locked
-- slots (a lock keeps the shape too; keep = { shape } alone picks the shape and draws every
-- word). A kept word that is not in its slot's list, a word taken out for safety or a
-- typo, is drawn again like an open slot. { text, parts }, or text and parts null when the
-- kept words leave no name (which a name the engine made never does).
function R.roll(a)
	local kind = kindOf("names.roll", a)
	local rand = draw("names.roll", a.seed)
	local keep
	if a.keep ~= nil then
		local shape
		keep, shape = partsIn("names.roll", kind, a.keep)
		for i, list in ipairs(shape.slots) do
			if keep[i] and not SETS[list][keep[i]] then keep[i] = nil end
		end
	end
	local text, parts = namegen.roll(kind, rand, keep)
	if not text then return object { text = NULL, parts = NULL } end
	return object { text = text, parts = partsOut(kind, parts) }
end

-- The next word in one slot that makes a name with the others (dir 1, the default, or
-- -1), round the list: a picker's arrows or a crank. { text, parts, moved }; moved is
-- false, with the parts as they came, when no other word fits.
function R.step(a)
	local kind = kindOf("names.step", a)
	local parts, shape = partsIn("names.step", kind, a.parts, true)
	local i = slotOf("names.step", shape, a)
	local dir = a.dir
	check(dir == nil or dir == 1 or dir == -1, "names.step: dir is 1 or -1")
	local text, next = namegen.step(kind, parts, i, dir or 1)
	if not text then
		local same = namegen.make(kind, parts)
		return object { text = same or NULL, parts = partsOut(kind, parts), moved = false }
	end
	return object { text = text, parts = partsOut(kind, next), moved = true }
end

-- Every word slot `slot` can take with the other slots as they are, in the list's order
-- (step's order): what a wheel or a list picker offers. { words }.
function R.choices(a)
	local kind = kindOf("names.choices", a)
	local parts, shape = partsIn("names.choices", kind, a.parts)
	local i = slotOf("names.choices", shape, a)
	for j = 1, #shape.slots do
		check(j == i or parts[j], "names.choices: parts.words needs a word for every other slot")
	end
	local out = {}
	for _, w in ipairs(words[shape.slots[i]]) do
		parts[i] = w
		if namegen.make(kind, parts) then out[#out + 1] = w end
	end
	return object { words = out }
end

-- The text for parts, or text null and why: "word" (a word not in its slot's list, or
-- missing), "long", "never" or "repeat" (namegen.make). { text, why }.
function R.make(a)
	local kind = kindOf("names.make", a)
	local parts = partsIn("names.make", kind, a.parts)
	local text, why = namegen.make(kind, parts)
	return object { text = text or NULL, why = why or NULL }
end

-- Is `text` a generated name of this kind? { ok, parts, default }: ok and its parts when it
-- is (namegen.valid, exactly); default when it is one of the engine's own names for no name
-- ("Computer", "Team A", "Player 2"; names.words' defaults), which a boundary also takes.
-- A client deciding whether its own kept name is still good reads `ok` alone.
function R.valid(a)
	local kind = kindOf("names.valid", a)
	local parts = namegen.parse(kind, a.text)
	return object {
		ok = parts ~= nil,
		parts = parts and partsOut(kind, parts) or NULL,
		default = type(a.text) == "string" and isDefault[a.text] == true,
	}
end

-- Everything a check outside Lua needs to give valid's answer (docs/NAMES.md section 6),
-- built once: the lists, the shapes, the never pairs, the length, the rules number, the
-- defaults, and `hash`, FNV-1a 32 (8 hex digits) of the canonical JSON of every other
-- field (keys sorted, no spaces: the engine's encoder, or JSON.stringify of the keys in
-- sorted order), so two ends compare one string to know they hold the same words.
local WORDS
function R.words()
	if WORDS then return WORDS end
	local lists = object {}
	for _, list in ipairs(LISTS) do lists[list] = { table.unpack(words[list]) } end
	local shapes = object {}
	for _, kind in ipairs(namegen.KINDS) do
		local out = {}
		for i, s in ipairs(namegen.shapes(kind)) do
			out[i] = object { id = s.id, prefix = s.prefix or NULL, slots = { table.unpack(s.slots) } }
		end
		shapes[kind] = out
	end
	local w = object {
		version = words.version,
		rules = names.RULES,
		max = object { player = namegen.max.player, team = namegen.max.team },
		lists = lists,
		shapes = shapes,
		never = { table.unpack(words.never) },
		defaults = { table.unpack(DEFAULTS) },
	}
	w.hash = fnv(json.encode(w))
	WORDS = w
	return w
end

-- Every name of a kind, sorted (namegen.all): for a client measuring its widest name in its
-- own font, at build time or once, not on every screen. { names }.
local ALL = {}
function R.all(a)
	local kind = kindOf("names.all", a)
	ALL[kind] = ALL[kind] or object { names = namegen.all(kind) }
	return ALL[kind]
end

names.calls = R

-- One call: its name (without "names."), its argument text. Returns the result text.
function names.call(name, argText)
	local f = R[name]
	if not f then error("unknown call names." .. tostring(name), 0) end
	local a = (argText and argText ~= "") and json.decode(argText) or {}
	if type(a) ~= "table" then error("names." .. name .. ": the argument is not an object", 0) end
	return json.encode(f(a))
end

tw.web.names = names
