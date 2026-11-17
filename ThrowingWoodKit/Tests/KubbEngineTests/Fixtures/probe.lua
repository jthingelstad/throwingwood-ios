-- The maths itself, for KubbEngineTests: each { fn, a, b? } (arguments as the
-- hex of their IEEE bits) through Lua's math library, the result's bits back
-- as hex. Fixtures/math-probe.json holds the web's answers.
local json = tw.web.json

local function double(hex)
	return (string.unpack("<d", string.pack("<i8", math.tointeger(tonumber(hex)))))
end

local function bits(v)
	return string.format("0x%016x", (string.unpack("<i8", string.pack("<d", v))))
end

local MATH = {
	sin = math.sin, cos = math.cos, tan = math.tan, asin = math.asin, acos = math.acos,
	atan = function(a, b) return math.atan(a, b) end,
	exp = math.exp, log = math.log, sqrt = math.sqrt,
	log2 = function(a) return math.log(a, 2) end,
	log10 = function(a) return math.log(a, 10) end,
	pow = function(a, b) return a ^ b end,
	fmod = math.fmod,
}

function mathProbe(casesText)
	local out = {}
	for i, c in ipairs(json.decode(casesText)) do
		local f = assert(MATH[c[1]], "no function " .. tostring(c[1]))
		out[i] = bits(f(double(c[2]), c[3] and double(c[3]) or nil))
	end
	return json.encode(out)
end
