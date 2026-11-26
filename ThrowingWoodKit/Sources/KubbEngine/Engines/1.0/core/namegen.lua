-- Generated names for players and teams (docs/NAMES.md). Pure: no playdate.*, no
-- math.random. A client passes its own random draw, so the core never picks a seed.
--
-- A name is text made from core/namewords' lists in one of a few shapes:
--   player  "<adjective> <wood>"                  "Mighty Maple"
--   team    "<adjective> <noun>"                  "Wobbly Towers"
--           "The <noun>"                          "The Lumberjacks"
--           "<wood> <noun>"                       "Birch Batons"
-- no longer than namegen.max[kind], not in namewords.never, and with no word that
-- begins with the one before it ("Pine Pinecones"). Nothing else is a name: `valid` is the
-- check every place that shows a name to someone else makes (the pitch, the reel,
-- the share card), so a client that sends free text is shown a default instead.
--
-- Names are stored and sent as their text, never as indices, so adding words never
-- changes a name already held.
import "core/tw"
import "core/namewords"

local words = tw.namewords

local namegen = {}

namegen.KINDS = { "player", "team" }

-- The longest name, in characters (ASCII: every word is letters only). 16 is the
-- pitch's and the reel's limit (docs/PITCH.md cleanName, the share card).
namegen.max = { player = 16, team = 16 }

namegen.tune = {
	alliterate = 0.6, -- a rolled player name tries for one letter first this often
	tries = 40,       -- draws before roll gives up on a name that fits (never in practice)
	-- How often roll draws each shape, in percent. "The <noun>" has few names, so it
	-- comes up less, or a lobby would see the same one twice.
	shapes = { player = { adj = 100 }, team = { adj = 65, wood = 25, the = 10 } },
}

-- Each kind's shapes, in a fixed order. A shape is its slots, each a list name in
-- core/namewords, with literal words between them.
local SHAPES = {
	player = {
		{ id = "adj", slots = { "adjectives", "woods" } },
	},
	team = {
		{ id = "adj", slots = { "adjectives", "teams" } },
		{ id = "the", prefix = "The", slots = { "teams" } },
		{ id = "wood", slots = { "woods", "teams" } },
	},
}

local function shapeOf(kind, id)
	for _, s in ipairs(SHAPES[kind] or {}) do
		if s.id == id then return s end
	end
end

-- Word -> true, per list, built once.
local sets = {}
local function setOf(list)
	if not sets[list] then
		local s = {}
		for _, w in ipairs(words[list]) do s[w] = true end
		sets[list] = s
	end
	return sets[list]
end

