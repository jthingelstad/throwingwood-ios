-- The one door from JavaScript (docs/SESSION.md "The API"): kubbCall(method,
-- argsJson) -> resultJson. One session per Lua state. Every call is
-- protected: a Lua error comes back as {"error": "..."}, which src/engine
-- throws as a JavaScript Error. snapshot returns the snapshot text itself;
-- restore takes it as its argument. "room.<name>" calls are the room's (room/api.lua).
import "core/tw"
import "version"
import "session/json"
import "session/session"
import "session/wide"
import "session/replay"
import "session/check"
import "room/api"

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
	stepSide = true, freshPlan = true, setLevel = true, setDrill = true, reset = true, setSurface = true,
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

local function wideOut(method, r)
	if not wideCam or not S or not WIDE[method] or type(r) ~= "table" then return r end
	if method == "showAt" then return wide.out(r, wideCam, S.recSide, S.recSide) end
	if method == "recording" then
		return (r.timeline and wide.recording(S.recSide, r)) or r
	end
	return wide.out(r, wideCam, S.frameSide, S.recSide)
end

-- ---------- the host, at start-up ----------
-- engineVersion: { version } (version.lua). useTune { name }: the host's tune
-- (tune/<name>.lua), once per Lua state, before the first new or restore; returns
-- { tune }. setClient { label }: the client label written into game files ("web
-- 0.4.2"; default "kubb-engine <version>") and, since 0.7.2, optionally { location }: the
-- game file's Location line ("Web"; absent: "Playdate", as before: each call sets both);
-- returns { client, location? }.
function M.engineVersion() return { version = tw.engine.version } end
function M.useTune(a) return { tune = session.useTune(a and a.name) } end
function M.setClient(a)
	local out = { client = session.setClient(a and a.label) }
	out.location = session.setLocation(a and a.location)
	return out
end

function M.new(a) R = nil; S = session.new(a or {}); return S:view() end
function M.restore(text, raw) R = nil; S = session.restore(raw); return S:view() end
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
function M.freshPlan() return need():freshPlan() end
function M.setLevel(a) return need():setLevel(a and a.level) end
function M.setDrill(a) return need():setDrill(a and a.on) end
function M.reset() return need():reset() end
function M.setSurface(a) return need():setSurface(a and a.surface) end
function M.setControl(a) return act():setControl(a) end
function M.aimState() return need():aimState() end
function M.showAim(a) return need():showAim(a) or json.object() end
function M.apply(a) return act():apply(a) end
function M.checkPunish(a) return need():checkPunish(a.x, a.y) end
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
	R = nil
	R = replay.new(a)
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
-- match's room document (replayLoad with document), with the hash at the start and after
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
	-- the room's pure calls (room/api.lua, docs/ROOM.md): "room.<name>"
	if type(method) == "string" and method:sub(1, 5) == "room." then return tw.room.api.call(method:sub(6), arg) end
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
