-- Micro benchmarks of the Lua operations the physics is made of, to learn
-- the device's cost model (the device autobench runs them; tools/bench.lua
-- --micro runs them on the desktop). Pure Lua: the clock is passed in.
-- Each test returns nanoseconds per loop iteration, the empty loop removed.
import "core/tw"
import "core/body"

local microbench = {}

-- Returns an array of { name, ns } and the iteration count.
function microbench.run(clock, n)
	n = n or 20000
	local out = {}
	local function time(name, fn)
		local t0 = clock()
		fn(n)
		out[#out + 1] = { name = name, ns = (clock() - t0) * 1e9 / n }
	end
	time("empty loop", function(n) for _ = 1, n do end end)
	time("clock() call", function(n) for _ = 1, n do clock() end end)
	time("8 local mul-adds", function(n)
		local x = 1.0
		for _ = 1, n do
			x = x * 0.999 + 0.001; x = x * 0.999 + 0.001; x = x * 0.999 + 0.001; x = x * 0.999 + 0.001
			x = x * 0.999 + 0.001; x = x * 0.999 + 0.001; x = x * 0.999 + 0.001; x = x * 0.999 + 0.001
		end
		return x
	end)
	time("8 sqrt (local)", function(n)
		local sqrt, x = math.sqrt, 2.0
		for _ = 1, n do
			x = sqrt(x + 3); x = sqrt(x + 3); x = sqrt(x + 3); x = sqrt(x + 3)
			x = sqrt(x + 3); x = sqrt(x + 3); x = sqrt(x + 3); x = sqrt(x + 3)
		end
	end)
	time("8 math.sqrt (global)", function(n)
		local x = 2.0
		for _ = 1, n do
			x = math.sqrt(x + 3); x = math.sqrt(x + 3); x = math.sqrt(x + 3); x = math.sqrt(x + 3)
			x = math.sqrt(x + 3); x = math.sqrt(x + 3); x = math.sqrt(x + 3); x = math.sqrt(x + 3)
		end
	end)
	time("8 field reads, 4-field table", function(n)
		local t, s = { a = 1, b = 2, c = 3, d = 4 }, 0
		for _ = 1, n do s = t.a + t.b + t.c + t.d + t.a + t.b + t.c + t.d end
		return s
	end)
	local b = tw.body.new("kubb", "k")
	time("8 field reads, body table", function(n)
		local s = 0
		for _ = 1, n do s = b.vx + b.vy + b.vz + b.wx + b.wy + b.wz + b.x + b.y end
		return s
	end)
	time("8 field writes, body table", function(n)
		for i = 1, n do b.vx = i; b.vy = i; b.vz = i; b.wx = i; b.wy = i; b.wz = i; b.x = i; b.y = i end
	end)
	local bodies = {}
	for i = 1, 18 do bodies[i] = tw.body.new("kubb", "k" .. i) end
	time("8 field reads, 18 bodies in turn", function(n)
		local s, k = 0, 1
		for _ = 1, n do
			local q = bodies[k]
			s = q.vx + q.vy + q.vz + q.wx + q.wy + q.wz + q.x + q.y
			k = k + 1; if k > 18 then k = 1 end
		end
		return s
	end)
	-- the solver's layout: 40 parallel arrays read at one index
	local arrs = {}
	for a = 1, 40 do local t = {}; for i = 1, 32 do t[i] = i * 0.5 end; arrs[a] = t end
	local A1, A2, A3, A4, A5, A6, A7, A8 = arrs[1], arrs[2], arrs[3], arrs[4], arrs[5], arrs[6], arrs[7], arrs[8]
	local A9, A10, A11, A12, A13, A14, A15, A16 = arrs[9], arrs[10], arrs[11], arrs[12], arrs[13], arrs[14], arrs[15], arrs[16]
	time("16 reads, 16 arrays at one index", function(n)
		local s, k = 0, 1
		for _ = 1, n do
			s = A1[k] + A2[k] + A3[k] + A4[k] + A5[k] + A6[k] + A7[k] + A8[k]
				+ A9[k] + A10[k] + A11[k] + A12[k] + A13[k] + A14[k] + A15[k] + A16[k]
			k = k + 1; if k > 27 then k = 1 end
		end
		return s
	end)
	-- the same 16 numbers in one record (array part), one record per index
	local recs = {}
	for i = 1, 32 do local r = {}; for j = 1, 16 do r[j] = j * 0.5 end; recs[i] = r end
	time("16 reads, one array record", function(n)
		local s, k = 0, 1
		for _ = 1, n do
			local r = recs[k]
			s = r[1] + r[2] + r[3] + r[4] + r[5] + r[6] + r[7] + r[8]
				+ r[9] + r[10] + r[11] + r[12] + r[13] + r[14] + r[15] + r[16]
			k = k + 1; if k > 27 then k = 1 end
		end
		return s
	end)
	-- one flat array, stride 16
	local flat = {}
	for i = 1, 32 * 16 do flat[i] = i * 0.5 end
	time("16 reads, flat array stride 16", function(n)
		local s, k = 0, 0
		for _ = 1, n do
			s = flat[k + 1] + flat[k + 2] + flat[k + 3] + flat[k + 4] + flat[k + 5] + flat[k + 6] + flat[k + 7] + flat[k + 8]
				+ flat[k + 9] + flat[k + 10] + flat[k + 11] + flat[k + 12] + flat[k + 13] + flat[k + 14] + flat[k + 15] + flat[k + 16]
			k = k + 16; if k >= 27 * 16 then k = 0 end
		end
		return s
	end)
	time("16 local reads (baseline)", function(n)
		local a, b2, c, d, e, f, g, h = 1, 2, 3, 4, 5, 6, 7, 8
		local s = 0
		for _ = 1, n do s = a + b2 + c + d + e + f + g + h + a + b2 + c + d + e + f + g + h end
		return s
	end)
	local function seven(x, y, z, p, q, r)
		return x * p, y * q, z * r, x + p, y + q, z + r, x * y
	end
	time("call, 6 args, 7 results", function(n)
		local s = 0
		for i = 1, n do
			local a1, a2, a3, a4, a5, a6, a7 = seven(i, 1.5, 2.5, 0.5, 0.25, 3)
			s = s + a7
		end
		return s
	end)
	time("new table, 5 fields", function(n)
		local t
		for i = 1, n do t = { t = i, x = 1, y = 2, z = 3, with = "ground" } end
		return t
	end)
	time("new closure", function(n)
		local f
		for i = 1, n do f = function() return i end end
		return f
	end)
	-- empty loop removed from the others
	local base = out[1].ns
	for i = 2, #out do out[i].ns = out[i].ns - base end
	return out
end

function microbench.lines(out)
	local l = {}
	for _, r in ipairs(out) do l[#l + 1] = string.format("  %-34s %9.0f ns", r.name, r.ns) end
	return l
end

tw.microbench = microbench
