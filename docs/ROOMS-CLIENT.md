# The iPhone pitch client

`KubbPitch` is a headless Swift 6 library: the pitch server client, the API client and
the headless pitch controller. No screens, accounts, analytics, third-party Swift
packages or task groups. The local practice screen runs its own engine session.

The references, read-only, are the web repository's `backend/pitch-server/PROTOCOL.md`
(the wire), `backend/pitch-server/API.md` (the HTTPS API) and `docs/MULTIPLAYER.md`,
whose section "What the iPhone app mirrors" lists what the two clients must keep the
same. The web's own client is `src/net/pitch-client.js`, `src/net/aim.js` and
`src/net/pitch.js`; where this doc gives a number, it is theirs. New code says "pitch",
and so does the bridge: the engine's `pitch.*` calls (`room.` was their old spelling,
which only engines before 0.13 needed).

## Ownership and lifetime

- `PitchClient` owns one socket, the member identity, presence, the document and its
  version, the frame stamp `s` and the outbox of actions not yet answered. Its
  Foundation adapter is `URLSessionWebSocketTask`; tests inject `PitchTransport` and
  `MemberIDStore`. The device keeps its member id in UserDefaults (an observer's its own
  for the app's run, `ObserverMemberIDStore`). Call `close()` when its owner ends;
  `leave()` sends `leave` and closes once it has gone.
- `PitchController` owns the engine effects, the match head and the actions this member
  has made that the pitch has not stored yet (`outstanding`), cached control and seat,
  and a 200 ms clock. Its state is lobby, match, versionMismatch, failed or closed.
  Call its `close()` to cancel the clock, remove its observer and close the client.
- `PitchAPI` is the HTTPS API (`report`, `game`, `replay`, `reel`, `share`) and the
  pitch server's `GET /open`. Every request is one call with a deadline and is never
  retried by the client.
- All are main-actor isolated. An engine stays on that actor; it is never marked
  Sendable or passed to a background task.

## Addresses

`PitchConfiguration` (the app) holds one value each:

| What | Production | Debug override | Simulator default |
| --- | --- | --- | --- |
| Pitch server | `wss://throwingwood-pitches.throwingwood.workers.dev` | `PITCH_SERVER_URL` | `ws://127.0.0.1:8797` |
| API | `https://throwingwood.com/api/` | `PITCH_API_URL` | `http://127.0.0.1:8798/api/` |
| Site (links, reels) | `https://throwingwood.com` | `REELS_URL` | `http://127.0.0.1:4322` |

The socket is `<pitch server>/ws?pitch=<code>` with no Origin header and User-Agent
`ThrowingWood/<app version> (ios)`; the open games list is `GET <pitch server>/open`
over HTTPS (HTTP for a `ws:` server). A code outside the server's pattern is refused
before any socket.

## The wire (PROTOCOL.md)

Client messages, in these key orders (`ProtocolTests` checks them against the
protocol's examples):

- `join {member, role, me, v?, n?, seq?, create?}`: `role` is `player` or `observer`;
  `v` the document version held (the pitch leaves the document out when it is the
  same); `n` and `seq` the match and last action held, own actions in flight not
  counted. `me` is the presence: name and `pitch.announce`'s engines (no level)
  (docs/ONLINE.md "Engines in one room").
- `me {me}`; `set {id, base, doc}`, compare-and-set on `base`; `start {id, base, doc,
  n, h, snap, meta}`; `act {id, n, seq, a, h, snap, over?, c: "ios"}`; `cast {d, all?}`;
  `open {open}`; `resync`; `leave`; and the literal text `ping`, answered `pong`.

Server frames that move `s` on by one (`member`, `left`, `host`, `doc`, `start`, `act`)
are taken only in order: one past a gap sends `resync` and nothing past the gap counts
until the `state` comes. A frame before `joined` is ignored.

**Lobby writes.** Updates from one client are serialized. Each reducer sees the current
raw document; a nil result writes nothing. `no` adopts the winner and runs the reducer
again (20 tries). A write unanswered in 10 s reconnects; the next `joined` says whether
it landed (`v` and `by`), and an unchanged version means it did not and it runs again.

**START** is one `start`: the document after it keeps only the match header `{n,
players, cpu, host, engine}` (players as `{A: [{id, name}], B: [...]}`, engine as
major.minor) with `started: true` and the next `n`; `meta` is `{v: 1, setup, engine,
version, players, cpu}`, `engine` the major.minor and `version` the full engine version,
the computer's level inside `setup`. No host in `meta`. A `no` builds it again on the
newer lobby: the first try and at most three more, as the web's pitch.js. A START whose
answer was lost is settled by the next join's match.

**Actions** are never waited for: the next goes at once, before the last one's `ok`.
Each stays in the outbox until its `ok`, and after a reconnect every one goes again
unchanged (same `id`); the pitch answers one it already has with `ok {dup: true}` and the
original `s`. In a resume, a stored act carrying one of this member's pending ids counts
as its `ok`. `refused` drops that act and every later pending one (each follows it), and
the controller goes back to the head and asks for the pitch (`resync`). A peer's act at
the next `seq` is applied and its hash checked; a gap in `seq` or a hash that differs
sends `resync`. The action that ends a match carries `over`; there is no `keep`.

**Host.** The pitch server picks the host and hands it on (PROTOCOL.md section 4);
there is no claim. The host sends `open {seats, state}` whenever either changes, and
afresh when it becomes host (`open: null` for invite only). An observer never hosts.

**Joins and resumes.** `joined` carries the members, the host, `s`, the document (unless
the join's `v` was current) and the match: null; or the actions after the join's `seq`
(up to `resumeMax`), applied and checked here; or, further behind, the whole match from
its head snapshot with its `meta`, adopted.

**Reconnecting** (the web's pitch-client.js tune, `PitchClient.Timing`): the first retry
at a random wait under 300 ms, then 1 s doubling to 10 s, each a quarter either way at
random. `retryNow()` (the device came online, the app became active) skips the wait, or
sends a `ping` on an open socket. `ping` after 20 s with nothing heard, 10 s to answer.
For good, with no more tries: `replaced`, and a join refused as `full`, `no-pitch`,
`bad-member`, `bad-role`, `already-joined` or `bad-message` (`PitchClient.final`). Any
other join error (busy, rate) tries again after the backoff.

## Aim

Sending (`PitchController.castAim`, the web's AimSender): at most 15 a second, only when
the aim changed, as `{t: "aim", s, k, c}`, `k` counting this member's samples and `c` its
clock in ms. The aim just before a release goes at once with `all: true`, which the pitch
never thins. A shout spends a slot, so the two stay under the cast limit.

Drawing (`AimBuffer`, the web's AimBuffer): the clock offset is the smallest
`arrival − ts` over the last 40 casts; the render time is `now − offset − 100 ms`. Between
the two casts around it `x, y, tx, ty, release, tilt, spin, back, mix` go in a straight
line and `arm` (degrees) the short way round, not at all when the two are half a turn or
more apart; the other fields are the earlier cast's. Never across two throws (`seq`) or
two senders; past the newest it holds the newest; a sender's late cast (`k` not newer) is
dropped. A peer's throw waits `min(250, ts + offset + 100 − now)` ms, or none when the
last aim is more than 1.5 s older than the throw (`holdFor`).

## The API (API.md)

- `report(r)`: `POST report {r}`, the report tagged `client: "ios"` and its engine.
  The report names the pitch as `pitch` and takes `match {n, seq}` from the client's
  match head.
- `recordGame(g)`: `POST game {g}`, a one-device solo or watch record (never a shared
  match: the pitch server keeps those).
- `replay(pitch:)`: `GET replay?pitch=`, read as a `KeptReplay` (the kept version, the
  replay's `n` and hash, `sealed`) or nil when none is kept. It starts nothing.
- `reel(pitch:v:)`: `POST reel {pitch, v?}`, read as a `ReelAnswer`: `rendering`,
  `done` (with `ReelFiles`, only paths under `/reels/<code>/` ending `.mp4`), `failed`
  (`render`, `empty`, or `timedOut`), `none` (`unavailable`, `replay`, `engine`, `busy`,
  `moved`) and the errors `too-many` and `failed` (nothing kept, so asking again may start
  it). `v` is a positive integer or left out, never null.
- `share(g)`: `POST share {g}`, read as a `ShareReply` (a code, or why not).
- Refusals are `{error, message}` with a status and are thrown as that `error` code; a
  call that could not be made throws `timeout` or `closed`.

## JSON

`JS` and `ASCIIJSON` write JSON explicitly: UTF-16 units above U+007E become lowercase
backslash-u escapes, emoji become surrogate pairs, controls use JSON.stringify's escapes,
finite doubles use its notation thresholds and non-finite doubles are null. Sizes are
counted on that ASCII text. Engine-produced JSON goes in as `JSONText`/`JS.raw`, never
through JSONEncoder or JSONSerialization. `JSONNode` looks into values while keeping
their exact source spans. A snapshot is an opaque string.

## Pitch effects

All lobby reducers, version checks, seat ownership, control and sync decisions use the
vendored engine's `pitch.*` calls. Swift holds no second copy of those rules. `reduce`
exposes joinTeam, setOptions, setAccess, pruneTeams and backToLobby; host reducers check
host ownership again inside the compare-and-set reducer.

`PitchController` takes an `EngineShelf`: the engines this build carries, one Lua state
per major.minor, the newest made at once and any other the first time a match needs it.
`engine` is the one the pitch runs on now (the match's own, else the newest), and room
calls go to it; `engineFor`, `carried`, `announce`, `speakAs` and `compareEngines` go to
the newest. `announce()` runs after every presence, host and document event and sends
`me` only when the answer changes. START runs lineup, engineFor, speakAs, startCheck,
matchOptions, new and startMatch on the room's engine; with none it refuses, writing
nothing (`mismatch` names the players). A match on an engine this build lacks is watched,
never played.

`take` requires the engine's mayAct for the current need. `frame` can release this
member's dial throw or a host-owned computer throw. Seat and control are cached between
presence ticks and committed actions; no room bridge runs per frame.

## Driving the pitch screen

The presentation callback runs on the main actor. After the controller verifies a peer
action it passes the action and the match to the screen (`remoteTs` carries the pitch's
`ts` for the aim hold); a gap, correction, new match or rejoin passes a snapshot to
restore. `OnlinePitch` (KubbRenderer) owns the controller and a second Lua session for
the board, so the pitch can take several actions while the board is still playing the
first one's recording; the board checks each action's hash and drains its queue in order.

## Verification

- `swift test --package-path ThrowingWoodKit` and the optimized run in AGENTS.md.
  `FakePitch` (Tests/KubbPitchTests) is an in-process pitch server written from
  PROTOCOL.md: members, host succession, `replaced`, compare-and-set, `start`, acts with
  `dup` and refusals, resumes within `resumeMax` or the whole match, casts, `open`,
  `resync` and dropped or deaf sockets. `PitchClientTests`, `PitchTests`, `EnginesTests`
  and `ObserverTests` run real controllers against it: two players in step, actions in
  flight through every socket dropping (each stored once), resume and full adoption,
  a peer first, refusals, hash mismatches, the host handed on, observers.
  `ProtocolTests` checks our messages and the server frames against PROTOCOL.md's
  examples (`Fixtures/protocol-examples.json`); `AimBufferTests` holds the web's aim
  cases; `ReelTests` and `ShareTests` the API answers.
- `LocalPitchServerTests` runs the real `WebSocketTransport`, client and controllers
  against the pitch server's own `wrangler dev` (`npm run dev` in the web repository's
  backend/pitch-server) when `PITCH_LOCAL_URL=ws://127.0.0.1:8797` is set; it refuses
  any host but 127.0.0.1. Two players start a match, the guest drops for two actions and
  resumes by sequence, a watcher joins at the fifth action, and a resign ends it with
  `over`: every hash the same, nothing corrected or adopted, the same finished replay.
  Passed 2026-11-21 against the web's pitch-client branch. The HTTPS API has no local
  stand-in run from Swift yet.
- The old cross-play script (`tools/rooms-test.mjs`) and its probe went with the rooms
  server, and the online review harness (`tools/online-snapshots.py`,
  `online-review.mjs`) with it on 2026-11-21. `tools/room-vectors.mjs` stays: it made
  the JSON codec vectors `VectorTests` still pins (the pitch client sizes a document
  with `ASCIIJSON`), from the web's old client, `src/net/room.js`, which the web's main
  no longer has; to remake them, point it at a web checkout from before the cutover.