-- The shortest word of a list, built once.
local shortestOf = {}
local function shortest(list)
	if not shortestOf[list] then
		local n = math.huge
		for _, w in ipairs(words[list]) do n = math.min(n, #w) end
		shortestOf[list] = n
	end
	return shortestOf[list]
end

-- The shapes of a kind: { { id, prefix?, slots = { listName, ... } }, ... }. Read only.
function namegen.shapes(kind)
	return SHAPES[kind]
end

-- The text for parts { shape = id, a word per slot in order }, or nil and why
-- ("kind", "shape", "word", "long", "never", "repeat").
function namegen.make(kind, parts)
	local shape = shapeOf(kind, parts and parts.shape)
	if not SHAPES[kind] then return nil, "kind" end
	if not shape then return nil, "shape" end
	local out = {}
	if shape.prefix then out[1] = shape.prefix end
	for i, list in ipairs(shape.slots) do
		local w = parts[i]
		if type(w) ~= "string" or not setOf(list)[w] then return nil, "word" end
		out[#out + 1] = w
	end
	local s = table.concat(out, " ")
	if #s > namegen.max[kind] then return nil, "long" end
	if setOf("never")[s] then return nil, "never" end
	for i = 2, #out do
		if out[i]:lower():sub(1, #out[i - 1]) == out[i - 1]:lower() then return nil, "repeat" end
	end
	return s
end

-- The parts of a name, or nil when the text is not a name of this kind. Exact: one
-- space between words, the words' own capitals.
function namegen.parse(kind, s)
	if type(s) ~= "string" or not SHAPES[kind] or #s > namegen.max[kind] then return nil end
	local ws = {}
	for w in s:gmatch("[^ ]+") do ws[#ws + 1] = w end
	if table.concat(ws, " ") ~= s then return nil end
	for _, shape in ipairs(SHAPES[kind]) do
		local first = 1
		if shape.prefix then
			if ws[1] == shape.prefix then first = 2 else first = nil end
		end
		if first and #ws == first - 1 + #shape.slots then
			local parts, ok = { shape = shape.id }, true
			for i, list in ipairs(shape.slots) do
				local w = ws[first - 1 + i]
				if not setOf(list)[w] then ok = false break end
				parts[i] = w
			end
			if ok and namegen.make(kind, parts) == s then return parts end
		end
	end
	return nil
end

function namegen.valid(kind, s)
	return namegen.parse(kind, s) ~= nil
end

-- A name rolled with the client's draw: rand(n) returns an integer 1..n. `keep`
-- holds parts to keep (a locked slot): { shape = id, [i] = word }; slots without a
-- word are drawn from the words that still fit. Returns the name and its parts, or
-- nil when the kept words leave no room.
function namegen.roll(kind, rand, keep)
	local shapes = SHAPES[kind]
	assert(shapes, "namegen.roll: kind")
	assert(type(rand) == "function", "namegen.roll: rand")
	keep = keep or {}
	for _ = 1, namegen.tune.tries do
		local shape = shapeOf(kind, keep.shape)
		if not shape then
			local r, weights = rand(100), namegen.tune.shapes[kind]
			for _, s in ipairs(shapes) do
				r = r - (weights[s.id] or 0)
				if r <= 0 then shape = s break end
			end
			shape = shape or shapes[1]
		end
		local parts = { shape = shape.id }
		if keep.shape == shape.id then
			for i = 1, #shape.slots do parts[i] = keep[i] end
		end
		-- Characters left for slot i: the length less the prefix, the spaces, the
		-- words already chosen and the shortest word of each slot still open.
		local function room(i)
			local left = namegen.max[kind] - (#shape.slots - 1)
			if shape.prefix then left = left - #shape.prefix - 1 end
			for j, list in ipairs(shape.slots) do
				if j ~= i then left = left - (parts[j] and #parts[j] or shortest(list)) end
			end
			return left
		end
		-- A player's wood first, so the adjective can share its letter.
		for i = #shape.slots, 1, -1 do
			local w = parts[i]
			if not w then
				local pool, left = {}, room(i)
				for _, x in ipairs(words[shape.slots[i]]) do
					if #x <= left then pool[#pool + 1] = x end
				end
				local list = pool
				if kind == "player" and i == 1 and parts[2]
					and rand(1000) <= namegen.tune.alliterate * 1000 then
					local letter = parts[2]:sub(1, 1)
					local same = {}
					for _, x in ipairs(list) do
						if x:sub(1, 1) == letter then same[#same + 1] = x end
					end
					if #same > 0 then pool = same end
				end
				if #pool == 0 then return nil end -- the kept words leave no room
				w = pool[rand(#pool)]
			end
			parts[i] = w
		end
		local s = namegen.make(kind, parts)
		if s then return s, parts end
	end
	return nil
end

-- The next word in slot `i` of `parts` (dir 1 or -1), skipping words that would
-- make the name too long: what a slot picker shows as the player scrolls. Returns
-- the new name and parts, or nil when no other word fits.
function namegen.step(kind, parts, i, dir)
	local shape = shapeOf(kind, parts and parts.shape)
	assert(shape and shape.slots[i], "namegen.step: slot")
	local list = words[shape.slots[i]]
	local at = 0
	for j, w in ipairs(list) do
		if w == parts[i] then at = j break end
	end
	local n = #list
	for k = 1, n - 1 do
		local j = (at - 1 + k * (dir < 0 and -1 or 1)) % n + 1
		local next = { shape = parts.shape }
		for x = 1, #shape.slots do next[x] = parts[x] end
		next[i] = list[j]
		local s = namegen.make(kind, next)
		if s then return s, next end
	end
	return nil
end

-- Every name of a kind, sorted: for tools and tests (docs/NAMES.md "Review"), not
-- for a device at play.
function namegen.all(kind)
	local out = {}
	for _, shape in ipairs(SHAPES[kind]) do
		local function walk(i, parts)
			if i > #shape.slots then
				local s = namegen.make(kind, parts)
				if s then out[#out + 1] = s end
				return
			end
			for _, w in ipairs(words[shape.slots[i]]) do
				parts[i] = w
				walk(i + 1, parts)
			end
			parts[i] = nil
		end
		walk(1, { shape = shape.id })
	end
	table.sort(out)
	return out
end

tw.namegen = namegen
