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
- **The version a player sees** is `<app version> (<engine version>)`, e.g.
  `0.2 (0.8.1)` or `1.0.0 (1.0.0)`, built in one place, `VersionLabel` (KubbRenderer): `VERSION`
  (the marketing version) and the newest carried engine's `engineVersion`, read
  from the engine, never typed. Nothing else goes in the parentheses: the build
  number is a detail line (`build 114`), and so would be any older engine carried
  (`Also plays 0.7.4`; none today). It is at the foot of the match, pitch and practice menus
  and in a feedback report's `build.label`. It never goes on the pitch wire, a
  rider, a kept match or a shared replay, which name only the engine a match is
  played on. Bump `VERSION` and `MARKETING_VERSION` together; the build number
  is the TestFlight script's.

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
  (`KUBB_ENGINE_SOURCE` overrides) byte for byte: `core/`, `pitch/` (0.13
  on) or `room/` (before), `session/`, `tune/`, `version.lua`, `engine.json`
  and `LICENSE` into
  `ThrowingWoodKit/Sources/KubbEngine/Engine/`, and the engine's golden
  driver and corpus (`tests/golden/drive.lua`, `hashes.json`) into
  `Tests/KubbEngineTests/Fixtures/golden/`. `check` (in CI, no checkout
  needed) verifies every file against the engine's own `engine.json`, and
  the version against the tag (v0.4.1 explicitly retains the 0.2.0
  golden corpus, v0.5.1 and v0.7.1 to v0.7.4 the 0.5.0 one, v0.8.1 and v0.8.2 the 0.8.0 one, v0.13.1 to v0.13.4 the 0.13.0 one;
  v0.15.0 carries its own, 19 matches, and v0.15.1 keeps it; v0.16.0 its own, 19
  matches and 724 actions; v0.18.0 its own, 21 matches and 854 actions; v1.0.0, the
  released engine, its own, 21 matches and 880 actions;
  arbitrary older corpora are not accepted). Never edit the
  vendored files; a fix belongs
  in kubb-engine, then here by moving to its next tag. Never write in the
  kubb-engine checkout from here.
