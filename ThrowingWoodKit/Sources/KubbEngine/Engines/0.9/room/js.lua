-- What the room's logic needs of JavaScript's semantics, so room/lobby, room/seats and
-- room/sync decide exactly as the web's src/net modules do on the same JSON (docs/ROOM.md
-- "Values"). Pure Lua 5.4.
--
-- A value read by json.decode(text, true) maps onto JavaScript's: nil is undefined (a
-- missing key), json.null is null, a table marked as an object is an object and any other
-- table an array. On top of that:
--   * truthy(v): JavaScript's truthiness (false, 0, NaN, "", null and undefined are false);
--   * same(a, b): ===, for the values a document holds (tables by identity);
--   * get(t, k): t?.[k] for an object or array; nil for anything else;
--   * text(v): JSON.stringify(v) with object keys sorted (numbers printed as JavaScript
--     prints them: 3 for 3.0, 1e-7, 1e+21), the canonical text a test compares;
--   * asciiSize(v): the web's asciiSize, JSON.stringify(v) with every character above
--     U+007E counted as 6 bytes: the room's size limits (the web's docs/ROOMS.md section 3).
import "core/tw"
import "session/json"

local json = tw.web.json
local NULL = json.null
local fmt, concat, sort, mtype = string.format, table.concat, table.sort, math.type
local floor, huge = math.floor, math.huge

local js = {}

function js.isNull(v) return rawequal(v, NULL) end

function js.truthy(v)
	if v == nil or v == false or rawequal(v, NULL) then return false end
	if type(v) == "number" then return v == v and v ~= 0 end
	if type(v) == "string" then return v ~= "" end
	return true
end

-- a === b for JSON values: numbers by value (3 === 3.0), strings by content, tables by
-- identity, null only to null and undefined only to undefined.
function js.same(a, b)
	if type(a) == "number" and type(b) == "number" then return a == b end
	return rawequal(a, b)
end

-- typeof v === "object" && v !== null (arrays too).
function js.isTable(v) return type(v) == "table" and not rawequal(v, NULL) end

function js.isArray(v) return json.isArray(v) end
function js.isObject(v) return json.isObject(v) end

-- t?.[k]: nil unless t is an object or an array.
function js.get(t, k)
	if type(t) ~= "table" or rawequal(t, NULL) then return nil end
	return t[k]
end

-- Number.isInteger(v)
function js.isInteger(v)
	return type(v) == "number" and v == v and v ~= huge and v ~= -huge and floor(v) == v
end

-- An integral number as a Lua integer where it fits (so it is written 3, not 3.0).
function js.int(v)
	return math.tointeger(v) or v
end

-- Array.prototype.includes, by ===.
function js.includes(list, v)
	if not js.isTable(list) then return false end
	for _, x in ipairs(list) do if js.same(x, v) then return true end end
	return false
end

-- Number(v) for the values a document holds (ToNumber; objects give NaN).
function js.toNumber(v)
	local t = type(v)
	if t == "number" then return v end
	if v == nil then return 0 / 0 end
	if rawequal(v, NULL) then return 0 end
	if t == "boolean" then return v and 1 or 0 end
	if t == "string" then
		local s = v:match("^[%s]*(.-)[%s]*$")
		if s == "" then return 0 end
		if s == "Infinity" or s == "+Infinity" then return huge end
		if s == "-Infinity" then return -huge end
		if s:find("^[-+]?%d*%.?%d*[eE]?[-+]?%d*$") or s:find("^0[xXoObB]%x+$") then
			local n = tonumber(s)
			if n then return n end
		end
		return 0 / 0
	end
	return 0 / 0
end

-- v + 1 and v - 1 as JavaScript computes them (a string + 1 is the string with "1" on).
function js.plus1(v)
	if type(v) == "number" then return v + 1 end
	if type(v) == "string" then return v .. "1" end
	return js.toNumber(v) + 1
end
function js.minus1(v)
	if type(v) == "number" then return v - 1 end
	return js.toNumber(v) - 1
end

