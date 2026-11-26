-- The one door from JavaScript (docs/SESSION.md "The API"): kubbCall(method,
-- argsJson) -> resultJson. One session per Lua state. Every call is
-- protected: a Lua error comes back as {"error": "..."}, which src/engine
-- throws as a JavaScript Error. snapshot returns the snapshot text itself;
-- restore takes it as its argument. "pitch.<name>" calls are the pitch's (pitch/api.lua);
-- "room.<name>" is their old spelling (before 0.13) and reaches the same calls.
-- "names.<name>" are generated names' (session/names.lua, docs/SESSION.md "Names").
-- "neighbours.<name>" are the Tournament's neighbouring pitches (session/neighbours.lua,
-- docs/SESSION.md "Neighbours", since 0.15.1): no session needed, and none touched.
-- "record.<name>" is record mode (session/record.lua, docs/RECORD.md, since 1.1.0): a real
-- game scored throw by throw, held apart from the session.
import "core/tw"
import "version"
import "session/json"
import "session/session"
import "session/wide"
import "session/replay"
import "session/check"
import "session/names"
import "session/neighbours"
import "session/record"
import "pitch/api"

local json, session, wide, replay, check = tw.web.json, tw.web.session, tw.web.wide, tw.web.replay, tw.web.check

local api = {}
local S = nil

local function need()
	assert(S, "no session: call new or restore first")
	return S
end

