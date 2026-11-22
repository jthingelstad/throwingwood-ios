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
- **App icon.** The build includes the temporary king icon. The final icon is Jamie's call.

## Internal testers

`scripts/testflight.sh` archives a clean commit on main and uploads it,
internal only (`testFlightInternalTestingOnly` in
`Config/ExportOptions-TestFlight.plist`). The version is `VERSION`, set by
hand; the build number is the commit count, so a commit uploads once. A player sees
the version as `<app version> (<engine version>)`, `0.2 (0.8.1)` for the first build on
engine 0.8, `0.3 (0.9.0)` for the first on engine 0.9, `0.4 (0.9.0)` for the first
with scenes, `0.7 (0.13.1)` for the first on engine 0.13 (AGENTS.md "The version a
player sees").
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

- The pitch code, persistent random room member ID, typed name, connection
  presence and engine version travel to the rooms service. People on the pitch
  can see names, teams and connection state.
- Team choices, match options, throw, raise and placement actions, scores,
  snapshots and game history travel in the shared document and action riders.
  The server retains match records, including typed names. It keeps an eligible
  finished replay for people with the pitch link.
- Current aim and selected shouts are relayed to the other members. An open
  pitch publishes its code and aggregate listing on the website.
- Choosing Send in practice, solo or online play transmits the answers, marked
  pieces, timing, build, viewport, engine version and replayable game state.
  Online reports also include the room code and document version. Reports can contain player names from the match. The report replaces
  member identifiers in the captured state. The server stores reports privately.
- The rooms handshake sends the app origin and versioned user agent. Private
  recording and report tags identify the client and engine version. Sharing a
  pitch through the system sheet sends its URL to the destination the user picks.
- A match against the computer leaves the phone only when the player presses
  SHARE AND MAKE THE REEL on its share card. That sends the finished match (its
  options, actions and result) and the name typed on the card to the rooms
  service, which checks it, keeps it as a replay with a link of its own for a
  year and makes its reel. The card says so before anything is sent. Nothing
  else about the player or the device is in it.

## App Privacy worksheet

Answer **Yes** to data collection and **No** to tracking for this build. There are no ad or analytics SDKs. Practice and solo stay on the phone unless the player sends feedback or shares a finished solo match for its highlight reel. Sound and haptic preferences stay on the phone. Multiplayer retains identifiable gameplay on the first-party service. The developer also uses the private game records to study throws and improve play. Apple's Analytics purpose covers that use of gameplay data.

| App Store Connect type | Purpose | What travels or is kept |
| --- | --- | --- |
| Contact Info — Name | App Functionality | The “Your name” field accepts a name or nickname and shows it to the pitch. It can remain in the match. |
| Identifiers — User ID | App Functionality | The pitch display name acts as a handle. The member key links someone to their seat when reconnecting. |
| Identifiers — Device ID | App Functionality | A persistent random key in this installation's defaults identifies the member to the service across pitches. |
| User Content — Gameplay Content | App Functionality, Analytics | Teams, levels, actions, board state and scores support play, shared replays and analysis of recorded games. |
| User Content — Customer Support | App Functionality | A player can send free text: two answers about a throw, or one box of any other feedback. |
| Diagnostics — Other Diagnostic Data | App Functionality | The report includes build, engine, viewport, time, and game state needed to reproduce the throw. |

Mark all six types **linked to the user**. Records can connect the installation, pitch and typed names. Even a report with substituted member IDs can be joined back to the game by room and document version. Mark tracking **No** for each type. Ordinary aim and preset shouts are transient. The app requests no contacts, location, photos, microphone, advertising identifier or payments. Its add-only `NSPhotoLibraryAddUsageDescription` is there for the share sheet's Save Video on a highlight reel; iOS asks then, and the app never reads the library. A reel request sends only the pitch code and the version number of its kept match, and the video is downloaded from the site. Review the public privacy-policy URL and these answers against the submitted build. [Apple's privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)

The bundled `PrivacyInfo.xcprivacy` declares two required-reason categories. `CA92.1` covers the app's own UserDefaults for settings and its random member key in GameModel, GameFeedback and DeviceMemberIDStore. `35F9.1` covers elapsed time within the app. PitchAudio compares systemUptime to each sound voice's busy-until time. That clock stays on device. The report's wall-clock timestamp comes from Date. The core, Lua and musl supply game logic and math. [Apple's required reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

## Age-rating worksheet

| Question group | Proposed response and basis |
| --- | --- |
| User-generated content | Yes. Players choose display names visible to others. Match replays can include those names. |
| Messaging and chat | Yes. Four preset shouts go directly to the pitch. Free-text feedback and throw reports go privately to the developer. |
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

The six portrait PNGs under `docs/store/` come from the Release simulator app on iPhone 17 (1206 × 2622) and iPhone 17 Pro Max (1320 × 2868). Each size shows aim, flight and the score sheet from synthetic solo checkpoints with invented names. This target supports iPhone. [Apple's screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## First signed iPhone checklist

- Run the KubbEngineTests golden suite from Xcode against the connected iPhone. Match every action hash in every reference match (engine 0.8: 505 in 13). Record device model, OS and commit with the result.
- On a ProMotion phone, enable the full refresh rate and profile an optimized build in Instruments. Measure frame intervals and update/draw time through aim, release, flight, impact and rest. Record median, p95, p99 and longest frame against the 8.33 ms budget at 120 Hz. Check input-to-knock timing through the speaker and Bluetooth.
- Feel band entry and exit, release, light and heavy contact, the three surface landings, king-down, win and hand-off. Check spectator cues, slow motion, SKIP and the HAPTICS switch. Use the provisional values in [FEEL.md](FEEL.md) as the comparison.
- Test the silent switch, other music, audio interruption and route changes. Check independent SOUND and HAPTICS settings after relaunch, and that leaving a pitch stops both.
- Play one intended match with the website from join through rematch. Check both sides' throws, reconnect, scores and the kept replay. Use an authorized human play session for this check.
- Tap a shared pitch link after enabling the association. Follow [UNIVERSAL-LINKS.md](UNIVERSAL-LINKS.md) for cold and warm launches.
