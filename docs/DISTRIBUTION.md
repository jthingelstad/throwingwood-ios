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
public TestFlight group and for the App Store. App Privacy follows
`ThrowingWood/PrivacyInfo.xcprivacy`: nothing collected, no tracking.
