# Throwing Wood for iPhone: agent guide

Kubb: Throwing Wood for iPhone. The game itself is
[kubb-engine](https://github.com/jthingelstad/kubb-engine), the Lua rules,
physics and session that the Playdate and the web version
(kubb.thingelstad.xyz, https://throwingwood.com) run too.
`README.md` is the overview for people; this file is the working rules.

`CLAUDE.md` is a symlink to this file. Do not fork them.

## Rules

- **This repository is public.** Never commit a team id, an email,
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
  golden corpus, v0.5.1, v0.7.1 and v0.7.2 the 0.5.0 one; arbitrary older corpora are not accepted). Never edit the
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
- CI (`.github/workflows/test.yml`) runs these on `macos-26`. Add jobs only for a reason.

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
Where the thrower stands is STAND, a plate in the plan (`StandPad.swift`, the
web's stand-pad.js numbers and words); WALK, the Playdate's held A, is gone.
A raise is a touch on the kubb (`RaiseTouch.swift`, the web's raise-touch.js
numbers), and Raising (by hand or automatic) is the match's choice, never a
device setting. SEND FEEDBACK sends a throw report (`kind: "throw"`) or
anything else (`kind: "feedback"`), the web's wire.
The six option lists come from the pinned engine. Store the raw snapshot after
each action, including a release before the throw has finished playing.
The solo host uses the pointer dial. The simulator-only card and HUD tests
use synthetic checkpoints and both iOS 26.2 review phones. Run
`python3 tools/solo-snapshots.py <simulator-app>` locally. Review changes to
both the 16e and Pro Max pictures before replacing either set.

## The meter

The throw's meter is the player's choice (Jamie, 2026-11-19: "I'm considering
a player preference for a circular meter (clock) versus a linear meter ... The
logic is the same to me. Just a choice if you want to spin your thumb or crank
-- or use a different hand to flick."): Meter, Clock or Linear, and Side, Left
or Right ("Left and right handed folks may want it on one side or the other"),
kept on the device. The clock is the default and is never retired. Both feed
the same arm degrees through `ThrowInput`: never give a meter an engine change
of its own. The linear meter must keep its room: the straight trial of
2026-11-18 went because "it was too cramped and visually looked janky", so an
upright screen that cannot give its track 320 pt shows the clock. The choice
holds when the phone turns: on a wide screen the track has the whole safe
height at its edge and needs 260 pt (`wideMinTravel`), which every iPhone on
its side has. The finger and the
meter apart ("if you can have the control and the touch be slightly distant
from each other, that could make that better"): a drag in the throw zone
(the lower 40% upright, the meter's half on a wide screen) strokes the linear knob and a press beside the clock's ring turns its arm,
while a tap there still aims. On a wide screen the linear body is throw zone
too (it stands over the far baseline's outer kubb): a tap on it aims, a drag
strokes, and only the knob's channel grabs at once. The nudge ("Have the UI show it not a separate
how to page.") draws on the meter itself and is never fed to the engine, and so
does the coach line (`Coach.swift`, the web's coach.js: a few words over the
prompt for a device under 3 throws, or after a SLOW flick). Keep the linear
meter (390 to 450 pt tall), the touch rules, the nudge's numbers and the coach's
lines and placement the same as the web's. Review tools launch with
`-pitch.throwsMade 9` so the coach stays out of other pictures.
docs/RENDER.md "The meter".

## A phone on its side

The app turns to landscape left and right as well as portrait, never upside
down (Jamie, 2026-11-19: "Given we have a widescreen view for web, can we
extend that to support iPhone rotated display?"). On its side the match is the
web's wide arrangement from its layout.js, in `KubbRenderer/WideLayout.swift`:
keep its numbers the web's, keep every frame inside the safe area (the
`WideLayoutTests` check both review phones, both meters, both sides), and keep
the thrower's camera. Linear chosen is the linear meter on its side too
(Jamie, 2026-11-19: "Bug: On iPhone if I turn on linear and then rotate it goes
back to the circular swing."): its box runs from 10 pt under the safe top to
7 pt over the safe bottom (at most 450), its track at least 260 pt (265.3 on
the 375 pt phones, 331.3 on the 17 Pro Max), and MENU or the rail moves in
beside it, 10 pt off its body. The coach line hangs under its tab there. Two hands (Jamie, 2026-11-19: "in landscape the
tilt, arc, stand controls should be pushed to the left hand side of the screen
so the user can control those with the left hand and the throw with the right
hand"): the plan block sits at the edge away from the meter, 8 pt inside the
safe area with TILT and STAND at the screen's edge, its foot 10 pt above the
meter box's, the minimap 12 pt on its inner side, and back beside the clock
only if the minimap would come within 24 pt of the centre (`WideLayout.plan`,
the web's planAt). Beside the linear meter the block never goes back over the
prompt tab: it stays at the far edge and the minimap goes over it, or is not
drawn where there is no room (a narrow, short iPad window). The raise and punishment panel is a bar along the bottom
(`WideLayout.bar`, the web's game.css panel): it must never cover the kubb
being raised, its numbers, a press or drag on it, or the ground a punishment
kubb may go on, so the app reports the bar's measured height
(`PitchSession.stillFloor`) and the scene moves up only by any shortfall
(`WideLayout.stillLift`, `StillBarTests`). A bounds change mid-gesture cancels the held
gesture (`BoardView.layoutSubviews`, `PitchSession.cancelHeld`). Cards taller
than about 390 pt use `FitOrScroll`. The review tools take `--landscape left|right`
(`<phone>-landscape-*.png`); review both phones on their side as well as
upright. docs/RENDER.md "A phone on its side".

## An iPad

The app is universal: an iPad plays the same game on a bigger screen (Jamie:
"The idea of an iPad version would just be to give us a little bit bigger
screen."). No new controls, no other camera, no split views. An iPad turns all
four ways; an iPhone keeps portrait and landscape left and right. iPadOS 26
resizes every app's window, so lay out from the window's size, never the
device's: a tall window is the upright phone, any other the wide arrangement
above, with the linear meter where its track has 320 pt upright or 260 pt
wide (450 pt on an iPad on its side, on the bottom margin as before) and the raise and punishment bar only when `WideLayout.isShort`.
Controls keep their phone sizes. Cards keep the web's widths and stay centred
(the sheet 640, the tall panel 520, Send feedback 560, on an iPad).
`WindowControls.swift` keeps the rail clear of a window's close, minimise and
full screen controls; full screen and every iPhone add nothing.
`WideLayoutTests` check both review iPads and sweep window sizes. The review
tools take `--ipad` (the iPad mini and iPad Pro 13-inch, `ipad-*.png`); an iPad
turns as a device through `tools/review_turn.py` (a UI-test bundle in
`tools/review-turn`, simulator only). A simulator left in Windowed Apps or
resized may stop turning until it is shut down; the tool says so. Review the
iPads upright and on their side as well as the phones. docs/RENDER.md "An iPad".

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