-- A replay (session/replay.lua) while one is loaded: its session is S, and nothing may
-- act in it (every call that would change the match but the replay's own is refused).
local R = nil

local function act()
	assert(not R, "a replay is read only")
	return need()
end

local M = {}

-- The wide view (session/wide.lua): while it is on, the calls that hand JS a
-- camera hand it the wide one, and what is in Team B's view frame comes out
-- in the world frame. It belongs to this Lua state, not to a session: a new
-- match or a restore keeps it.
local wideBox, wideCam = nil, nil
local WIDE = { view = true, aim = true, frame = true, showAt = true, apply = true, recording = true,
	showAim = true, setTarget = true, nudgeTarget = true, setStance = true, stepArc = true, setArc = true,
	stepSide = true, setTilt = true, setSpin = true, freshPlan = true, setLevel = true, setDrill = true, reset = true, setSurface = true,
	new = true, restore = true, replayLoad = true, replayStep = true, replayBack = true, replayRewind = true }

-- { box = { left, top, right, bottom } } turns it on (frame px; kind "side"
-- or "end" to choose the framing, else by the box's shape), {} turns it off.
-- Returns { camera, kind, farPx } (farPx: the smallest base kubb's height in
-- frame px) or {}.
function M.setWide(a)
	if a and a.box then
		local b = a.box
		wideBox = { left = b.left + 0, top = b.top + 0, right = b.right + 0, bottom = b.bottom + 0 }
		wideCam = wide.camera(wideBox, a.kind)
		return { camera = wideCam, kind = wideCam.kind, farPx = wide.smallest(wideCam) }
	end
	wideBox, wideCam = nil, nil
	return json.object()
end

-- A view from one side (1.4.0; session/wide "a view from one side", docs/SESSION.md): while
-- it is on (and the wide view is off: the wide view wins), every output comes in that
-- side's frame, and the other side's throws, inkast and raises come with a camera at the
-- viewer's end. It belongs to this Lua state, as the wide view does. View only.
local viewSide, viewBox = nil, nil
local VIEW = { need = true, cpuPlay = true }
for k in pairs(WIDE) do VIEW[k] = true end

-- setView { side = "A" | "B", box? } turns it on (box: the frame px the end camera is
-- fitted to; absent, camera.tune["end"].box); {} (or no side) turns it off. Returns
-- { side, box } or {}.
function M.setView(a)
	if a and (a.side == "A" or a.side == "B") then
		viewSide = a.side
		local b = a.box
		viewBox = b and { left = b.left + 0, top = b.top + 0, right = b.right + 0, bottom = b.bottom + 0 } or nil
	else
		viewSide, viewBox = nil, nil
	end
	session.viewSide, session.viewBox = viewSide, viewBox
	if not viewSide then return json.object() end
	return { side = viewSide, box = viewBox or tw.camera.tune["end"].box }
end

-- The end camera for the last recording when it is the other side's (fixed for the
-- whole of it), made once per recording.
local recCam = { rec = nil, cam = nil }
local function recordingCam()
	local rec = S.recording
	if recCam.rec == rec and recCam.side == viewSide and recCam.box == viewBox then return recCam.cam end
	local t = wide.T(S.recSide, viewSide)
	local tr = wide.recording(t, rec)
	if tr and tr.launch and tr.launch.x and t == "B" then
		local l = {}
		for k, v in pairs(tr.launch) do l[k] = v end
		l.x, l.y = tw.frame.point("B", l.x, l.y)
		local c = {}
		for k, v in pairs(tr) do c[k] = v end
		c.launch = l
		tr = c
	end
	recCam.rec, recCam.side, recCam.box = rec, viewSide, viewBox
	recCam.cam = wide.endCamera(viewBox, nil, tr)
	return recCam.cam
end

local viewOut
function viewOut(method, r)
	if wideCam or not viewSide or not S or not VIEW[method] or type(r) ~= "table" then return r end
	if method == "showAt" then
		if wide.T(S.recSide, viewSide) == "B" and r.items then
			r.items = wide.items("B", r.items)
			if S.recording then r.camera = recordingCam() end
		end
		r.view = viewSide
		return r
	end
	if method == "recording" then return (r.timeline and wide.recording(wide.T(S.recSide, viewSide), r)) or r end
	if method == "need" then return wide.needTo(r, viewSide, viewBox) end
	if method == "cpuPlay" then
		-- each step's recording is in its thrower's frame (step.side)
		for _, st in ipairs(r.steps or {}) do
			if st.recording then st.recording = wide.recording(wide.T(st.side, viewSide), st.recording) end
		end
		if type(r.need) == "table" then r.need = wide.needTo(r.need, viewSide, viewBox) end
		if type(r.view) == "table" then r.view = viewOut("view", r.view) end
		return r
	end
	local cams = { box = viewBox, aim = function(aimT) return wide.endCamera(viewBox, aimT) end }
	return wide.toSide(r, viewSide, S.frameSide, S.recSide, cams)
end

local function wideOut(method, r)
	if viewSide and not wideCam then return viewOut(method, r) end
	if method == "cpuPlay" and wideCam and S and type(r) == "table" then
		-- (1.4.0) as viewOut's: each step's recording from its thrower's frame (step.side)
		-- to the world's, and the view and need as `view` and `need` give them
		for _, st in ipairs(r.steps or {}) do
			if st.recording and st.recording.timeline then st.recording = wide.recording(st.side, st.recording) end
		end
		if type(r.view) == "table" then r.view = wide.out(r.view, wideCam, S.frameSide, S.recSide) end
		if type(r.need) == "table" then r.need = wide.out({ need = r.need }, wideCam, S.frameSide, S.recSide).need end
		return r
	end
	if not wideCam or not S or not WIDE[method] or type(r) ~= "table" then return r end
	if method == "showAt" then return wide.out(r, wideCam, S.recSide, S.recSide) end
	if method == "recording" then
		return (r.timeline and wide.recording(S.recSide, r)) or r
	end
	return wide.out(r, wideCam, S.frameSide, S.recSide)
end

-- ---------- scenes (core/scenes, since 0.14) ----------
-- scenes: the catalogue, no session needed: { default, scenes = [{ id, name, surfaces,
-- surface, sets, set, dark, ring, mono, choices }], surfaces = [{ id, name }], sets =
-- [{ id, name }] } (every surface the engine plays and every set it takes, in order).
function M.scenes()
	local out = {}
	for i, e in ipairs(tw.scenes.list) do
		local sf, st = {}, {}
		for j, k in ipairs(e.surfaces) do sf[j] = k end
		for j, k in ipairs(e.sets) do st[j] = k end
		out[i] = { id = e.id, name = e.name, surfaces = sf, surface = e.surface, sets = st, set = e.set,
			dark = e.dark, ring = e.ring, mono = e.mono, choices = tw.scenes.choices(e.id) }
	end
	local surfaces, sets = {}, {}
	for i, k in ipairs(tw.scenes.SURFACES) do surfaces[i] = { id = k, name = tw.scenes.surfaceName[k] } end
	for i, k in ipairs(tw.scenes.SETS) do sets[i] = { id = k, name = tw.scenes.setName[k] } end
	return { default = tw.scenes.DEFAULT, scenes = out, surfaces = surfaces, sets = sets }
end

-- setImpacts { on }: while on, each recording's timeline carries `impacts`, where the
-- pieces met the ground hard (session/throw, docs/SESSION.md "Ground impacts"). It
-- belongs to this Lua state, like the wide view; off (the default), nothing is gathered.
-- Returns { on }.
function M.setImpacts(a)
	tw.web.throw.impacts = (a and a.on) and true or false
	return { on = tw.web.throw.impacts }
end

-- ---------- the host, at start-up ----------
-- engineVersion: { version } (version.lua). useTune { name }: the host's tune
-- (tune/<name>.lua), once per Lua state, before the first new or restore; returns
-- { tune }. setClient { label }: the client label written into game files ("web
-- 0.4.2"; default "kubb-engine <version>") and, since 0.7.2, optionally { location }: the
-- game file's Location line ("throwingwood.com"; absent: "Playdate", as before: each call
-- sets both). Returns { client, location }: since 0.7.4 `location` is always the line
-- the files will carry, "Playdate" when none was given (before, it was left out).
function M.engineVersion() return { version = tw.engine.version } end
function M.useTune(a) return { tune = session.useTune(a and a.name) } end
function M.setClient(a)
	local out = { client = session.setClient(a and a.label) }
	out.location = session.setLocation(a and a.location) or tw.notation.location
	return out
end

-- new: a match or practice as a client sets it up; a scene named decides the surface
-- and the set (session.sceneOptions, since 0.14)
function M.new(a) R = nil; S = session.new(session.sceneOptions(a or {})); return S:view() end
-- restore's argument is the snapshot text itself, or since 0.13.4 { snap, names } with
-- names = "check": the snapshot refused (nothing changes) when a name in it is not one
-- the engine allows (session/namecheck). A snapshot has `v`, the wrapper does not.
function M.restore(text, raw)
	local d = json.decode(raw)
	local opts = nil
	if type(d) == "table" and d.v == nil and d.snap ~= nil then
		opts = { names = d.names }
		d = d.snap
	end
	local s = session.restore(d, nil, opts)
	R = nil
	S = s
	return S:view()
end
function M.restorePractice(a) R = nil; S = session.restorePractice(a.checkpoint); return S:view() end
function M.view() return need():view() end
-- The view in the thrower's frame even while the wide view is on: what a report
-- records, so tools/reports.mjs can compare it with a replay (not in WIDE).
function M.frameView() return need():view() end
function M.need() return need():need() end
function M.aim() local s = need(); return { aim = s:aimView(), camera = s.ts.aimCam } end
function M.frame(a) return need():frame(a or {}) end
function M.showAt(a) return need():showAt(a and a.t or 0) or json.object() end
function M.setTarget(a) return need():setTarget(a.x, a.y, a.snap) end
function M.nudgeTarget(a) return need():nudgeTarget(a.dx, a.dy) end
function M.setStance(a) return need():setStance(a and a.x, a and a.y) end
function M.stepArc(a) return need():stepArc(a and a.step) end
function M.setArc(a) return need():setArc(a.deg) end
function M.stepSide(a) return need():stepSide(a and a.step) end
function M.setTilt(a) return need():setTilt(a and a.deg) end
function M.setSpin(a) return need():setSpin(a and a.spin) end
function M.freshPlan() return need():freshPlan() end
function M.setLevel(a) return need():setLevel(a and a.level) end
function M.setDrill(a) return need():setDrill(a and a.on) end
function M.reset() return need():reset() end
function M.setSurface(a) return need():setSurface(a and a.surface) end
function M.setControl(a) return act():setControl(a) end
function M.aimState() return need():aimState() end
function M.showAim(a) return need():showAim(a) or json.object() end
function M.apply(a) return act():apply(a) end
function M.checkPunish(a) return need():checkPunish(a.x, a.y, a.frame) end
function M.hash() local text = need():snapshot(); return { hash = session.fnv(text), bytes = #text } end
-- ---------- a replay (session/replay.lua) ----------
-- replayLoad { setup, h0, log } (or { start, ... }; options checkCpu, checkThrows and
-- document: session/replay.lua) sets the match out again from its options; the view,
-- with `replay` = its info. replayStep plays the next action ({ ok, recording?, need,
-- action, standing = { before, after }, replay }); replayBack goes to the start of the previous turn and
-- replayRewind to the start of the match (the view, with `replay`).
local function withInfo(r)
	r.replay = R:info()
	return r
end
function M.replayLoad(a)
	-- made before it replaces anything: a replay that is refused (names = "check", or one
	-- that is not a replay) leaves the session and a replay already loaded as they were
	local r = replay.new(a)
	R = r
	S = R.s
	return withInfo(S:view())
end
local function needReplay()
	assert(R, "no replay: call replayLoad first")
	return R
end
function M.replayStep()
	local r = needReplay():step()
	S = R.s
	return withInfo(r)
end
function M.replayBack()
	needReplay():back()
	S = R.s
	return withInfo(S:view())
end
function M.replayRewind()
	needReplay():rewind()
	S = R.s
	return withInfo(S:view())
end
function M.replayInfo()
	local r = needReplay():info()
	r.held = S.ts.mode == "cpuhold"
	return r
end
function M.replayEnd() R = nil; return json.object() end
-- replayFinish: every action left (no recordings); the info. replayDocument: the finished
-- match's pitch document (replayLoad with document), with the hash at the start and after
-- each action: { document, h0, hashes }.
function M.replayFinish()
	local r = needReplay():finish()
	S = R.s
	return r
end
function M.replayDocument()
	local r = needReplay()
	local doc, why = r:document()
	assert(doc, "replayDocument: " .. tostring(why))
	return { document = doc, h0 = r.firstHash, hashes = r.hashes }
end

-- ---------- checking a shared match (session/check.lua) ----------
-- checkThrow(action): could this be the next throw as the match is set up now? { ok, why,
-- computer, levels, level, atLevel }. checkStart { start }: is it a match's first
-- snapshot? { ok, why }. renameStart { start, names = { A = "<name>" }, log? }: { start, ids,
-- log? }: the renamed start, the players' ids old to new, and the log with its thrower
-- actions' ids mapped (session.renameLog), so the renamed match replays to its end.
function M.checkThrow(a) return check.throw(need(), a) end
-- cpuPlay { at?, recordings? } (1.4.0, docs/SESSION.md "The computer's turn, fast"): every
-- computer throw until a person is needed, no frames: { steps, need, view }
function M.cpuPlay(a) return act():cpuPlay(a or {}) end
function M.checkStart(a)
	local ok, why = session.startCheck(a and a.start)
	return { ok = ok, why = why }
end
function M.renameStart(a)
	local start = session.renameStart(a.start, a.names)
	local ids = session.renameIds(a.start, start)
	local out = { start = start, ids = ids }
	if a.log ~= nil then out.log = session.renameLog(a.log, ids) end
	return out
end

-- Frozen rest poses in the frame of the reported throw, including pieces
-- picked up for the following turn. Avoid serializing the playback tracks.
function M.reportThrow()
	local s = need()
	local rec = s.recording
	if not rec then return json.object() end
	local items = {}
	for i, it in ipairs(rec.items) do
		local b = s.ts.last.res.bodies[it.id]
		items[i] = { id = it.id, kind = it.kind, team = it.team, x = b.x, y = b.y, z = b.z,
			qw = b.qw, qx = b.qx, qy = b.qy, qz = b.qz, toppled = b.toppled }
	end
	return { seq = rec.seq, items = items, result = rec.result, practiceBefore = s.practiceBefore }
end

function M.recording() return need().recording or json.object() end
function M.sheet() return need():sheet() or json.object() end

local function call(method, arg)
	if method == "snapshot" then return need():snapshot() end
	-- the pitch's pure calls (pitch/api.lua, docs/PITCH.md): "pitch.<name>", or
	-- "room.<name>", the old spelling, which a bridge that also drives older engines uses
	if type(method) == "string" then
		if method:sub(1, 6) == "pitch." then return tw.shared.api.call(method:sub(7), arg, "pitch") end
		if method:sub(1, 5) == "room." then return tw.shared.api.call(method:sub(6), arg, "room") end
		-- generated names (session/names.lua, docs/SESSION.md "Names"): no session needed
		if method:sub(1, 6) == "names." then return tw.web.names.call(method:sub(7), arg) end
		-- the neighbouring pitches (session/neighbours.lua): their own state, no session
		if method:sub(1, 11) == "neighbours." then return tw.web.neighbours.call(method:sub(12), arg) end
		-- record mode (session/record.lua, docs/RECORD.md): its own game, no session
		if method:sub(1, 7) == "record." then return tw.web.record.call(method:sub(8), arg) end
	end
	local f = M[method]
	if not f then error("unknown call " .. tostring(method), 0) end
	local a = nil
	if method == "restore" then return json.encode(wideOut(method, f(nil, arg))) end
	if arg and arg ~= "" then a = json.decode(arg) end
	local r = wideOut(method, f(a))
	if r == nil then r = json.object() end
	return json.encode(r)
end

function kubbCall(method, arg)
	local ok, r = pcall(call, method, arg)
	if ok then return r end
	return json.encode { error = tostring(r) }
end

api.call = call
tw.web.api = api
