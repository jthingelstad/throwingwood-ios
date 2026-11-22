# Engines the app carries

## The rule

An engine is carried only while we decide it is supported, never because it was once
released (the owner, 2026-11-21: "Let's force all clients to the most recent engine. We
should only support engines that we decide are worth supporting not just ones that have
published so that we can push players to the new engines."). Today that is the newest
alone: 0.13 (v0.13.3, golden corpus 0.13.0, 15 matches). Every match plays on it: solo,
practice and every pitch.

The decision is written in one place, `TAG` and `OLDER` in `scripts/vendor-engine.sh`:
`TAG` is the newest and `OLDER` the older minors we have decided to keep supporting,
one per major.minor. `OLDER` is empty. Moving to a new minor drops the last one unless
we decide otherwise. 0.9, 0.8 and 0.7 went on 2026-11-21 (app 0.8); no client shipped
0.10 to 0.12.

A match still belongs to the engine it was started on, its `match.engine` major.minor,
for its whole life (kubb-engine docs/VERSIONING.md), because a new minor can change how a
throw goes. So a match made on an engine this build does not carry is never played,
replayed or reopened on another one: the app says so in one sentence and nothing around
it breaks ("Looking back at a match" below).

## Vendoring

| Folder | What |
| --- | --- |
| `ThrowingWoodKit/Sources/KubbEngine/Engine/` | the newest (`TAG`) |
| `ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden/` | its golden driver and corpus |
| `ThrowingWoodKit/Sources/KubbEngine/Engines/<major.minor>/` | each of `OLDER`, laid out the same way (none today) |
| `ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/engines/<major.minor>/golden/` | each older one's corpus (none today) |

`scripts/vendor-engine.sh sync` writes every one from its own tag; `check` verifies each
against its own `engine.json` and corpus, fails on an engine folder `OLDER` does not
name, and fails unless `Package.swift` copies `Engines` as a resource exactly when
`OLDER` names an engine. None is ever edited. `GoldenTests` plays every carried engine's
corpus (`pinnedCorpora`).

`sync` also writes `OLDER` as compiled code, `Sources/KubbEngine/Supported.swift`
(`Engine.supportedOlder`), and `check` fails unless it matches. `Engine.carried` takes an
older engine from the bundle only when that list names it, because a built bundle can
outlive the change: SwiftPM never removes a resource folder that Package.swift stopped
copying, so a cached or earlier build kept 0.9, 0.8 and 0.7 in
`ThrowingWoodKit_KubbEngine.bundle` after they were dropped (CI, 2026-11-21). `check`
also fails on such a stale bundle in a local build (`ThrowingWoodKit/.build`, `build/`),
`GoldenTests.theBundleHoldsOnlyTheSupportedEngines` says so in a test run, and CI removes
the built resource bundles after restoring its cache.

## Carrying an older engine again

The machinery stays, so supporting an older minor again is a decision and three edits,
not new code: its tag in `OLDER`, `.copy("Engines")` on the KubbEngine target in
`Package.swift` and its corpus in `pinnedCorpora`, then sync. The app already loads one:

- `Engine.carried` lists the bundle's engines newest first (`Engine/`, then any
  `Engines/<major.minor>/`), `Engine(minor:)` makes one, and each is a Lua state of its
  own, made the first time something needs it (`PitchSession.useEngine`, `EngineShelf`
  in `PitchController`).
- Online, the member announces every engine it carries (`pitch.announce`), the room's
  engine is `pitch.engineFor` of the host and the players, START stamps the match with it,
  and each match plays on its own engine (docs/ONLINE.md "Engines in one room").
- A kept solo match resumes on the engine its own files name, and a shared match on the
  engine its kept replay names.

The session's older-engine fallbacks (no `aim.controls` before 0.9, no `optionsOf` or
`computer` option before 0.9, no scene before 0.9) stay with it: they cost nothing while
no older engine is carried. The bridge says `pitch.`, which only 0.13 on answer, so an
older engine carried again would need its old spelling, `room.` (kubb-engine
docs/VERSIONING.md 0.13.0, "The pitch rename").

## Looking back at a match

A match made on an engine this build does not carry cannot be replayed here. Every place
one can be opened says it in the same sentence, `VersionWords.oldMatch` (the web's
`OLD_REPLAY`): "This match was made on an older version of the game and can no longer be
replayed."

- **A kept unfinished solo match** (a cold launch, or PLAY THE COMPUTER): the save's own
  files name its engine (`MatchSave.engineNamed`: the trail, then the finished-match
  file, each only when it holds the save's hash, FNV-1a of the snapshot, so no engine is
  needed to read it). On an engine not carried, `PitchSession.restore` throws `OldMatch`
  and changes nothing; the app drops the save and its trail (`MatchSave.dropOld`), says
  the sentence over the screen, and PLAY THE COMPUTER opens the options card for a fresh
  match. A save nothing names (a build before the trail) plays on the newest, as it
  always did.
- **A finished solo match reopened on its winner card**: the same, through its
  finished-match file, which goes with it. Its share is refused too
  (`shareableMatch` needs the finished match's engine to be the session's).
- **A shared match opened by its code or link** (a sealed pitch): the kept replay's
  `engine`; one not carried shows the sealed card with the sentence and HOME, and no TRY
  AGAIN (`SealedPitch.Phase.old`).
- **A pitch's match on an engine not carried** (a rejoin, or a peer's START from an older
  build): the controller refuses it (`mayPlay`, the version card); see
  docs/ONLINE.md "Engines in one room".
- **A highlight reel** is made by the server, which answers `engine` ("another version")
  as before.

The tests: `SoloTrailTests` (`aKeptMatchOnAnOlderEngineIsRefused`,
`aFinishedMatchOnAnOlderEngineIsRefused`, `aSharedReplayOnAnOlderEngineIsRefused`,
`theSavesHashIsTheEnginesWithoutAnEngine`), `EnginesTests`
(`aPlayerOnAnOlderEngineIsNamedAndNothingStarts`, `aMatchOnAnOlderEngineIsNeverPlayedHere`)
and `VersionWordsTests`.
