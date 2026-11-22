-- How a client kept its match in step through a shared document (docs/PITCH.md "Calls
-- live play no longer makes"): the web's src/net/sync.js in Lua, as it was. Pure. Live play
-- on the pitch server no longer uses it (the server holds the log and relays each action);
-- its calls stay because what clients call only grows (docs/VERSIONING.md).
--
-- The acting client applies its action, then commits the snapshot after it as action
-- `seq` with the action riding along (`with`). Every other client gets the new document
-- with `with`, applies the same action to watch the same throw, and then checks its hash
-- against the committed one. A gap, a missing `with`, a refused action or a different
-- hash: it adopts the committed snapshot instead.
import "core/tw"
import "session/json"
import "pitch/js"

local json, js = tw.web.json, tw.shared.js
local object = json.object
local truthy, same, get = js.truthy, js.same, js.get

local sync = {}

-- The client name the web put in a rider's `c` (the retired rooms server's, the web's
-- docs/ROOMS.md section 7). Another client passes its own (`ios`).
sync.CLIENT = "web"
-- The retired rooms server's limit on `with` (the web's docs/ROOMS.md section 3): the default
-- for rider's bytes.
sync.WITH_BYTES = 4096

-- What to do with a document version that arrived.
--   loc = { n, seq }  the match number and the last action number this client holds
--                     (applied or queued to apply)
--   doc the pitch's document; w its `with` (or nil); mine: our own write
-- Returns one of:
--   { kind = "lobby" }                       no match running
--   { kind = "start", match }                another match than ours: take it
--   { kind = "same", match }                 the version we hold: compare hashes
--   { kind = "old" }                         older than what we hold
--   { kind = "apply", match, action }        the next action: apply and verify
--   { kind = "adopt", match, why }           take the snapshot as it is ("own", "gap",
--                                            "no-action")
function sync.decide(loc, doc, w, mine)
	local m = nil
	if truthy(doc) and truthy(get(doc, "started")) then m = get(doc, "match") end
	if not truthy(m) or type(get(m, "snap")) ~= "string" then return object { kind = "lobby" } end
	local ln, ls = get(loc, "n"), get(loc, "seq")
	if not same(m.n, ln) then return object { kind = "start", match = m } end
	if same(m.seq, ls) then return object { kind = "same", match = m } end
	if js.less(m.seq, ls) then return object { kind = "old" } end
	if truthy(mine) then return object { kind = "adopt", match = m, why = "own" } end
	if not same(m.seq, js.plus1(ls)) then return object { kind = "adopt", match = m, why = "gap" } end
	if not truthy(w) or not same(get(w, "n"), m.n) or not same(get(w, "seq"), m.seq) or not truthy(get(w, "a")) then
		return object { kind = "adopt", match = m, why = "no-action" }
	end
	return object { kind = "apply", match = m, action = get(w, "a") }
end

-- The `with` for an action, or nil when it would not fit the limit (`bytes`, as
-- ASCII JSON, default 4096): then the others just adopt the snapshot. `c` names the
-- client that committed it (default "web"); `e`, when given, the engine's version (the
-- web sends neither yet; the web's docs/ROOMS.md section 7). The recorder keeps them with the
-- action; other clients ignore them.
function sync.rider(n, seq, action, bytes, client, engine)
	local w = object { n = n, seq = seq, a = action, c = (client == nil) and sync.CLIENT or client, e = engine }
	if bytes == nil then bytes = sync.WITH_BYTES end
	local limit = (type(bytes) == "number" and bytes or js.toNumber(bytes)) - 64
	return (js.asciiSize(w) <= limit) and w or nil
end

sync.asciiSize = js.asciiSize

tw.shared = tw.shared or {}
tw.shared.sync = sync
