-- JSON in and out for the web session (docs/SESSION.md "Determinism"). Pure Lua 5.4.
--
-- What the session hands JavaScript and what it keeps in a snapshot goes
-- through here, so it is exact and the same in every browser:
--   * object keys are written sorted, so the same table is always the same
--     text (the snapshot hash depends on it);
--   * a Lua integer is written without a point ("3") and a float always with
--     one or an exponent ("3.0", "0.1", "1e-07"): json.decode gives back an
--     integer for the first and a float for the others, so a snapshot comes
--     back with every number of the same Lua type it had (Lua 5.4 keeps
--     integers and floats apart: 3 // 2 and string.format of them differ);
--   * a float is written with the fewest digits (15, 16 or 17) that read back
--     as exactly the same double, so nothing drifts through a round trip;
--   * an empty table is written as [] (json.object() marks one that must be
--     {}), a table with keys 1..n as an array, any other as an object (string
--     keys only: anything else is an error, as core/save's plain rule is).
-- json.raw(text) puts text into the output as it is (the recording's pose
-- arrays, already formatted).
--
-- The pitch's documents (pitch/, docs/PITCH.md) need what a JavaScript client wrote to come
-- back as it was: json.decode(text, true) keeps every object an object (an empty one too,
-- marked as json.object() marks it) and every null a null (json.null, which encodes as
-- null), where the plain decode drops nulls and reads {} as an empty table, written [].
-- The session never decodes that way, so its texts and hashes are unchanged.
import "core/tw"

local json = {}

local fmt, concat, sort, mtype = string.format, table.concat, table.sort, math.type

local RAW = {}      -- metatable of json.raw values
local OBJECT = {}   -- metatable of tables always written as objects
local NULL = setmetatable({}, { __name = "json.null", __tostring = function() return "null" end })

function json.raw(text) return setmetatable({ text }, RAW) end
function json.object(t) return setmetatable(t or {}, OBJECT) end

-- JSON's null, kept apart from a missing key (nil) by json.decode(text, true).
json.null = NULL
function json.isNull(v) return rawequal(v, NULL) end

-- An array: a table that is not json.null, not marked as an object, and is empty or has
-- exactly the keys 1..n (what json.encode writes as an array).
function json.isArray(v)
	if type(v) ~= "table" or rawequal(v, NULL) then return false end
	local mt = getmetatable(v)
	if mt == OBJECT or mt == RAW then return false end
	local len, n = #v, 0
	for _ in pairs(v) do n = n + 1 end
	return n == len
end

-- An object: a table that is not json.null and not an array.
function json.isObject(v)
	return type(v) == "table" and not rawequal(v, NULL) and getmetatable(v) ~= RAW and not json.isArray(v)
end

-- A float as the shortest text that reads back as the same double.
local function float(v)
	if v ~= v then error("json: NaN", 0) end
	if v == math.huge then return "1e999" end
	if v == -math.huge then return "-1e999" end
	local s
	for p = 15, 17 do
		s = fmt("%." .. p .. "g", v)
		if tonumber(s) == v then break end
	end
	if not s:find("[%.eEn]") then s = s .. ".0" end
	return s
end
json.float = float

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
	["\r"] = "\\r", ["\t"] = "\\t" }
local function str(s)
	return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or fmt("\\u%04x", c:byte()) end) .. '"'
end

