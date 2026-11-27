# Distribution

Throwing Wood is in the App Store (1.0.0, 2026-11-24) and in TestFlight: build 20 (0.1) went to the Internal group on
2026-11-18, and the Beta group takes external builds once Apple's Beta App
Review passes them. Every upload, every tester group and the App Store are
Jamie's call. Jamie has given a standing go to upload an external build and
submit it to Beta App Review for the Beta group whenever Jamie asks for one.
Build 256, `1.0.0 (1.0.0)`, went to the Internal group on 2026-11-22, the first
build of 1.0.0 in TestFlight.
Build 284, `1.1.0 (1.4.0)`, went to the Internal group on 2026-11-26 and was
submitted to Beta App Review for the Beta group the same day, at 4:30 PM Central (the
owner asked for the TestFlight builds for dev and beta to be brought up to the current
build). It is the first build on engine 1.4, and it carries 1.0 as well for a pitch with
someone on the App Store version. Apple passed it for the Beta group.
Build 291, `1.1.0 (1.4.1)`, went to the Internal group on 2026-11-27 and was submitted to
Beta App Review for the Beta group the same day, at 1:13 PM Central (the owner asked for a
new build for dev and beta once that day's changes were in): a match playing behind the
first screen, watching the other team from your own baseline, a raise view that stands
over the lying kubbs, and RESIGN against the computer ending at once. It was uploaded from
the development Mac. Until Apple passes it, outside testers have build 284.

## The App Store submission

**1.0.0 is in the App Store** since 2026-11-24: Apple approved it and it went live that
day at <https://apps.apple.com/us/app/kubb-throwing-wood/id6836326990> (app id
6836326990). throwingwood.com shows Apple's badge on `/` and `/ios/`, and keeps the public
TestFlight link on `/ios/` for testing new versions (the web repository's
`APP_STORE_URL` and `TESTFLIGHT_URL`).

