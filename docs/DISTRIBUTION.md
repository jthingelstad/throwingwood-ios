# Distribution

Throwing Wood is not distributed yet. Every upload, every tester group and the
App Store are Jamie's call. When that day comes:

## Once, before the first upload

- **The bundle id** `com.throwingwood.app` must be registered with Apple. An
  App Store Connect API key can't register a new bundle id or make its first
  profile, so the first archive needs Xcode's own sign-in.
- **The app in App Store Connect**, made on the web (the API can't make one),
  with an internal group of testers.
- **Signing.** `Config/Signing.local.xcconfig` holds the team and
  `Config/AppStoreConnect.local` the API key's ids (both ignored by git; see
  `scripts/testflight.sh`).
- **An app icon.** There is none yet, and App Store Connect refuses an upload
  without one.

## Internal testers

`scripts/testflight.sh` archives a clean commit on main and uploads it,
internal only (`testFlightInternalTestingOnly` in
`Config/ExportOptions-TestFlight.plist`). The version is `VERSION`, set by
hand; the build number is the commit count, so a commit uploads once.
`scripts/asc.swift` calls the App Store Connect API for the rest (groups,
What to Test, review submissions).

## Outside testers and the App Store

`scripts/testflight.sh --external` makes a build Apple can review for a
public TestFlight group and for the App Store. Reconcile the privacy answers
and manifest with the online data below before distribution.

## Data that leaves the device during online play

- The pitch code, persistent random room member ID, typed name, selected level,
  connection presence and engine version travel to the rooms service. People on
  the pitch can see names, levels, teams and connection state.
- Team choices, match options, throw, raise and placement actions, scores,
  snapshots and game history travel in the shared document and action riders.
  The server retains match records, including typed names. It keeps an eligible
  finished replay for people with the pitch link.
- Current aim and selected shouts are relayed to the other members. An open
  pitch publishes its code and aggregate listing on the website.
- Choosing Send on a report transmits the two typed answers, room code and
  document version, timing, build, viewport, engine version and replayable game
  state. Reports can contain player names from the match. The report replaces
  member identifiers in the captured state. The server stores reports privately.
- The rooms handshake sends the app origin and versioned user agent. Private
  recording and report tags identify the client and engine version. Sharing a
  pitch through the system sheet sends its URL to the destination the user picks.
