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
  `0.2 (0.8.1)`, built in one place, `VersionLabel` (KubbRenderer): `VERSION`
  (the marketing version) and the newest carried engine's `engineVersion`, read
  from the engine, never typed. Nothing else goes in the parentheses: the build
  number is a detail line (`build 114`), and so would be any older engine carried
  (`Also plays 0.7.4`; none today). It is at the foot of the match, pitch and practice menus
  and in a feedback report's `build.label`. It never goes on the room wire, a
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
The six option lists come from the pinned engine (Computer among them on 0.9). Store the raw snapshot after
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
`backend/pitch-server/PROTOCOL.md` and `API.md`, and its docs/MULTIPLAYER.md section
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
`--landscape left` and `--ipad` (docs/ONLINE.md "Sharing a match against the computer").
Never send a real share.

The Kit's tests run the real client and controller against `FakePitch`, an in-process
pitch server written from PROTOCOL.md, in the existing macOS CI job. A run against the
pitch server's own `wrangler dev` stays local and on 127.0.0.1: start it from the web
repository's backend/pitch-server (`npm run dev`, port 8797), then
`PITCH_LOCAL_URL=ws://127.0.0.1:8797 swift test --package-path ThrowingWoodKit --filter
LocalPitchServerTests` (off without the variable, and it refuses any other host).


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
device's (Your name, Sound, Haptics, Meter, Meter side) are together on
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

A scene is a look only (Jamie, 2026-11-20: "dark mode for the game"): the world,
the controls' skin and the throw's effects. It never changes play, the engine, a
throw or a hash. Day is today's look and the default; Night is a real pitch at night
under a full moon (lit pieces, stardust behind a thrown piece); Neon is our own black
world on a grid of light (pieces edged in light, a ribbon and sparks; no film names).
The web (0.7.0) is the reference: keep its numbers and colours (`SceneRenderer.swift`,
`SceneEffects.swift`, `SceneSkin.swift`). Scene and Surface stay two settings.

- **The Scene row** (shown as Park, Camping and Techno for the ids `day`, `night`,
  `neon`, the owner's 2026-11-22 names, from the one table `SceneID.shownNames`;
  `SceneID.row`) is offered only where the
  match's engine takes a scene (0.9 on, `scene` in its OPTION_DEFAULTS): last in the
  solo options (kept as `solo.option.scene`), in the lobby for the host (the room's
  `settings.scene`, as the web writes it), and in the practice menu (kept as
  `pitch.practiceScene`; a change starts a new practice in it, as on the web). A 0.8
  or 0.7 match has no row and draws the day. Never a Scene row in the match menu.
- **An unknown id** draws as the day and is carried untouched (`SceneID.shown`).
- **Everything that shows a match follows its scene** (`GameModel.shownScene`):
  play, watching, a reopened match, the replay and the winner card. Home, the
  online entry and Settings from home are the day.
- **The skin.** Every control takes the scene's colours from `SceneSkin` through
  `SkinStore`; each pair of words and ground is 7:1 or better (`SceneSkinTests`).
  The day is the 1.0 system's tokens ("The 1.0 design" below, `DesignTests`); the
  pitch's own day picture (`PitchRenderer`, its five snapshots) does not move.
- **Reduce Motion** calms the effects: no trail or ribbon, fewer and shorter puffs,
  no hit flash.
- Review pictures take `--scene night|neon` on the solo and online tools
  (`<phone>-<scene>-<shot>.png`). docs/RENDER.md "Scenes".

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
  layout, never moving while a control is held, Team A circles and Team B squares. The
  meters' power band is striped and the release band solid, both with ink end-marks,
  and the throw's distance (the engine's plan `dist`, `MeterWords`) sits on an inverted
  tab beside WIND BACK and DRAW BACK. The verdict leads with each off word inverted
  with its arrow (`VerdictWords`); the hand-off is a short card at the foot with one
  line (`HandoffWords.line`, from the engine's rail); the computer's turn has no card,
  only the WATCH tab on its team's colour over the faded meter. The coach is one
  inverted chip naming the marks by shape. VoiceOver reads the header, the prompt and
  distance, the meter, the tray, then the minimap (`MatchReaders.swift`). `TrayTests`.
- **Play the computer**: the name row, Scene as three picture tiles from the app's own
  renderer, Computer, Opening, Raising, Wind and Surface (`SoloOptions.cardRows`); no
  Kubbs row, the scene decides the set (`SceneID.kubbs`): `startSolo` plays it and
  `SoloOptions.keep` keeps it, whatever set was kept before. The lobby has no Kubbs row
  either (`OnlinePitch.hiddenRows`, the web's HIDDEN_ROWS); the room's stored set is
  left as it is and a match started there plays it, as on the web. The names a player sees for
  the scenes are one table, `SceneID.shownNames`.

## Sound and haptics

Read [docs/FEEL.md](docs/FEEL.md) for engine events, sample provenance,
pattern values and the simulator timing probe. Keep input cues on ThrowInput,
recording cues on the shown-time clock and match cues on the presented need.
Keep SOUND and HAPTICS independent. Measure warm mixer onset on the simulator
after changing the audio graph. Actual haptic feel requires a physical phone.