local encodeTo
encodeTo = function(v, out, n, path)
	local t = type(v)
	if v == nil or rawequal(v, NULL) then n = n + 1; out[n] = "null"
	elseif t == "boolean" then n = n + 1; out[n] = v and "true" or "false"
	elseif t == "number" then
		n = n + 1
		out[n] = (mtype(v) == "integer") and fmt("%d", v) or float(v)
	elseif t == "string" then n = n + 1; out[n] = str(v)
	elseif t == "table" then
		local mt = getmetatable(v)
		if mt == RAW then n = n + 1; out[n] = v[1]; return n end
		local len = #v
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		if mt ~= OBJECT and (len > 0 and #keys == len or #keys == 0) then
			n = n + 1; out[n] = "["
			for i = 1, len do
				if i > 1 then n = n + 1; out[n] = "," end
				n = encodeTo(v[i], out, n, path)
			end
			n = n + 1; out[n] = "]"
		else
			for _, k in ipairs(keys) do
				if type(k) ~= "string" then error("json: a " .. type(k) .. " key at " .. path, 0) end
			end
			sort(keys)
			n = n + 1; out[n] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then n = n + 1; out[n] = "," end
				n = n + 1; out[n] = str(k) .. ":"
				n = encodeTo(v[k], out, n, path .. "." .. k)
			end
			n = n + 1; out[n] = "}"
		end
	else
		error("json: a " .. t .. " at " .. path, 0)
	end
	return n
end

function json.encode(v)
	local out = {}
	encodeTo(v, out, 0, "")
	return concat(out)
end

-- ---------- decoding ----------

local byte, sub, find, char = string.byte, string.sub, string.find, utf8.char

local function fail(s, i, what) error(fmt("json: %s at %d", what, i), 0) end

local function skip(s, i)
	local _, e = find(s, "^[ \t\r\n]*", i)
	return e + 1
end

local value

local function decodeString(s, i)
	-- i is just after the opening quote
	local parts, n = {}, 0
	local j = i
	while true do
		local c = byte(s, j)
		if not c then fail(s, j, "unterminated string") end
		if c == 34 then
			n = n + 1; parts[n] = sub(s, i, j - 1)
			return concat(parts), j + 1
		elseif c == 92 then
			n = n + 1; parts[n] = sub(s, i, j - 1)
			local e = sub(s, j + 1, j + 1)
			if e == "u" then
				local cp = tonumber(sub(s, j + 2, j + 5), 16)
				if not cp then fail(s, j, "bad \\u escape") end
				j = j + 6
				if cp >= 0xD800 and cp <= 0xDBFF and sub(s, j, j + 1) == "\\u" then
					local lo = tonumber(sub(s, j + 2, j + 5), 16)
					if lo and lo >= 0xDC00 and lo <= 0xDFFF then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
						j = j + 6
					end
				end
				n = n + 1; parts[n] = char(cp)
			else
				local m = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
				if not m then fail(s, j, "bad escape") end
				n = n + 1; parts[n] = m
				j = j + 2
			end
			i = j
		else
			j = j + 1
		end
	end
end

value = function(s, i, keep)
	i = skip(s, i)
	local c = sub(s, i, i)
	if c == "{" then
		local t = keep and setmetatable({}, OBJECT) or {}
		i = skip(s, i + 1)
		if sub(s, i, i) == "}" then return t, i + 1 end
		while true do
			if sub(s, i, i) ~= '"' then fail(s, i, "expected a key") end
			local k
			k, i = decodeString(s, i + 1)
			i = skip(s, i)
			if sub(s, i, i) ~= ":" then fail(s, i, "expected :") end
			local v
			v, i = value(s, i + 1, keep)
			t[k] = v
			i = skip(s, i)
			local d = sub(s, i, i)
			if d == "}" then return t, i + 1 end
			if d ~= "," then fail(s, i, "expected , or }") end
			i = skip(s, i + 1)
		end
	elseif c == "[" then
		local t, n = {}, 0
		i = skip(s, i + 1)
		if sub(s, i, i) == "]" then return t, i + 1 end
		while true do
			local v
			v, i = value(s, i, keep)
			n = n + 1
			t[n] = v
			i = skip(s, i)
			local d = sub(s, i, i)
			if d == "]" then return t, i + 1 end
			if d ~= "," then fail(s, i, "expected , or ]") end
			i = i + 1
		end
	elseif c == '"' then
		return decodeString(s, i + 1)
	elseif c == "t" and sub(s, i, i + 3) == "true" then return true, i + 4
	elseif c == "f" and sub(s, i, i + 4) == "false" then return false, i + 5
	elseif c == "n" and sub(s, i, i + 3) == "null" then return keep and NULL or nil, i + 4
	else
		local _, e = find(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
		if not e then fail(s, i, "unexpected character") end
		local text = sub(s, i, e)
		local v = tonumber(text)
		if v == nil then fail(s, i, "bad number") end
		-- a number with a point or an exponent is a float even when it is whole
		-- (tonumber already gives a float for those; adding 0.0 would turn -0.0
		-- into 0.0 and a snapshot would not come back to the same text)
		if find(text, "[%.eE]") and mtype(v) == "integer" then v = v + 0.0 end
		return v, e + 1
	end
end

-- Decode JSON text. null in an object leaves the key out; in an array it
-- leaves a hole (the session never sends one). With keep, null is json.null and
-- every object is marked as one (json.object), so the text comes back as it was.
function json.decode(s, keep)
	if type(s) ~= "string" then error("json: not a string", 0) end
	local v, i = value(s, 1, keep and true or nil)
	i = skip(s, i)
	if i <= #s then fail(s, i, "trailing text") end
	return v
end

tw.web = tw.web or {}
tw.web.json = json