-- a < b (numbers, or two strings compared by their characters).
function js.less(a, b)
	if type(a) == "string" and type(b) == "string" then return a < b end
	return js.toNumber(a) < js.toNumber(b)
end

-- ---------- JSON.stringify ----------

-- A number as JavaScript's Number.prototype.toString prints it (ECMA-262 Number::toString):
-- the shortest digits that read back as the same double, in plain notation from 1e-6 up
-- to 1e21, else with an exponent. NaN and the infinities are null in JSON.
local function jsNumber(v)
	if mtype(v) == "integer" then
		if v > -9007199254740992 and v < 9007199254740992 then return fmt("%d", v) end
		v = v + 0.0
	end
	if v ~= v or v == huge or v == -huge then return "null" end
	if v == 0 then return "0" end
	local sign = ""
	if v < 0 then sign, v = "-", -v end
	local s
	for p = 0, 16 do
		s = fmt("%." .. p .. "e", v)
		if tonumber(s) == v then break end
	end
	local m, e = s:match("^([%d%.]+)e([-+]%d+)$")
	local digits = m:gsub("%.", ""):gsub("0+$", "")
	if digits == "" then digits = "0" end
	local k, n = #digits, tonumber(e) + 1
	local out
	if k <= n and n <= 21 then
		out = digits .. string.rep("0", n - k)
	elseif 0 < n and n <= 21 then
		out = digits:sub(1, n) .. "." .. digits:sub(n + 1)
	elseif -6 < n and n <= 0 then
		out = "0." .. string.rep("0", -n) .. digits
	else
		local x = n - 1
		local ex = (x < 0) and ("-" .. -x) or ("+" .. x)
		if k == 1 then out = digits .. "e" .. ex
		else out = digits:sub(1, 1) .. "." .. digits:sub(2) .. "e" .. ex end
	end
	return sign .. out
end
js.number = jsNumber

-- A string as JSON.stringify quotes it: \" \\ \b \f \n \r \t, \u00xx for the other
-- control characters, everything else (DEL and non-ASCII included) as it is.
local SHORT = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
	["\r"] = "\\r", ["\t"] = "\\t" }
local function jsString(s)
	return '"' .. s:gsub('[\0-\31"\\]', function(c) return SHORT[c] or fmt("\\u%04x", c:byte()) end) .. '"'
end
js.string = jsString

local function textTo(v, out, n)
	local t = type(v)
	if v == nil or rawequal(v, NULL) then n = n + 1; out[n] = "null"
	elseif t == "boolean" then n = n + 1; out[n] = v and "true" or "false"
	elseif t == "number" then n = n + 1; out[n] = jsNumber(v)
	elseif t == "string" then n = n + 1; out[n] = jsString(v)
	elseif t == "table" then
		if json.isArray(v) then
			n = n + 1; out[n] = "["
			for i = 1, #v do
				if i > 1 then n = n + 1; out[n] = "," end
				n = textTo(v[i], out, n)
			end
			n = n + 1; out[n] = "]"
		else
			local keys = {}
			for k in pairs(v) do
				if type(k) ~= "string" then error("js: a " .. type(k) .. " key", 0) end
				keys[#keys + 1] = k
			end
			sort(keys)
			n = n + 1; out[n] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then n = n + 1; out[n] = "," end
				n = n + 1; out[n] = jsString(k) .. ":"
				n = textTo(v[k], out, n)
			end
			n = n + 1; out[n] = "}"
		end
	else
		error("js: a " .. t, 0)
	end
	return n
end

-- JSON.stringify(v), keys sorted.
function js.text(v)
	local out = {}
	textTo(v, out, 0)
	return concat(out)
end

-- The web's asciiSize(v) (src/net/sync.js): the characters of JSON.stringify(v), each
-- above U+007E counted 6. The order of keys does not change it.
function js.asciiSize(v)
	local s = js.text(v)
	local n = 0
	for _, cp in utf8.codes(s, true) do n = n + ((cp > 0x7e) and 6 or 1) end
	return n
end

tw.room = tw.room or {}
tw.room.js = js