Version 1.0.0 with build 260 was submitted for App Review on 2026-11-22 at 9:12 PM
Central (the owner: "Approved: submit Kubb: Throwing Wood 1.0.0 (build 260) for App
Review"), to release as soon as it is approved. What the record holds:

- **The listing**: the 1.0 words and keywords below, the subtitle "The lawn game, in
  your hand", Games with Sports and Family, free in every territory, rated 4+.
- **Support and privacy**: `https://throwingwood.com/support/` and
  `https://throwingwood.com/privacy/` (the web repository's pages).
- **App Privacy**: published as the worksheet below.
- **Pictures**: the sixteen under `docs/store/` ("Screenshots"), eight a device.
- **Previews**: three highlight reels a device ("App previews").
- **App Compliance** (China mainland; the owner's answers): no feature that needs a
  security assessment, and no AI-generated or synthetic content service. A new app
  cannot be submitted until both are answered.
- **Review notes**: no sign-in, how to see an online match on one device, nothing a
  player types that others see, and why the app asks for add-only photo access.

`scripts/asc.swift` made the record and the submission (a review submission, its item
for the version, then `submitted`), `tools/asc-upload-media.py` the pictures and
previews; App Privacy and App Compliance are on the web only. The App Store row in the
web repository's docs/ENGINES.md was changed on 2026-11-24, the day it went live; change
it again the day any later version does.

## Once, before the first upload (done 2026-11-18)

- **The bundle id** `com.throwingwood.app` must be registered with Apple. An
  App Store Connect API key can't register a new bundle id or make its first
  profile, so the first archive needs Xcode's own sign-in.
- **The app in App Store Connect**, made on the web (the API can't make one),
  with an internal group of testers.
- **Signing.** `Config/Signing.local.xcconfig` holds the team and
  `Config/AppStoreConnect.local` the API key's ids (both ignored by git; see
  `scripts/testflight.sh`).
- **App icon.** The final icon is Jamie's call. His direction (2026-11-22): the top third of a king in profile, the crown framed, with an alternate per scene. It is built (the Park king as the primary with dark and tinted looks, the other six scenes as alternates picked in Settings, drawn by the game's renderer: docs/RENDER.md "The app icon"). It shipped in build 260, and Jamie approved it on 2026-11-22: "260 is great. icon is lovely. even alternative icons are amazing".

## The web plays with the builds people have

The web carries the engines of the current App Store release and the current TestFlight
Dev (internal) and Beta builds, and its own, and no others (the owner, 2026-11-22: "Web
will support the CURRENT App Store release and the CURRENT Test Flight Dev and Beta
releases. At most the web will support those three versions and whatever version it is
running natively."). It cannot see App Store Connect, so its record is a table in the web
repository's docs/ENGINES.md, "The iPhone builds people have". After every upload to a
tester group and every App Store release, change that group's row there (app version,
engine, date) in a pull request the same day: the web drops an engine only when no row
names it.

## Internal testers

`scripts/testflight.sh` archives a clean commit on main and uploads it,
internal only (`testFlightInternalTestingOnly` in
`Config/ExportOptions-TestFlight.plist`). The version is `VERSION`, set by
hand; the build number is the commit count, so a commit uploads once. An
internal-only build can never join the Beta group or go to the App Store, so a
commit meant for outside testers is uploaded with `--external` and nothing else
(the Internal group sees every build either way). A player sees
the version as `<app version> (<engine version>)`, `0.2 (0.8.1)` for the first build on
engine 0.8, `0.3 (0.9.0)` for the first on engine 0.9, `0.4 (0.9.0)` for the first
with scenes, `0.7 (0.13.1)` for the first on engine 0.13, `0.8 (0.13.3)` for the first
that carries the newest engine alone (docs/ENGINES.md: it plays no match with a build
before 0.7 or a web tab on 0.9), `0.9 (0.13.4)` for the first with generated names and no
typed name anywhere, `0.10 (0.15.1)` for the first with the engine's seven scenes and Kid
matches, `0.11 (0.16.0)` for the first with the drive and the engine's own raises watched,
`0.12 (0.18.0)` for the first with a match's length and computer players in the lobby,
`1.0.0 (1.0.0)` for the released game on the released engine, the build submitted to the
App Store (the owner, 2026-11-22: "lets move all four projects to version 1.0.0 and tag
those releases. We will use that version to submit to the App Store as well."),
`1.1.0 (1.4.0)` for the first on engine 1.4, with the throw to go, a person's throw
level, the view from your own end, the computer's speed and tip-up in any order,
`1.1.0 (1.4.1)` for build 291, on the patch engine with the baseline and raise cameras
(AGENTS.md "The version a player sees").
`scripts/asc.swift` calls the App Store Connect API for the rest (groups,
What to Test, review submissions).

## Outside testers and the App Store

`scripts/testflight.sh --external` makes a build Apple can review for a
public TestFlight group and for the App Store. Use the worksheet below for this build.

A commit uploads once, so an external build needs a commit on main that has not
been uploaded yet. Before the first submission, Beta App Review needs the
review contact, a beta description, a feedback email and each build's What to
Test, all set with `scripts/asc.swift`.

## Data that leaves the device

No name is typed anywhere in the app (since 0.9, 2026-11-21): every player and team
name is generated from the game's own word lists ("Mighty Maple", "Birch Batons") and
picked in a name row (AGENTS.md "Names are generated"). The pitch server drops any
other name it is sent and refuses a document or a start that names one.

- The pitch code, the persistent random member ID, the device's generated name, the
  connection presence and the engines carried travel to the pitch server
  (`throwingwood-pitches`, first party). No level is sent. People on the pitch see the
  generated names, teams and connection state.
- Team choices, generated team names, match options, throw, raise and placement
  actions, scores, snapshots and game history travel in the shared document and
  actions. The pitch server keeps the match record, generated names included, and an
  eligible finished replay for people with the pitch link.
- Current aim and HOLLER's preset phrases and emoji are relayed to the other members. An open
  pitch publishes its code and an aggregate listing (seats and state, never a name).
- Choosing Send in practice, solo or online play transmits the answers, any paint
  over the picture of the pitch, timing, build, viewport, engine version and replayable game state.
  Online reports also include the pitch code and document version. Reports can contain
  the match's generated names. The report replaces member identifiers in the captured
  state. The server stores reports privately.
- The pitch handshake sends a versioned user agent. Private report tags identify the
  client and engine version. Sharing a pitch through the system sheet sends its URL to
  the destination the user picks.
- A match against the computer leaves the phone only when the player presses SHARE AND
  MAKE THE REEL on its share card. That sends the finished match (its options, actions
  and result) under the generated name picked on the card to the API, which checks the
  names, keeps it as a replay with a link of its own for a year and makes its reel. The
  card says so before anything is sent. Nothing else about the player or the device is
  in it.

**What a player authors that others see**: nothing free-form. Others see the player's
generated name and team name (picked from the game's word lists), HOLLER's fixed
set of 24 phrases (NICE!, OOH!, TOK!, ...) and 12 emoji, which a receiver shows only when they are exactly on the list, match options from fixed lists, and the play
itself (aim, throws, raises). The only free text in the app is Send feedback's answers,
which go privately to the developer and are never shown to anyone else.

## App Privacy worksheet

Published in App Store Connect on 2026-11-22 as written here.
Answer **Yes** to data collection and **No** to tracking. There are no ad or analytics SDKs. Practice and solo stay on the phone unless the player sends feedback or shares a finished solo match for its highlight reel. Sound and haptic preferences stay on the phone. Multiplayer retains identifiable gameplay on the first-party service. The developer also uses the private game records to study throws and improve play. Apple's Analytics purpose covers that use of gameplay data.

| App Store Connect type | Purpose | What travels or is kept |
| --- | --- | --- |
| Identifiers — User ID | App Functionality | The generated display name acts as a screen name on the pitch and in its replay. The member key links someone to their seat when reconnecting. |
| Identifiers — Device ID | App Functionality | A persistent random key in this installation's defaults identifies the member to the service across pitches. |
| User Content — Gameplay Content | App Functionality, Analytics | Teams, generated names, actions, board state and scores support play, shared replays and analysis of recorded games. |
| User Content — Customer Support | App Functionality | A player can send free text privately to the developer: two answers about a throw, or one box of any other feedback. |
| Diagnostics — Other Diagnostic Data | App Functionality | The report includes build, engine, viewport, time, and game state needed to reproduce the throw. |

**Contact Info — Name** comes off: no name the person types is collected; a generated
name is made from the game's words and holds nothing about the person. Mark the five
types **linked to the user**: records connect the installation, the pitch and its
generated names. Even a report with substituted member IDs can be joined back to the game by pitch and document version. Mark tracking **No** for each type. Ordinary aim and HOLLER's preset phrases and emoji are transient. The app requests no contacts, location, photos, microphone, advertising identifier or payments. Its add-only `NSPhotoLibraryAddUsageDescription` is there for the share sheet's Save Video on a highlight reel; iOS asks then, and the app never reads the library. A reel request sends only the pitch code and the version number of its kept match, and the video is downloaded from the site. Review the public privacy-policy URL and these answers against the submitted build. [Apple's privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)

The bundled `PrivacyInfo.xcprivacy` declares two required-reason categories. `CA92.1` covers the app's own UserDefaults for settings and its random member key in GameModel, GameFeedback and DeviceMemberIDStore. `35F9.1` covers elapsed time within the app. PitchAudio compares systemUptime to each sound voice's busy-until time. That clock stays on device. The report's wall-clock timestamp comes from Date. The core, Lua and musl supply game logic and math. [Apple's required reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

## Age-rating worksheet

| Question group | Proposed response and basis |
| --- | --- |
| User-generated content | No (from 0.9). A player authors nothing free-form that others see: names and team names are generated from the game's own word lists and picked from them (the pitch server refuses any other), hollers are a fixed set of phrases and emoji (a receiver drops anything else), options come from fixed lists. Free-text feedback goes privately to the developer. Apple has not ruled on picked-from-list names that we know of (kubb-engine docs/NAMES.md section 6), so this is defensible, not certain. |
| Messaging and chat | No. Players cannot write to each other: the only thing sent between them beyond play is a HOLLER, one of a fixed set of 24 phrases and 12 emoji (NICE!, OOH!, TOK!, ...), and a receiver shows only an exact member of that set. Answer Yes instead if Apple counts preset emotes as chat. Feedback goes privately to the developer. |
| Contests | None. Apple's contests are events where users compete for rankings, rewards or personal goals, and the game has none: a match is a game between players, with no stakes, prizes or standings. (The first draft said Frequent, which would have rated the app 13+.) |
| In-app controls | No parental controls or age assurance. |
| Other capabilities | No social media feed, unrestricted web access or advertising. Sharing uses the system share sheet. |
| Mature themes, fear, profanity, substance references, sexual content and nudity | None in authored content. |
| Violence and weapons | None. The sporting equipment hits wooden pieces on the pitch. |
| Medical, treatment, health and wellness | None. |
| Gambling and loot boxes | None, including simulated gambling. |

Enter the answers for the release build and review the age rating Apple computes in each territory. The build makes no Kids Category claim. [Apple's rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)

## Export compliance

Answer **No** to use of non-exempt encryption. For the encryption-algorithm question, select none of the listed algorithms implemented by the app. The live socket uses Apple's URLSessionWebSocketTask with system TLS. The app ships no custom or third-party cryptography. Game state hashes check that two plays agree. Config/Info.plist already sets ITSAppUsesNonExemptEncryption to false. [Apple's encryption documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)

## Draft store listing

**Kubb: Throwing Wood**

Six batons. Ten kubbs. One king. Take aim from the baseline and send the wood across the pitch. Leave the king standing until the other side is clear.

Find your range in practice, play a match against the computer, or send a pitch link to a friend. An iPhone and a web browser can play opposite sides of the same match. Choose grass, sand or snow, raise your field kubbs, and read the finished game back on its score sheet.

**Keywords** — kubb,lawn,baton,king,wood,backyard,throw,toss,pitch,multiplayer,Viking,chess

### The 1.0 listing (in App Store Connect)

The draft above predates scenes and Kid matches. This one is the listing submitted with
1.0.0 on 2026-11-22.

**Kubb: Throwing Wood**

Six batons. Ten kubbs. One king. Kubb is the lawn game of knocking down your
opponent's wooden blocks before you topple the king, and Throwing Wood puts the pitch
in your hand: set your arc, from a high lob to a low, hard drive, your tilt and your
stance, then wind the meter back and flick.

Play the computer at four levels, from a gentle Kid match (three kubbs a side, thrown
from the cones) to Pro. Send a pitch link to a friend and play opposite sides of the
same match, iPhone against iPhone or iPhone against a web browser, with every throw
the same on both, and fill out either team with computer players at their own levels.

Choose where you play: a summer park, a beach by the sea, a campsite under the full
moon, Techno's grid of light, a Minnesota snowfall, a tournament field with matches
going on around you, or the black and white of the original handheld game. Raise your
field kubbs, place the punishment kubbs, and read the finished game back on its score
sheet in Planet Kubb notation.

Every name in the game is made from its own word lists, so there is nothing to type and
nothing to moderate. No ads, no tracking.

**Keywords** (94 of 100 characters) —
kubb,lawn game,baton,king,viking chess,backyard,throw,toss,scenes,kids,multiplayer,score sheet

## Screenshots

The app is universal, so the store takes an iPhone set and an iPad set. Apple's
specification (read 2026-11-22,
[Apple's screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)):
iPhone needs one set in the large Dynamic Island class (1260 x 2736, 1290 x 2796 or
1320 x 2868) or, failing that, the Face ID large class (1284 x 2778 or 1242 x 2688);
every smaller iPhone class is scaled from it, so the iPhone 17 size (1206 x 2622, the
medium class) is no longer needed. An app that runs on iPad needs one set in the
13-inch class (2064 x 2752 or 2048 x 2732, portrait or landscape); the 11-inch and
smaller are scaled from it. One to ten pictures a size, PNG or JPEG, no alpha channel.

The sixteen portrait PNGs under `docs/store/` come from the Release simulator app on the
iPhone 17 Pro Max (1320 x 2868) and the iPad Pro 13-inch (M5, 2064 x 2752), status bar
at 9:41 with a full battery (the iPad's shows the simulator's date; its status bar takes
no date), the whole framebuffer (no Dynamic Island or rounded corners drawn, as a
device's own screenshot; the simulator now and then draws the island into a capture, and
the tool takes that one again), real screens with invented names and no words added
(`tools/store-snapshots.sh`, which flattens the alpha the simulator leaves on an iPad's
PNG). An iPad keeps the phone's control sizes, so its pictures are mostly pitch; that is
the app as it is, not a framing choice.

Every one is play on a pitch (the owner, 2026-11-22: "i want to make sure we highlight
some of the different scenes in the screenshots. no scoresheet -- show gameplay."): all
seven scenes, no menu, no scene tiles, no winner card and no score sheet. The first three
are the ones a search result shows, so they are the throw itself and the two scenes that
look least like it. The set as retaken on 2026-11-22 from build 260 (commit `991223e`).
In order:

1. `1-aim`: Park. The clock wound back to its band, FLICK!, the circle on a group of four field kubbs 4 m off.
2. `2-techno`: Techno. A baton down on the grid, its impact rings spreading past the lit kubbs.
3. `3-camping`: Camping. A baton in the air under the full moon, stardust behind it, the king glowing.
4. `4-kid`: Beach. A Kid match, STAND open on the Kid line ("Stand anywhere from behind your line up to the Kid line"), three kubbs a side, the sea behind.
5. `5-tournament`: Tournament. The player's baton in flight under the bunting, the pitch ahead in play, scoreboards and a tent.
6. `6-raise`: Minnesota. Raising field kubbs in the snow: one of two tipped up by a finger, its end lit.
7. `7-drive`: Black & White. A low drive in slow motion, the baton at a row of field kubbs, one bit.
8. `8-hit`: Park. The hit: a field kubb down beside the baton, the verdict and its chips.

Six of the shots are the review tool's own (`ring`, `flight`, `kidstand`,
`neighboursflight`, `drive-flight-5`, `drive-verdict`); `wound` and `raisemanydrag` are two
more in `tools/solo-snapshots.py` for this set (`STORE_SHOTS`), from review modes the app
already has (`drivemeterwound`, `raisedrag`). `--player` names side A in every fixture.

Each is `iphone-17-pro-max-<n>-<name>.png` and `ipad-pro-13-<n>-<name>.png`.

## App previews

Apple's specification (read 2026-11-22,
[App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/)):
15 to 30 seconds, at most 30 frames a second and 500 MB, up to three previews a device
size and language, shown before the screenshots. H.264 (`.mov`, `.m4v`, `.mp4`),
progressive, up to High Profile level 4.0, a target of 10 to 12 Mbps (or ProRes 422 HQ
in a `.mov`); stereo AAC at 256 kbps, 44.1 or 48 kHz, one two-channel track or two
one-channel tracks, every track enabled. Portrait 886 x 1920 is accepted for every
iPhone class with Face ID or a Dynamic Island, and 1200 x 1600 for the 13-inch iPad; a
class without its own is scaled from a related one. The default poster frame is the one
at 5 seconds.

**What is in the store** is three of the game's own highlight reels a device (the
owner, 2026-11-22: "highlight reels of three different scenes are the ideal things"):
Park, Techno and Camping, each a match of a generated name against the computer that
ends on the king, 25 to 29 s, with the reel's captions and sound, a one second title and
no end card. They are drawn by the web repository's reel renderer at the store's sizes
(886 x 1920 and 1200 x 1600; the change that adds those sizes is the web repository's
pull request 135, open as this is written), kept in
`build/store-previews/reels/` (not committed) with the commands that made them, and
went up with `tools/asc-upload-media.py preview IPHONE_67` and `preview
IPAD_PRO_3GEN_129`. A reel is the engine's picture of a match, not a recording of the
phone's screen; App Review's guideline 2.3.4 asks for screen captures of the app, so if a
reviewer refuses them the captured preview below takes their place.

One preview is made here, for the iPhone, as real play (the owner, 2026-11-22: "focus on
game play.. and show 3 or 4 diff scenes"); the owner's first choice for the store's
previews is the game's own highlight reels, so this one is the fallback. No iPad preview
is made. `python3 tools/store-previews.py <simulator app>` films and cuts it into
`build/store-previews/` (not committed): `iphone-17-pro-max-preview-1.mp4`, 886 x 1920,
about 20.5 s, with `iphone-17-pro-max-preview-1-poster.png`, its frame at 5 s. Three
scenes, plain cuts, no titles, captions or added graphics:

| From | Scene | What happens |
| --- | --- | --- |
| 0.0 s | Park | The opening throw: the aim dragged to the next base kubb, the clock wound and flicked, the baton in slow motion, TOK!, the kubb down, the verdict. The frame at 5.0 s is the TOK! |
| 6.9 s | Techno | Two batons into a knot of six field kubbs 5 m off: rings on the grid, 1 down, then KLAK! KLAK!, 2 down |
| 16.3 s | Camping | At the king under the moon: wound, flicked, KING!, the king down |

How it is made:

- **The app is the build as it is.** It is launched as a player launches it, with no
  review mode. Each scene starts from a kept match the app resumes (`solo-match.json` in
  its Application Support, the file `MatchSave` writes), and what a throw does is what
  the engine does with the touches it is given.
- **The positions** (`tools/store-previews/park.json`, `techno.json`, `camping.json`)
  are matches started as `startSolo` starts them, each in its scene, and played on from
  a fixed seed by the engine's own computer player on both sides until the throw wanted:
  `node tools/preview-positions.mjs` (this repository's engine on the web client's host,
  the web checkout read only). Never a saved or recorded game.
- **The touches** are a UI-testing bundle's (`tools/review-turn`, `Play`): a tap on
  THROW, a drag of the aim, a swing round the clock to the middle of the power band and
  of the release band, as a finger makes them. XCTest's public gestures are one straight
  stroke, so the swing's path is built with the event classes those gestures use.
- **The recording** is `xcrun simctl io recordVideo`, cut by the times the touches were
  made and encoded with ffmpeg to the specification (High Profile level 4.0, 30 frames a
  second, held at 11 Mbps). **There is no sound**: the simulator's recording has none,
  and none is added; the file carries a silent stereo AAC track (48 kHz) so it has the
  track the specification names. Sound from a phone would need a capture of its own.
- **The phone is the iPhone 16e's simulator**, not the 17 Pro Max the pictures use: a
  recording of a Dynamic Island simulator has the island drawn into every frame as a
  black pill, which a phone's own screen recording never has. The 16e's screen is the
  same shape (1170 x 2532, scaled to 888 x 1920 and a pixel trimmed from each side); the
  file keeps the store slot's name.

## First signed iPhone checklist

- Run the KubbEngineTests golden suite from Xcode against the connected iPhone. Match every action hash in every reference match (engine 1.0: 880 in 21). Record device model, OS and commit with the result.
- On a ProMotion phone, enable the full refresh rate and profile an optimized build in Instruments. Measure frame intervals and update/draw time through aim, release, flight, impact and rest. Record median, p95, p99 and longest frame against the 8.33 ms budget at 120 Hz. Check input-to-knock timing through the speaker and Bluetooth.
- Feel band entry and exit, release, light and heavy contact, the three surface landings, king-down, win and hand-off. Check spectator cues, slow motion, SKIP and the HAPTICS switch. Use the provisional values in [FEEL.md](FEEL.md) as the comparison.
- Test the silent switch, other music, audio interruption and route changes. Check independent SOUND and HAPTICS settings after relaunch, and that leaving a pitch stops both.
- Play one intended match with the website from join through rematch. Check both sides' throws, reconnect, scores and the kept replay. Use an authorized human play session for this check.
- Tap a shared pitch link after enabling the association. Follow [UNIVERSAL-LINKS.md](UNIVERSAL-LINKS.md) for cold and warm launches.
