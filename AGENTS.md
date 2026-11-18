# Throwing Wood for iPhone: agent guide

Kubb: Throwing Wood for iPhone. The game itself is
[kubb-engine](https://github.com/jthingelstad/kubb-engine), the Lua rules,
physics and session that the Playdate and the web version
(kubb.thingelstad.xyz, https://throwingwood.com) run too.
`README.md` is the overview for people; this file is the working rules.

`CLAUDE.md` is a symlink to this file. Do not fork them.

## Rules

- **Private, kept clean as if public.** Never commit a team id, an email,
  a local path, keys or signing files. `Config/Signing.local.xcconfig` and
  `Config/AppStoreConnect.local` are ignored by git.
- **Pull requests only** after the first commit. Codex reviews each one.
- **Every upload is Jamie's call.** `scripts/testflight.sh` and
  `scripts/asc.swift` are here for that day; don't run them without Jamie's go.
  Never install to a physical iPhone without it either.
- No third-party Swift packages. No `withTaskGroup` (the optimizer has broken
  one in a sibling app). No analytics.
- Shut the simulators down when done: `xcrun simctl shutdown all`.

## The engine must match the web's, bit for bit

A match on a phone and one in a browser are the same match only if every hash
agrees. So:

- **Lua 5.4.5** (lua/lua at be908a7d, wasmoon 1.16's Lua) in `CLua`, with
  `config/twl_config.h` force-included: a fixed `luai_makeseed`, `system()`
  stubbed (iOS forbids it), and every libm name renamed to musl's.
- **musl 1.2.5's math** in `CMusl`, never Apple's libm: the web's WebAssembly
  uses musl, and Apple's differs in the last bit on some arguments. Each
  public and internal musl symbol is renamed `twm_*` (`include/twm_names.h`,
  force-included in both C targets), so nothing clashes with or falls back to
  Apple's. Both targets build with `-ffp-contract=off -fno-builtin` (no fused
  multiply-add, no compiler-folded maths) and `-fno-modules` (the Darwin
  module map would bring Apple's `math.h` and skip the renames). Don't drop
  any of these flags. CMusl also force-includes `config/twm_musl.h`, which
  turns musl's long double classifier (`__fpclassifyl`, emitted by a Debug
  build from a branch a double never takes) into an inline function of its
  own. `scripts/check-libm.sh` (in CI) builds Debug and release and fails if
  CLua or CMusl references anything Apple's libm exports.
- Update Lua or musl only with `scripts/vendor-c.sh <lua dir> <musl dir>`, and
  record the source and its sha256 in the target's `NOTICE.md`.
- **The game's Lua** comes from a tagged release of kubb-engine, named once,
  `TAG` in `scripts/vendor-engine.sh`. `sync` copies that tag's tree (never
  the working tree) from the kubb-engine checkout beside this one
  (`KUBB_ENGINE_SOURCE` overrides) byte for byte: `core/`, `room/`,
  `session/`, `tune/`, `version.lua`, `engine.json` and `LICENSE` into
  `ThrowingWoodKit/Sources/KubbEngine/Engine/`, and the engine's golden
  driver and corpus (`tests/golden/drive.lua`, `hashes.json`) into
  `Tests/KubbEngineTests/Fixtures/golden/`. `check` (in CI, no checkout
  needed) verifies every file against the engine's own `engine.json`, and
  the version against the tag (v0.4.1 explicitly retains the 0.2.0
  golden corpus; arbitrary older corpora are not accepted). Never edit the
  vendored files; a fix belongs
  in kubb-engine, then here by moving to its next tag. Never write in the
  kubb-engine checkout from here.
- **Moving to a new engine release:** set `TAG`, run
  `scripts/vendor-engine.sh sync`, then all three test runs below (macOS
  Debug, release and the simulator). Every golden action must match on each.
  A golden test that fails is a determinism bug, never a fixture to
  regenerate around: the corpus is the engine's, made on its reference
  platform (kubb-engine docs/DETERMINISM.md). A minor or major engine
  version may change hashes or formats (kubb-engine docs/VERSIONING.md):
  read its changes before moving.
- **Starting the engine.** `Engine(appVersion:)` boots through
  `session/api`, then makes the host's calls before any match:
  `engineVersion` (it must equal `engine.json`'s), `useTune {name =
  "pointer"}` (the iPhone dial) and `setClient {label =
  "ios <app version>"}`.
- **The maths probe.** `Fixtures/math-probe.json` holds arguments where
  Apple's libm and musl's differ in the last bit, with the web's answers;
  `mathIsTheWebsMath` checks the engine gives those.

## Testing

- `swift test --package-path ThrowingWoodKit`, and optimized:
  `swift test -c release -Xswiftc -enable-testing --package-path ThrowingWoodKit`.
- On the simulator: `cd ThrowingWoodKit && xcodebuild test -scheme ThrowingWoodKit-Package
  -destination 'platform=iOS Simulator,name=iPhone 17'`.
- The app: `xcodebuild -project ThrowingWood.xcodeproj -scheme ThrowingWood
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- `scripts/check-libm.sh`: no Apple libm in the engine's C, Debug and release.
- CI (`.github/workflows/test.yml`) runs these on `macos-26`. macOS minutes
  cost money on a private repo: add jobs only for a reason.

## Proving Apple's libm fails (manual, not CI)

The golden tests mean something only if Apple's libm would fail them. To see
it, build Lua on Apple's libm in a scratch build of its own and run them:

```sh
cd ThrowingWoodKit
KUBB_APPLE_LIBM_PROOF=1 swift test -c release -Xswiftc -enable-testing \
  -Xcc -DTWL_APPLE_LIBM --scratch-path .build/apple-libm
rm -rf .build/apple-libm
```

It must fail: `appleLibmDiffersOnTheProbe` shows Apple's answer differs on
the probes, `mathIsTheWebsMath` fails on them, and every golden match leaves
the corpus within a few actions (engine 0.2.0, 2026-11-17: all 22 probes
differ, 75 of 453 actions agree before each match's first difference, the
same as kubb-engine measures with desktop Lua). It is not in CI because a
new Apple libm could round these arguments musl's way.

## Pitch renderer, practice and solo

`KubbRenderer` owns the pure Core Graphics picture, the shared projection for hit
testing, and main-actor `PitchSession` (also exposed as `PracticePitch`). Keep physics, cameras, slow motion and
verdicts in the tagged session. Read [docs/RENDER.md](docs/RENDER.md) before
changing projection, recording interpolation, input or review fixtures. The app
uses the pointer dial through `ThrowInput`. Compare all five snapshots and the
independent practice throw locally with the usual Kit tests. The web checkout is
read-only when generating review pictures. Keep synthetic scenes free of names.

Read [docs/MATCH.md](docs/MATCH.md) before changing solo flow or persistence.
The six option lists come from the pinned engine. Store the raw snapshot after
each action, including a release before the throw has finished playing.
The solo host uses the pointer dial. The simulator-only card and HUD tests
use synthetic checkpoints and both iOS 26.2 review phones. Run
`python3 tools/solo-snapshots.py <simulator-app>` locally. Review changes to
both the 16e and Pro Max pictures before replacing either set.

## Rooms and the online screen

`KubbRooms` is the main-actor room client and headless pitch controller; its contract
is `docs/ROOMS-CLIENT.md`. Lobby, seat and sync rules are exclusively the engine's
`room.*` API. Keep engine JSON as raw text. Use the tagged record/report helpers.
Close the controller/client when its owner ends.

Read [docs/ONLINE.md](docs/ONLINE.md) for the screen, recording and lifecycle contract.
OnlinePitch connects the authoritative controller to a separately paced PitchSession.
Keep admission and seat decisions in room.*. Keep all simulator, script and review
sockets on 127.0.0.1. Use the numeric ROOMS_DEV_PORT for simulator review.
Run `python3 tools/online-snapshots.py <simulator-app> --web <web checkout>`
on both review phones. Only invented names belong in these pictures.

Local wire conformance and three complete cross-play matches run with
`swift build --package-path ThrowingWoodKit --product RoomsProbe` then
`node tools/rooms-test.mjs` (or `--web <web checkout>`). The script imports the web's
client and rooms-dev read-only, binds an ephemeral 127.0.0.1 port and writes only
`build/rooms-results.json` here. Never point tests at production. Regenerate wire
vectors with `node tools/room-vectors.mjs`; committed vectors and injected Swift tests
run in the existing macOS CI job, without an additional cross-repository checkout.


## Sound and haptics

Read [docs/FEEL.md](docs/FEEL.md) for engine events, sample provenance,
pattern values and the simulator timing probe. Keep input cues on ThrowInput,
recording cues on the shown-time clock and match cues on the presented need.
Keep SOUND and HAPTICS independent. Measure warm mixer onset on the simulator
after changing the audio graph. Actual haptic feel requires a physical phone.
