# Distribution

Throwing Wood is in TestFlight: build 20 (0.1) went to the Internal group on
2026-11-18, and the Beta group takes external builds once Apple's Beta App
Review passes them. Every upload, every tester group and the App Store are
Jamie's call. Jamie has given a standing go to upload an external build and
submit it to Beta App Review for the Beta group whenever Jamie asks for one.

## Once, before the first upload (done 2026-11-18)

- **The bundle id** `com.throwingwood.app` must be registered with Apple. An
  App Store Connect API key can't register a new bundle id or make its first
  profile, so the first archive needs Xcode's own sign-in.
- **The app in App Store Connect**, made on the web (the API can't make one),
  with an internal group of testers.
- **Signing.** `Config/Signing.local.xcconfig` holds the team and
  `Config/AppStoreConnect.local` the API key's ids (both ignored by git; see
  `scripts/testflight.sh`).
- **App icon.** The final icon is Jamie's call. His direction (2026-11-22): the top third of a king in profile, the crown framed, with an alternate per scene. It is built (the Park king as the primary with dark and tinted looks, the other six scenes as alternates picked in Settings, drawn by the game's renderer: docs/RENDER.md "The app icon") and awaits his look before it goes in an upload.

## Internal testers

`scripts/testflight.sh` archives a clean commit on main and uploads it,
internal only (`testFlightInternalTestingOnly` in
`Config/ExportOptions-TestFlight.plist`). The version is `VERSION`, set by
hand; the build number is the commit count, so a commit uploads once. A player sees
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
those releases. We will use that version to submit to the App Store as well.")
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
- Current aim and the four preset shouts are relayed to the other members. An open
  pitch publishes its code and an aggregate listing (seats and state, never a name).
- Choosing Send in practice, solo or online play transmits the answers, marked
  pieces, timing, build, viewport, engine version and replayable game state.
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
generated name and team name (picked from the game's word lists), the four preset
shouts (NICE!, OOH!, TOK!, UNLUCKY), match options from fixed lists, and the play
itself (aim, throws, raises). The only free text in the app is Send feedback's answers,
which go privately to the developer and are never shown to anyone else.

## App Privacy worksheet

Proposed for the next submission (nothing is changed in App Store Connect from here).
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
generated names. Even a report with substituted member IDs can be joined back to the game by pitch and document version. Mark tracking **No** for each type. Ordinary aim and preset shouts are transient. The app requests no contacts, location, photos, microphone, advertising identifier or payments. Its add-only `NSPhotoLibraryAddUsageDescription` is there for the share sheet's Save Video on a highlight reel; iOS asks then, and the app never reads the library. A reel request sends only the pitch code and the version number of its kept match, and the video is downloaded from the site. Review the public privacy-policy URL and these answers against the submitted build. [Apple's privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)

The bundled `PrivacyInfo.xcprivacy` declares two required-reason categories. `CA92.1` covers the app's own UserDefaults for settings and its random member key in GameModel, GameFeedback and DeviceMemberIDStore. `35F9.1` covers elapsed time within the app. PitchAudio compares systemUptime to each sound voice's busy-until time. That clock stays on device. The report's wall-clock timestamp comes from Date. The core, Lua and musl supply game logic and math. [Apple's required reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

## Age-rating worksheet

| Question group | Proposed response and basis |
| --- | --- |
| User-generated content | Proposed: No (from 0.9). A player authors nothing free-form that others see: names and team names are generated from the game's own word lists and picked from them (the pitch server refuses any other), shouts are four presets, options come from fixed lists. Free-text feedback goes privately to the developer. Apple has not ruled on picked-from-list names that we know of (kubb-engine docs/NAMES.md section 6), so this is defensible, not certain. |
| Messaging and chat | Proposed: No. Players cannot write to each other: the only thing sent between them beyond play is one of four preset shouts (NICE!, OOH!, TOK!, UNLUCKY). Answer Yes instead if Apple counts preset emotes as chat. Feedback goes privately to the developer. |
| Contests | Frequent. Playing a scored game against another player is central to the app. There are no stakes or prizes. |
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

### Proposed listing for 1.0 (for the owner to settle)

The draft above predates scenes and Kid matches. This one is true of the app today; the
words are the owner's to keep, change or drop.

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

The sixteen portrait PNGs under `docs/store/` (and an alternate for picture 8 on each) come from the Release simulator app on the
iPhone 17 Pro Max (1320 x 2868) and the iPad Pro 13-inch (M5, 2064 x 2752), status bar
at 9:41 with a full battery (the iPad's shows the simulator's date; its status bar takes
no date), the whole framebuffer (no Dynamic Island or rounded corners drawn, as a
device's own screenshot), real screens with invented names and no words added
(`tools/store-snapshots.sh`, which flattens the alpha the simulator leaves on an iPad's
PNG). An iPad keeps the phone's control sizes, so its pictures are mostly pitch; that is
the app as it is, not a framing choice. In order:

1. `1-aim`: aiming in Park, the set-up tray, the clock and the target.
2. `2-hit`: the moment after a hit, the verdict with its chips.
3. `3-scenes`: Play the computer, the seven scene tiles.
4. `4-techno`: a throw on Techno's grid with an impact ring.
5. `5-camping`: Camping at night, the aim under the full moon in the scene's dark skin.
6. `6-tournament`: the Tournament with a neighbouring pitch in play.
7. `7-kid`: a Kid match, STAND open on the Kid line ("Stand anywhere from behind your line up to the Kid line"), three kubbs a side.
8. `8-winner`: the winner card at the end of a match, its length on it; `8-sheet-alternate` is the score sheet of the same match, for the owner to choose between. Both are the review fixture's finished match stamped 24 minutes long (`--finish 24`): the fixtures predate a match's length, and a card with no time looks unfinished.

Each is `iphone-17-pro-max-<n>-<name>.png` and `ipad-pro-13-<n>-<name>.png`.

## First signed iPhone checklist

- Run the KubbEngineTests golden suite from Xcode against the connected iPhone. Match every action hash in every reference match (engine 0.18: 854 in 21). Record device model, OS and commit with the result.
- On a ProMotion phone, enable the full refresh rate and profile an optimized build in Instruments. Measure frame intervals and update/draw time through aim, release, flight, impact and rest. Record median, p95, p99 and longest frame against the 8.33 ms budget at 120 Hz. Check input-to-knock timing through the speaker and Bluetooth.
- Feel band entry and exit, release, light and heavy contact, the three surface landings, king-down, win and hand-off. Check spectator cues, slow motion, SKIP and the HAPTICS switch. Use the provisional values in [FEEL.md](FEEL.md) as the comparison.
- Test the silent switch, other music, audio interruption and route changes. Check independent SOUND and HAPTICS settings after relaunch, and that leaving a pitch stops both.
- Play one intended match with the website from join through rematch. Check both sides' throws, reconnect, scores and the kept replay. Use an authorized human play session for this check.
- Tap a shared pitch link after enabling the association. Follow [UNIVERSAL-LINKS.md](UNIVERSAL-LINKS.md) for cold and warm launches.