- **Only the engines we decide to support.** An engine is carried only while we
  decide it is supported, never because it was once released (the owner,
  2026-11-21: "We should only support engines that we decide are worth supporting
  not just ones that have published so that we can push players to the new
  engines."). Today that is the newest alone. The decision is written in one place,
  `TAG` and `OLDER` in `scripts/vendor-engine.sh`: `OLDER` names any older minor we
  keep (none; `check` fails on an engine folder it does not name, and unless
  `Package.swift` copies `Engines` exactly when it names one; `sync` writes it as
  compiled code too, `Supported.swift`, so a stale bundle never adds an engine). A match belongs to
  the engine it was started on (its `match.engine` major.minor), so a match on an
  engine this build does not carry is never played, replayed or reopened on another:
  every place one can be opened says `VersionWords.oldMatch` and breaks nothing
  around it, and a pitch with a player on an older or newer build says who must
  update (`VersionWords`, the web's words; docs/ENGINES.md "Looking back at a
  match", docs/ONLINE.md "Engines in one room"). The per-engine loader stays
  (`Engine.carried`, `EngineShelf`, `PitchSession.useEngine`), so carrying an older
  engine again is a decision and three edits (docs/ENGINES.md). `GoldenTests` pins
  each carried engine to its corpus (`pinnedCorpora`). A new minor: set `TAG`, sync;
  the old minor goes with it.
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
  "ios <app version>", location = "throwingwood.com"}` (the game file's
  Location line, as on the web; in no snapshot, document or hash).
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
- CI (`.github/workflows/test.yml`) runs these on `macos-26`, all but the simulator's
  test run, with `scripts/vendor-engine.sh check` and `scripts/version.sh test` before
  them; both `swift test` runs go through `scripts/test-watch.sh`, which fails a run
  still going after `WATCH_SECONDS` (480) and prints where each test process is stuck.
  Add jobs only for a reason.

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
device setting. Raises the app sends or receives as actions are watched (the owner, 2026-11-22: "When you hit
auto to raise kubbs you should watch the computer raise them."): AUTO, AUTO ALL, REST OF
GAME, the menu's Raising: Automatic and another member's raises online tip each kubb up in
the raise scene one after another from the need's own poses (`RaiseShow` in AutoRaise.swift;
`Pacing.raiseBeat`), a tap skips to the end, and the engine's actions and their order never
change. The raises the engine makes itself (the computer's, a match started with Raising:
Automatic) and the punishment kubbs it places are watched too, from engine 0.16.0's list on
the next throw need, `need.setup.settled` (`StoodShow.engineRaised`): in its order, with the
watched raise's tip and pace, in the frame it gives (the raiser's view frame; the world frame
in the wide view), round each its entry's own `others` and `king` (engine 0.17 on; the king
alone in the thrower's view for an entry without them). Each such raise ends on its entry's `seat`
(engine 1.0.0: a standing kubb leans up to 3 degrees in the turf), settling into it as it
slides to its spot, so the kubb does not step at the next throw's first frame; a raise the app
sends itself ends plumb and takes its seat on the next throw. Never compare pieces before and
after or turn a pose between frames in Swift to find them. The raise
camera stands twice as far back as it did (`RaiseCamera`, the web's numbers). The last
throw's verdict never stops a player aiming: it takes no touches, goes at the first press
of the aim or after `Pacing.verdictShown`, and stands clear of the target
(`WideLayout.verdictBand`, `verdictClear`); a tall screen puts the far baseline at 41% of
its height (`PitchProjection.anchorAt`). docs/MATCH.md, docs/RENDER.md.
SEND FEEDBACK sends a throw report (`kind: "throw"`) or anything else (`kind: "feedback"`), the web's wire.
The six option lists come from the pinned engine (Computer among them on 0.9). Store the raw snapshot after
each action, including a release before the throw has finished playing.
The solo host uses the pointer dial. The simulator-only card and HUD tests
use synthetic checkpoints and both iOS 26.2 review phones. The review set
(docs/review) is retaken from a Release simulator build one group a command,
`tools/review-set.sh <group>` (phones, phones-side, ipads, ipads-side, scenes,
scenes-side, scenes-ipad, ax3, meters, share, reel, raises, tournament; docs/RENDER.md
"Retaking the review set"), the App Store pictures (docs/store) with
`tools/store-snapshots.sh`, and the App Store preview, real play filmed in the app with
no review mode, with `tools/store-previews.py` (docs/DISTRIBUTION.md "App previews"). Look at every picture a retake changes, on both the 16e
and the Pro Max, before committing it.

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
prompt for a device under 3 throws, or after a SLOW flick, naming the marks by shape:
"the stripes", "the solid mark"). Keep the linear
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
the thrower's camera. MENU is a word inside the header's plate there too (the 1.0
design: "MENU never leaves it"); online SHOUT takes the top right. Linear chosen is the
linear meter on its side too
(Jamie, 2026-11-19: "Bug: On iPhone if I turn on linear and then rotate it goes
back to the circular swing."): its box runs from 10 pt under the safe top to
7 pt over the safe bottom (at most 450), its track at least 260 pt (265.3 on
the 375 pt phones, 331.3 on the 17 Pro Max), and the header (meter at the left) or
SHOUT (at the right) moves in beside it, 10 pt off its body. The coach line hangs under its tab there. Two hands (Jamie, 2026-11-19: "in landscape the
tilt, arc, stand controls should be pushed to the left hand side of the screen
so the user can control those with the left hand and the throw with the right
hand"): the set-up tray sits at the edge away from the meter, 12 pt inside the
safe area, its foot 10 pt above the meter box's foot, and the minimap under the
header's right end (`WideLayout.plan`, the web's trayAt; the 1.0 tray, "The 1.0 design"
below). The header takes the web's width there (0.4 W, at least min(300, 0.4 W), at
most 400, short of the throwing line where it can), so the minimap stays off it. The caption strip
never goes under 112 pt (`WideLayout.captionMin`): where the strip beside SHOUT
cannot give that, the captions take a line of their own under the header row,
clear of the meter, the tray (and all an open plate may take), tab and coach line, never the clock instead. The raise and punishment panel is a bar along the bottom
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

## The pitch and the online screen

`KubbPitch` is the main-actor pitch server client (`PitchClient`), the HTTPS API
client (`PitchAPI`) and the headless pitch controller (`PitchController`); its contract
is `docs/ROOMS-CLIENT.md`. The references are the web repository's
`backend/pitch-server/PROTOCOL.md` and `backend/api/API.md`, and its docs/MULTIPLAYER.md section
"What the iPhone app mirrors": keep those the same as the web (the message flow, the
start `meta` and document header, the reconnect timings, the aim rules, the pace). New
code says "pitch", and so does the bridge: the engine's `pitch.*` calls (`room.` was
their old spelling, which only engines before 0.13 needed). Lobby, seat and sync rules
are exclusively the engine's `pitch.*` API. Keep engine JSON as raw text. Use the
tagged record/report helpers. Close the controller/client when its owner ends.

The addresses are `PitchConfiguration`, one value each (pitch server, API, site), with a
Debug override (`PITCH_SERVER_URL`, `PITCH_API_URL`, `REELS_URL`) and 127.0.0.1 on the
simulator. Never point tests at production: no connection to throwingwood.com's `/ws`
or the live API from a test or a review tool. The pace between actions is `Pacing`
(KubbRenderer), the web's src/game/pacing.js; change it in one place, on both.

Read [docs/ONLINE.md](docs/ONLINE.md) for the screen, recording and lifecycle contract.
OnlinePitch connects the authoritative controller to a separately paced PitchSession;
someone else's turn shows its hand-off as a banner over the live dial, never the modal
card. Keep admission and seat decisions in pitch.*. Keep all simulator, script and review
sockets on 127.0.0.1. The online review pictures (docs/review/online, docs/review/observer)
are the last ones the old rooms harness made; it went with the rooms server on 2026-11-21,
and a harness that seats its players on the pitch server's `wrangler dev` is open (the
app's simulator checkpoints, `OnlineReview.swift`, stay for it). Only invented names
belong in these pictures.
The highlight reel card (`ReelCard.swift`, `HighlightReel`, the API's `replay` and
`reel`) takes a pitch code, and the match when it has one, and keeps the web's
docs/REEL.md words; its pictures come from
`python3 tools/reel-snapshots.py <simulator-app> --videos <dir>` (docs/ONLINE.md
"The highlight reel"). Never point it at production while testing.
Sharing a finished match against the computer (`ShareCard.swift`, `SoloShare`,
`KubbPitch/Share.swift`) keeps the web's docs/REEL.md "The share card" words and
reducer, and the web's share `g` byte for byte but for `client: "ios"`
(`Fixtures/share-vectors.json`, from `node tools/share-vectors.mjs --web <web checkout>`),
sent as the API's `POST share`. Nothing is sent before SHARE AND MAKE THE REEL, and
nothing about the device beyond `client`. A sealed pitch shows its winner card from its
kept replay. Pictures: `python3 tools/share-snapshots.py <simulator-app>`, upright,
`--landscape left` and `--ipad`, kept in docs/review/share (`tools/review-set.sh share`;
docs/ONLINE.md "Sharing a match against the computer").
Never send a real share.

The Kit's tests run the real client and controller against `FakePitch`, an in-process
pitch server written from PROTOCOL.md, in the existing macOS CI job. A run against the
pitch server's own `wrangler dev` stays local and on 127.0.0.1: start it from the web
repository's backend/pitch-server (`npm run dev`, port 8797), then
`PITCH_LOCAL_URL=ws://127.0.0.1:8797 swift test --package-path ThrowingWoodKit --filter
LocalPitchServerTests` (off without the variable, and it refuses any other host).


## Computer players

A team on a pitch may hold computer players beside its people, six a team together, each
at its own level (engine 0.17, kubb-engine docs/PITCH.md "Computer seats"; the owner,
2026-11-22: "in online play we should be able to add computer players to the match, with a
specified level."). The host's ADD COMPUTER per team, a seat's level bar, ↑ ↓, TO A / TO B
and REMOVE call the engine's `addComputer`, `setComputerLevel`, `moveComputer` and
`removeComputer` through `PitchController`, which decide every rule; the app decides
nothing. The words and numbers are the web's (its docs/SYSTEM.md "Computer seats"),
`SeatWords`. `engineFor` is asked with the document as it is (engine 1.0.0 leaves seats out
itself; the app's `withoutSeats` went with 0.18). A
match's computer players are the host's device's, as a computer side is. docs/ONLINE.md
"Computer players".

## Observers and the free camera

Anyone may watch an open game (Jamie: "I want to allow an observer to view open
games that people are playing... In observer mode you should be able to fly around
and position your view wherever you want to be."). The web (docs/OBSERVER.md) is the
reference: keep its numbers, words and rules. An observer (`?observe=1`, WATCH in
the Open games list, the pitch server's `GET /open`) joins with the `observer` role:
a member with no seat that never acts, never writes the document and never casts. The
pitch server never makes it host, so there is nothing to claim or step back from. It
joins with a member id of its own, never the player's (`ObserverMemberIDStore`), or a
host watching its own pitch would stall it. Every watcher
gets the engine's wide view and the free camera (`FreeCamera.swift`), whose
camera must stay core/camera.lua's lookAt (`FreeCameraTests`); players keep the
thrower's view. The app has no replay viewer, so no WATCH THE LAST MATCH.
Pictures: docs/review/observer (modes observe, observemoved, watchcard, noGame,
opengames), from the old rooms harness until a pitch server one is made (above).
docs/ONLINE.md "Observers and open games",
docs/RENDER.md "The watcher's wide view".

## Levels are the computer's

From engine 0.13 a level (Beginner, Club, Pro) is the computer's standard only and
every person throws on one meter, its bars going by the throw's distance (the owner,
2026-11-21: "player level really should only mean for the computer opponent. It
doesn't mean anything for the human player."; kubb-engine docs/notes/throw.md "The
person's meter"). So the app has no level of the player's own on any screen: no
Your level in Settings, no level on the solo options card's or the lobby's line
(`PlayerLine`: the name row), and no words that present a level
as the player's difficulty (`ThrowLevelTests`). The computer's level stays a
per-game choice: the options card's Computer level and the lobby's Computer, the
match's `computer` option (kubb-engine docs/SESSION.md `newMatch`), kept per game in
`solo.option.computer` (read from the older `solo.option.level` once).

With only the newest engine carried (docs/ENGINES.md) nothing reads a person's level,
so the app keeps none and sends none (2026-11-21): no `pitch.throwLevel`, no level on
the solo player's entry, no `setLevel` for practice or a throw, no `level` in the pitch
member's presence. The engine and the pitch server need none: a lineup takes "club"
for a member that names none (pitch/lobby.lua `matchOptions`), and the pitch server's
`me` is free-form. A stored `pitch.throwLevel` from an earlier build is left unread.

## Names are generated

No name is typed anywhere (the owner, 2026-11-21; kubb-engine docs/NAMES.md): a typed
name others can see is user-generated content, which App Store review would want
report and block tools for. Every player and team name is made from the engine's word
lists through its `names.*` calls (`Names` in KubbPitch, the web's src/game/names.js),
and kept and sent as its text. The web (src/ui/name-row.js, src/net/pitch.js) is the
reference: keep its words, order and behaviour.

- **The device's name** (`PlayerName`, `pitch.name`): the first run rolls one from the
  system's random source and keeps it; a kept text that is not a generated player name
  (a typed name from before, or a default) is replaced on load and never shown.
- **The name row** (`NameRowModel`, drawn by `NameRowView`; the 1.0 design): the name
  and SHUFFLE on one line, and no KEEP anywhere (the owner, 2026-11-21: "KEEP goes from
  the name row"); SHUFFLE rolls a whole new name. Settings alone adds a stepper per word
  (`NameSteppers`: previous, the word, next, the engine's `names.step`). VoiceOver: the
  group "Your name" ("Name on the reel", "Team A's name"), "Shuffle your name", each
  stepper "First word" with "Previous first word", "Your name, first word" (adjustable,
  the word its value) and "Next first word", and a change announced as "Your name:
  Mighty Maple" (`NameRowTests`). It is in Settings, the solo card's and the lobby's You
  row, under a lobby side of several as PLAYS AS (the host's row; others read the name)
  and on the share card.
- **What comes from someone else is judged by the engine, whole** (engine 0.13.4,
  `names.check`; never read a snapshot's or a replay's fields to judge its names): a
  pitch's snapshot through `restore`'s strict door (`{ snap, names: "check" }`, in
  `PitchController.begin` and `OnlinePitch.restore`), a shared replay through
  `names.check({ replay })` and the strict door (`PitchSession.restoreFromOutside`), the
  lobby through `names.check({ document, members })`, a share's start through
  `renameStart` and `names.check({ replay })`. A refused member is "Player n", a team
  "Team A" / "Team B", two alike in a lobby "Mighty Maple II"; a refused match is not
  shown ("Cannot show this match", `NameWords`). The device's own kept match resumes
  with the plain `restore` (typed names from before stay, seen only by its player).
  `names.valid` stays for a single name. Never show a refusal's `from` or `text`. The
  host checks every name before START and writes team names to the document's top-level
  `teamNames`; the app never sends a typed name, and a `bad-name` refusal reads as any
  refused write.
- **Fit**: every name from `names.all` is measured in the app's fonts (`NameFitTests`).

docs/ONLINE.md "Names", docs/MATCH.md.

## Where a setting lives

Each setting lives where the owner's scopes put it (his sheet, 2026-11-20). The
device's (Your name, Sound, Haptics, Meter, Meter side, App icon) are together on
one Settings card (`SettingsCard`), reached from home and from inside every match (the
match and pitch menus' SETTINGS, the practice menu's Settings); no other screen makes
their controls, but for the name: the device's name row is in Settings and in a set-up
screen's You row (`PlayerLine`, the solo card and the lobby), as on the web ("Names are
generated"). The game's are the match options and nowhere else: the solo
options card, the practice menu (Surface, kept as `pitch.practiceSurface`, and
Scene) and the lobby, whose options a host's next pitch opens with
(`pitch.hostOptions`, docs/ONLINE.md). Raising part way stays in the match menu
(Raising) and the raise panel (REST OF GAME). A turn's and a throw's settings are on the
throw controls and the engine keeps them for their scope. `SettingsScopesTests`
checks this; keep it passing when a setting is added.

## Scenes

A scene is the engine's (core/scenes, engine 0.14; Jamie, 2026-11-21: "a Scene should
have an allowed set of surfaces and pitch types"): it decides a match's surface and kubb
set, and the app draws the world, the controls' skin and the throw's effects for it. It
never changes a throw's physics or a hash beyond what its surface does. Seven, the
engine's names (kubb-engine docs/notes/scenes.md): Park (`day`, the default), Beach,
Camping (`night`: a real pitch at night under a full moon), Techno (`neon`: our own
black world on a grid of light, no film names), Minnesota, Tournament and Black & White
(`bw`, the Playdate's look). The web is the reference: keep its numbers and colours
(`SceneRenderer.swift`, `SceneWorlds.swift`, `SceneEffects.swift`, `Impacts.swift`,
`SceneSkin.swift`). docs/RENDER.md "Scenes" has each look.

- **The catalogue** is the engine's; `SceneID.catalogue` is the app's copy for the
  renderer, held to the engine's `scenes()` by a test. `SceneID.drawn` lists the scenes
  this build draws besides the day (the other six: all seven are drawn).
- **The options cards are scene first** (the engine's `pitch.optionRows({ scene })`):
  the solo card (`SoloOptions.cardRows`), the practice menu and the lobby (the room's
  `settings.scene`) show Scene first, Surface only where the scene leaves one (Black &
  White), no Kubbs row. `scene` goes with every `new` and every lobby `setOptions`;
  kept options (`solo.option.*`, `pitch.practiceScene`, `pitch.hostOptions`) go through
  the scene. Never a Scene row in the match menu.
- **An unknown id** draws as the day and is carried untouched (`SceneID.shown`).
- **Everything that shows a match follows its scene** (`GameModel.shownScene`):
  play, watching, a reopened match, the replay and the winner card. Home, the
  online entry and Settings from home are the day.
- **The skin.** Every control takes the scene's colours from `SceneSkin` through
  `SkinStore`; each pair of words and ground is 7:1 or better (`SceneSkinTests`).
  The day is the 1.0 system's tokens ("The 1.0 design" below, `DesignTests`); the
  pitch's own day picture (`PitchRenderer`, its five snapshots) does not move.
- **The Tournament's neighbours are live** (engine 0.15.1; `TournamentNeighbours`,
  Neighbours.swift): a second engine of their own (`Engine.neighbours()`: its own Lua
  state, the host's clock `__kubbClock` as a C function of the Swift target, no `useTune`)
  on a queue of its own, never the player's engine's and never waited on by the main
  thread. Open (`neighbours.open`, the match's seed, the grid in every layout) only
  for a match, practice or watched match in the Tournament scene, closed on leaving it or
  in the background, never under Reduce Motion (the four fixed pitches then, and no second
  engine). `advance` once a frame on the match clock with `budgetMs: 2`; a failure leaves
  them standing. Recordings play through `Playback`; the field turns with Team B's view. No
  people anywhere in the Tournament (the owner, 2026-11-22: "Tournament mode should not have
  people. Just pitches with live play."): a thrown piece shows once it is in the air and
  kubbs a beat stands up rise one after another (`Calm`). No names and no haptics; their
  sounds are quiet and far (`NeighbourSounds`, docs/FEEL.md "The other pitches"). The web
  is the reference for numbers and behaviour. docs/RENDER.md "The Tournament's neighbours"
  has the rules and the cost; `NeighbourTests`.
- **Ground impacts** are on (`setImpacts`): Techno rings at each `timeline.impacts`
  entry (and taps lightly), Beach puffs sand and Minnesota sprays snow.
- **Black & White is one bit**: every pixel black or white (`Painter.mono`, no
  antialiasing), its skin black and white, the dimming a checker (`SkinDim`).
- **A spin the frames cannot show** is drawn as one (`Spin.swift`): never touch the
  physics for how a throw looks.
- **Reduce Motion** calms the effects: no trail or ribbon, fewer and shorter puffs,
  no hit flash, rings that do not grow, no falling snow.
- Review pictures take `--scene <id>` on the solo and online tools
  (`<phone>-<scene>-<shot>.png`; the `scenes`, `scenes-side`, `scenes-ipad` and
  `tournament` groups of `tools/review-set.sh`). docs/RENDER.md "Scenes".
- **The app icon** is each scene's own king, drawn by the renderer (`AppIconArt`, the
  owner's direction of 2026-11-22): Park the primary with dark and tinted looks, the other six
  scenes alternates picked in Settings' App icon row (three a row), each on its scene's own ground and kubb set. Never edit the PNGs: change
  `AppIconArt` and run `scripts/make-app-icons.sh`. A new scene's icon is one line in
  `AppIconArt.icons` (`AppIconTests`). docs/RENDER.md "The app icon".

## Kid matches

The Kid computer makes a Kid match (engine 0.15, kubb-engine docs/notes/kid-mode.md); the
engine does the rules. The app offers Kid first on the Computer row (the engine's), draws
the Kid line (`aim.kidY`) in every renderer and the minimap, words STAND for it, says
"Kid match" from `need.kid` (`HandoffWords.kid`), and shows a Kid ruling's flag
(`ThrowResult.shownFlag`). Nothing may tell a child they were punished or lost when they
were not (`KidTests`). docs/MATCH.md.

## The drive

Engine 0.16 lets a baton be thrown flat or down and hard into a group (the owner, 2026-11-22:
"We need a way to throw low and hard into a group." and "When throwing at a close Kubb players
do not even have the baton flip."; kubb-engine docs/notes/throw.md "The drive"). The web
(src/game/plan-sliders.js, tray.js, coach.js; its docs/SYSTEM.md "The drive") is the reference
for numbers and words.

- **ARC's range is the engine's** (`aim.controls.arc`) whenever it is drawn: its `min` is the
  throw's floor (0 at a kubb a metre away, about 12 at 4 m, the knee from about 5 m) and moves
  with the circle and the stance (`PitchSession.replan` draws again when it does); `knee` (15)
  is where the drive begins. Never a fixed 15 to 165.
- **The track** (`PlanControl.fraction`, `value(at:)`, `driveFraction`): two straight scales
  joined at the knee, the drive part 30% of the track at a floor of 0, scaled by
  (15 − floor) / 15, none once the floor is the knee; hatched in wood under the knee's heavy
  ink line, named DRIVE up the lane of marks where it is 54 pt or taller (the web's 44 px at
  10 px; the app's words are never under 14 pt), no marks under the knee (`ArcSlider`).
- **The words**: a plan under the knee reads `DRIVE −5°` on the plate and the open slider
  (`PlanScale.arcLabel`, a true minus), VoiceOver "Arc, 5 degrees down, drive"
  (`arcValueText`), the closed plate's picture falls into a kubb (the web's 70 by 32 picture,
  scaled), the held caption "A DRIVE GOES IN LOW AND HARD, WITH NO FLIP." and a baton's "A
  HIGHER ARC DROPS IN STEEPER. A LOWER ARC DRIVES IN HARDER." (a kubb keeps its own words), and
  after a drive the engine called SHORT the coach leads with "A DRIVE NEEDS MORE POWER."
  (`Coach.driveShortLine`; SLOW wins).
- **The side view** draws `aim.arc` point by point, down as well as up; a close drive does not
  turn, so `Spin.swift` draws no spin; the meter's power band at a drive (125 to 147) stays clear
  of the overpowered zone, which never starts under the band (`overStart`). A thrown kubb has no
  drive. `DriveTests` stand on the web's advantage position (`Fixtures/solo/advantage.json`, its
  tests/fixtures/snap-advantage.json) at 1.5, 4 and 8 m; the review tool's `--drive` takes the
  pictures (docs/RENDER.md "The drive").

## The 1.0 design

The Throwing Wood 1.0 system (the owner's design review, 2026-11-21; its build list is
the work order) is in `ThrowingWood/Design.swift` and the day's `SceneSkin`, whose
values are the system's tokens: ink `#16130f`, paper (cards, plain buttons), baton
(insides), field (a segmented bar's parts not chosen), wood (plate title bands), muted
(helper text, no greys), marigold the one go colour (one per screen, last in its row;
grass is never a button) and Team A, violet Team B; a 3 pt ink line, radius 6 on
controls and 8 on cards, a hard shadow of 3 on controls and 5 on cards, chips 2 pt and
no shadow. Londrina Solid Black for titles (sentence case), buttons, prompts and flags
(capitals), never a body sentence; Inter (bundled, `Fonts/OFL-Inter.txt`) for the rest,
row labels bold 14 capitals with 0.06 em tracking; nothing under 14 pt. A scene swaps
the colours and nothing else (`SceneSkinTests` 7:1; the day 4.5:1, `DesignTests`).

- **Three buttons**: go (`WoodButton(accent: true)`), plain (`WoodButton()`) and quiet
  (`QuietButton`: underlined display capitals, a full touch target) for leaving: HOME,
  RESIGN, NOT NOW. Every pressable thing is 48 pt on a phone, never under 44.
- **One segmented bar** (`Segmented`) for every two to four way choice; VoiceOver reads
  a part "Clock, selected, 1 of 2" (`SegmentWords`). Five or more is a plain button
  that opens its list (`ChoiceList`, the lobby's Kubbs).
- **Rows** (`FormRow`): the label left, its control right, 48 tall; from the largest
  three text sizes, or where they do not fit, the control drops under its label.
- **Cards** (`CardScreen`): one top edge (64 pt under the safe top upright), one dim
  (ink at 50%), the rows scrolling where the card does not fit and the button row pinned
  under them.
- **The header**: "Turn 4 · baton 2 of 6" over the thrower's name in sentence case, the
  base kubbs standing as two numbers on the team colours, MENU as a word inside the
  plate, upright and on its side (`HeaderWords`).
- **The aim (stage 3)**: ARC, TILT (SPIN) and STAND are the set-up tray, three plates
  of one size (86 x 60 upright, 104 x 70 on its side) in a column 8 pt apart
  (`TrayLayout.swift`, `TrayView`). Upright it is 10 pt in at the left edge beside the
  clock, mirrored when the meter is at the left, its foot 8 pt over the safe bottom, so
  the throwing thumb's side stays empty; on its side at the edge away from the meter. A
  tap opens one plate (`PitchSession.tapPlate`, one at a time): it grows up from its
  place, ARC into its slider with the side view (SIDE VIEW is no longer a button), TILT
  and STAND also in toward the middle, as the web's trayAt sizes them; a tap outside or
  on its band closes it. The minimap is a plate under the header's right end in every
  layout (on a wide screen with the linear meter at the left, where that end is over the
  throwing line, under the header 24 pt short of the line, so it never covers the
  target), never moving while a control is held, Team A circles and Team B squares. The
  meters' power band is striped and the release band solid, both with ink end-marks,
  and the throw's distance (the engine's plan `dist`, `MeterWords`) sits on an inverted
  tab beside WIND BACK and DRAW BACK. The verdict leads with each off word inverted
  with its arrow (`VerdictWords`); the hand-off is a short card at the foot with one
  line (`HandoffWords.line`, from the engine's rail; on a wide screen its words beside
  THROW); the computer's turn has no card,
  only the WATCH tab on its team's colour over the faded meter. The coach is one
  inverted chip naming the marks by shape. VoiceOver reads the header, the prompt and
  distance, the meter, the tray, then the minimap (`MatchReaders.swift`). `TrayTests`.
- **Play the computer**: the name row, Scene as seven picture tiles from the app's own
  renderer (three a row on a phone, four from 600 pt, the last row centred, a row each
  at the accessibility sizes; the lobby's host and the practice menu have them too), Surface only for Black & White, Computer (Kid first), Opening, Raising and Wind
  (`SoloOptions.cardRows`, the engine's card for the scene); no Kubbs row, the scene
  decides the set: `startSolo` plays it and `SoloOptions.keep` keeps it, whatever set
  was kept before. The lobby has no Kubbs row either (`OnlinePitch.hiddenRows`, the
  web's HIDDEN_ROWS); the pitch holds the set to the scene's.

## Sound and haptics

Read [docs/FEEL.md](docs/FEEL.md) for engine events, sample provenance,
pattern values and the simulator timing probe. Keep input cues on ThrowInput,
recording cues on the shown-time clock and match cues on the presented need.
Keep SOUND and HAPTICS independent. Measure warm mixer onset on the simulator
after changing the audio graph. Actual haptic feel requires a physical phone. The
Tournament's other pitches are heard, never felt: the web's cues and levels (the pitch
beside about 10 dB under the player's knock), from each recording's `hits` and `landing`
(engine 0.16.0: each body knocks once at its first hit, a topple at 0.35 + 0.65 x strength,
the king 1.5 times, a kubb left standing a tap at 0.45 of that), voices of their own, three
at most, dropped faintest first, and quiet round the player's own knock (`NeighbourSounds`).
