-- The determinism driver: the same Lua runs inside the web's WebAssembly
-- engine (tools/golden-hashes.mjs, which writes golden-hashes.json) and inside
-- this app's native engine (KubbEngineTests). Each function takes and returns
-- JSON text, and reaches the engine only through kubbCall, as the app does.
-- Every hash is the engine's own (FNV-1a 32 of the snapshot text).
local json = tw.web.json
local fnv = tw.web.session.fnv

local function call(method, arg)
	local text = kubbCall(method, arg or "")
	if text:sub(1, 9) == '{"error":' then error(method .. ": " .. json.decode(text).error, 0) end
	return text
end

local function hash()
	return json.decode(call("hash")).hash
end

-- A seeded match, the computer on both sides, played frame by frame at 60
-- frames a second the way a screen drives it. Returns { start, actions } with
-- one [type, hash after it, FNV of the action's JSON] per action, and
-- `releaseCpu`, the CPU seconds (os.clock) of the frames that threw: the
-- throw simulated to rest (a timing only when nothing else runs alongside).
function driveMatch(optsText)
	local opts = json.decode(optsText)
	opts.mode = "match"
	opts.cpu = "both"
	call("new", json.encode(opts))
	local out = { start = hash(), actions = {} }
	local frameArg = json.encode { dt = 1 / 60 }
	local frames, releaseCpu = 0, 0
	if json.decode(call("need")).kind ~= "over" then
		while true do
			local t0 = os.clock()
			local text = call("frame", frameArg)
			local t1 = os.clock()
			frames = frames + 1
			assert(frames < 1000000, "the match never ended")
			-- Only a frame with an action changes the match; the rest are the
			-- computer thinking and swinging.
			if text:find('"action":', 1, true) then
				local f = json.decode(text)
				if f.action then
					releaseCpu = releaseCpu + (t1 - t0)
					out.actions[#out.actions + 1] = { f.action.type, hash(), fnv(json.encode(f.action)) }
					if json.decode(call("need")).kind == "over" then break end
				end
			end
		end
	end
	out.frames, out.releaseCpu = frames, releaseCpu
	return json.encode(out)
end

-- A recorded match (the web's tests/fixtures/replay-north-south.json) played
-- again action by action through the replay. Returns { hashes, differs }.
function driveReplay(replayText)
	local d = json.decode(replayText)
	call("replayLoad", json.encode { setup = d.setup, h0 = d.h0, log = d.log })
	local out = { start = hash(), hashes = {} }
	while true do
		local r = json.decode(call("replayStep"))
		if r.replay.done and r.ok == false then break end
		out.hashes[#out.hashes + 1] = hash()
		if r.replay.done then
			out.differs = r.replay.differs
			break
		end
	end
	call("replayEnd")
	return json.encode(out)
end

-- The maths itself: each { fn, a, b? } (arguments as the hex of their IEEE
-- bits) through Lua's math library, the result's bits back as hex.
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
