# The iPhone rooms client

`KubbRooms` is a headless Swift 6 library. No screens, accounts, analytics, third-party
Swift packages or task groups. The local practice screen runs its own engine session.

## Ownership and lifetime

- `RoomsClient` owns one socket, member identity, presence and document versions. Its
  Foundation adapter is `URLSessionWebSocketTask`; tests inject `RoomsTransport` and
  `MemberIDStore`. The device stores `kubb.member` in UserDefaults, and reconnects with
  that same ID and the last document version. Call `close()` when its owner ends;
  `leave()` sends leave before closing and forgets the member on the server.
- `PitchController` owns the engine effects, the optimistic match sequence, cached
  control/seat, and a 200 ms host/presence clock. Its state is lobby, match,
  versionMismatch, failed or closed; a mismatch includes the engine's check result.
  Call its `close()` to cancel the clock, remove its observer and close the client.
- Both are main-actor isolated. An engine stays on that actor; it is never marked
  Sendable or passed to a background task. Socket receives, ordered frame sends,
  retries, ping and answer deadlines have individually owned cancellable tasks.

## The wire

The reference is the web's `src/net/room.js` and `backend/rooms/core.mjs`, with
`docs/ROOMS.md` as the guide. The client sends Origin `https://app.throwingwood.com` and
User-Agent `ThrowingWood/<app version> (ios)`. Each join includes the engine's version
in `me.engine`. `recordGame` and `report` add `client: ios` and the actual engine version (the server's
client tag allows no space, so the app version travels in the report's `build.version`);
commit riders carry `c: ios` and `e` from that engine. The low-level `request` and
`send` methods are available for protocol work; use the tagged methods for records.

`JS` and `ASCIIJSON` write JSON explicitly: UTF-16 units above U+007E become lowercase
backslash-u escapes, emoji become surrogate pairs, lone surrogates are representable,
controls use JSON.stringify's escapes, finite doubles use its notation thresholds and
non-finite doubles are null. Sizes are counted on that ASCII text. Engine-produced
JSON goes in as `JSONText`/`JS.raw`, never through JSONEncoder or JSONSerialization.
`JSONNode` looks into values while preserving their exact source spans. A snapshot is
an opaque string: even integral floats and exponent spelling inside it are untouched.

Messages over 30,000 characters split into `~id.i.n~` parts with 29,960-character
slices. The receiver accepts reordered/interleaved/duplicate parts, clears them at
socket changes, bounds assemblies to 16 parts/300 KiB and 32 unfinished messages, and
ignores malformed frames. These bounds intentionally harden the web client's unbounded
part reader. The transport caps incoming WebSocket messages at 32 KiB; each application
part is a distinct WebSocket message, not a WebSocket continuation frame.

Document versions increase for doc/ok/no; member revisions are per ID (left keeps its
tombstone) and the host has its own revision. A joined state resets presence revisions
and is authoritative for the document, including a room that expired and restarted at
version zero. An older ok still settles its caller without replacing a newer document.
All wire messages, including casts, pong, recorded, reported and errors, are observable
as raw messages; document/state/member/host/status events also have dedicated cases.

Updates from one client are serialized. Each reducer sees the current raw document;
a null reducer result writes nothing. A `no` adopts the winner and runs the reducer
again (20 retries by default). A dropped or unanswered set reconnects. Joined's sid/by
proves it landed, an unchanged base proves it did not (safe to retry), and any other
version is uncertain. An uncertain action is never automatically sent again. Requests
for game/report/list/replay have correlated IDs and a deadline; they are not retried.
A busy join reconnects; full/bad joins close, and replaced is terminal. Pings every
four minutes require a pong within 15 seconds. Close settles all pending continuations.

## Pitch effects

All lobby reducers, version checks, seat ownership, control and sync decisions use the
vendored engine's `room.*` calls and read `.value`. Swift contains no second version of
lobby/seats/sync rules. `reduce` exposes joinTeam, setOptions, setAccess, pruneTeams and
backToLobby; host reducers check host ownership again inside the CAS reducer.

START uses lineup, startCheck, matchOptions, new and startMatch inside the reducer, so a
CAS retry uses the current lineup/options. Engine checks are strict: different or
unknown player major.minor versions refuse START, and mayPlay gates running matches.
No lenient transition is enabled in the native client.

`take` requires the engine's mayAct result for the current need. `frame` can release
this member's dial throw or a host-owned computer throw. Seat/control are cached between
presence ticks and committed actions; no room bridge runs per frame. The caller supplies
frame input; a frame-generated action is already applied and is committed once. The
library does not autonomously fast-forward a CPU match or render playback.

Each commit writes the engine's snapshot/hash and action through commitAction, with a
rider from room.rider. A peer document goes through room.decide: apply the next action,
compare the hash, restore if refused/different; adopt gaps/missing riders, restore a new
match, and ignore old versions. There is no playback queue because actions finish
synchronously and this layer has no renderer. Future screens must queue their recording
animations separately. A losing optimistic action or uncertain write discards local
sequence first, then recovers the authoritative document. Replay, correction and gap
adoption counts are exposed for tests.

Lua nextHost picks the claimant; the client waits 16 seconds after observing host loss
(the server's minimum is 15 seconds), retries at most every five seconds, and claims
immediately if the host left for good. New host control restarts a held CPU from its
snapshot. Each participant who observes the end asks keep with replayOf and the exact
ending document version, once per match; a late arrival at an already-ended match does
not keep it again. Aim and shout helpers pace casts; a caller supplies aim ticks.

## Verification

- `swift test --package-path ThrowingWoodKit` and the optimized command in AGENTS.md
  run codec vectors, injected transport/controller tests and all 453 golden actions.
- `tools/room-vectors.mjs` imports the real web client read-only. Its committed fixtures
  include provenance and expected ASCII encoding, numbers, sizes, raw-text handling,
  UTF-16 decoding, frame boundaries and reassembly.
- `swift build --package-path ThrowingWoodKit --product RoomsProbe`, then
  `node tools/rooms-test.mjs --web <web checkout>` runs real Foundation sockets against
  imported rooms-dev on an ephemeral 127.0.0.1 port. Its in-memory callbacks write
  nothing into the web checkout, and finally closes all sockets/processes/server.
  The web checkout needs its existing `ws` and wasmoon 1.16.0 dependencies.
- Conformance covers ordinary messages, multi-frame documents, every documented server
  error code, all 16 seats, replacement, reconnect, CAS no, strict mismatched START,
  and controller host handover/CPU takeover. Busy/store failures and time passage are
  injected into the same local server, not production. Injected transports cover
  out-of-order revisions and all unanswered-set outcomes deterministically.
- Cross-play uses the web's actual Engine wrapper, wasmoon 1.16.0 and Room client,
  alongside RoomsClient/PitchController/native Lua/musl in a Swift process. Both seats
  use computer-planned actions: throwaway engines plan human seats without changing the
  playing engines' CPU options. Each seat commits its own side; every committed action
  is applied by the other platform and checked. Three matches end naturally without a
  maxTurns cap, on grass/sand/snow, with off/light/strong wind. Every hash must agree,
  no correction or gap adoption is allowed, and each kept replay must replay every
  action with no difference. The report is `build/rooms-results.json` (ignored).

Cross-play is a local acceptance check, not an additional billed CI job: the CI token
cannot read the separate private web repository. CI runs the committed vectors and
Swift tests in its existing single macOS job. No live room, device install or TestFlight
upload is part of this work.

## Gaps in the web documentation (at the referenced code)

- ROOMS.md documents `keep(replay)`, but room.js requires `keep(replay, v)`; omitting v
  is bad-message. Keep does not infer the version or acknowledge success on the wire.
- The web part reader only checks the header regex; unlike the server, it does not
  enforce 2..16 parts, index bounds, size or expiry. Its regex even accepts 0/1 for n.
- Joined's public limits omit parts, messageBytes, reportBytes, gameBytes and replayBytes.
  The native receiver uses the fixed protocol caps rather than expecting those fields.
- The document “never goes back” rule has an incarnation boundary: the web forces joined's
  document even after an expired room restarts at v0. Ordinary doc/ok/no remain monotonic.
- MULTIPLAYER.md still describes JavaScript lobby/seats/sync, `me` without engine,
  match without engine, and says rider e is not sent; room.js sends an explicit v with
  keep and pitch.js already passes engine to rider. Engine 0.3's room calls supersede
  those logic descriptions; the native controller uses them directly.
- “Non-ASCII counts 6 bytes each” means UTF-16 code units: an emoji counts twelve escaped
  bytes, a lone surrogate six. Report answer length separately uses Unicode code points.

No UI, universal links, background lifecycle integration, open-game publication,
record/report collection policy, replay controls or physical network conditions are
covered here. The wire carries open/list/replay and tagged game/report messages, but
these product surfaces belong to the next phase. AWS origin filtering, stage throttles,
TTL scheduling and real two-hour socket expiry are not exercised by rooms-dev.

## Driving the pitch screen

The optional presentation callbacks on PitchController run on the main actor.
After the controller verifies a peer action, it passes the action and its
committed match to the presentation. A gap, correction, new match or rejoin
supplies an authoritative snapshot. Presence and document notifications reach
the screen after the controller processes them. The 200 ms clock also drives
changed aim casts, listing renewal and shout expiry.

OnlinePitch in KubbRenderer owns the controller and a second Lua session
for the board. The room can receive and verify several actions while the
board is still playing the first recording through showAt. The board checks
each action's hash and drains the queue in order. Its own release or placement
goes through the same seat check and CAS commit as a scripted action.
The screen announces room.constants.ENGINE in presence. Record and report
tags use the full engine version.

The local rooms test drives OnlinePitch with the web Room and wasm engine.
It compares each displayed hash, the controller hash, and a replay of the
server's kept log. It also checks peer-visible message shapes, round-trip
aim and shouts, a real dial release after host succession, connection loss,
background return, both directions of a version mismatch and a captured
report on an unjoined socket. For a faster local run, build RoomsProbe with
`-c release` and pass `--release` to the Node script.
