# A pitch is a link

Home → Play online → Start a pitch makes a random code. The lobby displays the
canonical HTTPS link, Copy and the system share sheet. Join a pitch accepts
the same link or its code. Both paths pass a PitchLink to the same entry point.
A shared link currently opens the website in a browser.

## From lobby to match

The socket opens when the player starts or joins a pitch. The host initializes
the lobby document. Presence sends the locally remembered name after room.cleanName,
the level and room.constants.ENGINE (major.minor). The lobby shows names, sides,
watchers, host and connection state. A member can join either team or sit out.
Team capacity and level and match options come from the engine. The host sets
options, invite-only or open access, and starts. An empty side plays as the
computer. An open pitch sends the web's counts-only listing on change and
renews it every five minutes while the host is present.

A seated guest checks the host's engine. START rechecks everyone in the lineup
inside the document reducer. A refused start names the members who need a
compatible version. A running match checks every member, including a watcher
who might inherit host control. An incompatible member can dismiss the version
card and watch a readable snapshot. Both iPhone and web require an advertised
compatible engine to play.

## One match, two clocks

PitchController owns the authoritative native session, room version and
compare-and-set writes. OnlinePitch gives the solo screen's PitchSession a
separate presentation session. That separation lets the network advance while
the board is still showing the preceding throw. The display clock only advances
the dial or computer while the room grants that seat control. A player can
choose a legal end for a raise or place a punishment kubb using the same board
controls as solo, including AUTO ALL and the device's Raising setting (in the
online menu too); automatic raising acts only while this seat holds control. The host runs the computer. Spectators see the thrower's
camera. A WATCH handoff closes after 2.5 seconds, or on the next action.

The dial releases an engine action. The room controller applies it, then sends
the tagged rider with the committed snapshot and hash. A remote action is
verified in the controller and queued for presentation. The board applies it,
checks the hash, and plays its recording using showAt. A gap or disagreement
restores the room snapshot. After a win the host can put everyone back in
the lobby with the same teams.

## The highlight reel

When the finished match has a kept replay (`PitchController.finishedReplay`:
the engine's `room.replayOf` is not null, the same test as the web's WATCH
REPLAY), the winner card adds a button, MAKE A HIGHLIGHT REEL. It opens the reel
card (`ReelCard.swift`), which holds a pitch code and, optionally, the match it
is for (`HighlightReel` in KubbRenderer), so a solo match can use it once a solo
match has a code; solo has no button yet. The web's docs/REEL.md "The iPhone" is
the contract, and the card's words (`ReelWords`) are the web's, word for word.
The card's title is "Highlight reel" in every state.

- First the card checks that the room still keeps this match, with the
  read-only `replay` fetch (docs/ROOMS-CLIENT.md), which starts nothing: the
  same `n`, and the same hash when both have one. A just-ended match's keep may
  still be on its way, so it looks 4 times, 2.5 seconds apart, before it says
  "This match has no replay, so it cannot have a reel." When the room keeps a
  newer match (a rematch since), it says "This pitch has moved on to a newer
  match." Opened with a code alone there is nothing to compare, and any kept
  replay is taken.
- Then it asks the rooms server with a `reel` request on a short-lived socket of
  its own. Every `reel` request (the first, each poll, a reopened card, TRY
  AGAIN) carries the pitch code and `v`, the kept version the check found, so
  the server never starts a render of another match: when the room keeps a
  different version it answers `why: "moved"`, starts nothing and counts
  nothing, and the card says the moved line. `v` is left out (never null) only
  when the card has had no kept read. A server from before `v` ignores it, so
  the card also says moved when an answer names another kept version.
- While the server renders, the card says MAKING YOUR REEL with a slow bar and
  "About a minute. You can keep watching.", and asks again every 5 seconds while
  the card is on screen. BACK or the app going to the background stops the
  asking; showing the card again asks once and goes on. There is no push
  notification. A poll that goes unanswered, or a device with no network path,
  puts "No connection." under the wait text and the asking goes on: the render
  goes on without us. The winner card's button reads MAKING YOUR REEL meanwhile
  and WATCH THE REEL once it is done.
- Done, the card says "Your reel is ready. Getting the video." while the tall MP4
  is downloaded to Caches (`reels/<code>/<v>-<tag>/`), and the wide one too when
  the window is wider than tall. iOS may empty Caches; the card downloads again
  when it is shown. The video plays muted and looping, wide in a window wider
  than tall and tall otherwise.
- SHARE gives the system share sheet the tall file, named
  `throwing-wood-<code>-tall.mp4`. Save Video there adds it to Photos, which is
  why Info.plist carries an add-only `NSPhotoLibraryAddUsageDescription`; the app
  never reads the library. COPY LINK copies `https://throwingwood.com/p/<code>`
  and "Copied the link." shows under it. A success haptic marks the reel
  arriving, when HAPTICS is on.
- Every other answer is said plainly, in the web's words: no highlights, another
  version of the game, busy today, too many at once, no replay, moved on, and
  "Reels cannot be made right now." for unavailable and any why this build does
  not know. TRY AGAIN is offered only where asking again can mend it:
  - No connection before anything renders: "No connection.", TRY AGAIN as often
    as it is pressed.
  - The server could not start the render (the error `failed`): "The reel could
    not be made." with TRY AGAIN once; a second failure is the final text.
  - A reel whose state is `failed` on the server is final for that version:
    "The reel could not be made. Not this time." with no TRY AGAIN (a `failed`
    with why `empty` is "There are no highlights to show in this match.").

Review pictures: `python3 tools/reel-snapshots.py <simulator-app> --videos <dir>`
shows the card over a finished match with a stand-in server (simulator only;
`--sim-prefix` picks simulators named with that prefix, so a session can use its
own;
`<dir>` holds a tall and a wide MP4 from the web's renderer, run in a copy of the
web checkout). Every state on both phones upright; making, done, failed and
offline also turned (`--landscape right` for the 16e, `left` for the Pro Max) and
on both iPads upright and turned (`--ipad`, `--ipad --landscape left`). An iPad
lays the card out from its window's shape, so upside down and turned right give
the same pictures as upright and turned left.

| State | Small iPhone | Large iPhone |
| --- | --- | --- |
| Making | [16e](review/reel/iphone-16e-making.png) | [17 Pro Max](review/reel/iphone-17-pro-max-making.png) |
| No connection while it renders | [16e](review/reel/iphone-16e-makingoffline.png) | [17 Pro Max](review/reel/iphone-17-pro-max-makingoffline.png) |
| Done | [16e](review/reel/iphone-16e-done.png) | [17 Pro Max](review/reel/iphone-17-pro-max-done.png) |
| Done, on its side | [16e](review/reel/iphone-16e-landscape-done.png) | [17 Pro Max](review/reel/iphone-17-pro-max-landscape-done.png) |
| Could not be made | [16e](review/reel/iphone-16e-failed.png) | [17 Pro Max](review/reel/iphone-17-pro-max-failed.png) |
| Not this time | [16e](review/reel/iphone-16e-notthistime.png) | [17 Pro Max](review/reel/iphone-17-pro-max-notthistime.png) |
| No connection | [16e](review/reel/iphone-16e-offline.png) | [17 Pro Max](review/reel/iphone-17-pro-max-offline.png) |
| No highlights | [16e](review/reel/iphone-16e-empty.png) | [17 Pro Max](review/reel/iphone-17-pro-max-empty.png) |
| Another version | [16e](review/reel/iphone-16e-engine.png) | [17 Pro Max](review/reel/iphone-17-pro-max-engine.png) |
| Busy today | [16e](review/reel/iphone-16e-busy.png) | [17 Pro Max](review/reel/iphone-17-pro-max-busy.png) |
| Not available | [16e](review/reel/iphone-16e-unavailable.png) | [17 Pro Max](review/reel/iphone-17-pro-max-unavailable.png) |
| Too many | [16e](review/reel/iphone-16e-toomany.png) | [17 Pro Max](review/reel/iphone-17-pro-max-toomany.png) |
| No replay | [16e](review/reel/iphone-16e-noreplay.png) | [17 Pro Max](review/reel/iphone-17-pro-max-noreplay.png) |
| Moved on | [16e](review/reel/iphone-16e-moved.png) | [17 Pro Max](review/reel/iphone-17-pro-max-moved.png) |
| iPad | [mini](review/reel/ipad-mini-done.png) | [Pro 13-inch, on its side](review/reel/ipad-pro-13-landscape-done.png) |

The winner card with the button is the online `winner` review mode
([16e](review/online/iphone-16e-winner.png)).

## What travels

- Joining sends the code, the persistent random member ID, name, level and
  engine compatibility version. Name and level edits update presence. Host and
  connection changes come from the rooms service.
- Changed aim state goes as an ephemeral aim cast at most five times a second.
  The four shout choices are casts, limited to one per 700 ms. Up to four
  shouts stay visible for 2.6 seconds. Neither cast identifies the application.
- A set carries the lobby or match document. The action rider carries c and e
  for the recorder. The native values are ios and the full engine version.
  The server records committed versions with their riders. A finished match
  sends keep with room.replayOf and the exact ending document version.
  Sending a separate game message here would double-record a shared match.
  The server reserves game for one-client solo and watch records.
- SEND FEEDBACK freezes the displayed action trail when the card opens. A throw
  report (`kind: "throw"`) sends the two answers; Something else
  (`kind: "feedback"`) sends one trimmed text of up to 2000 characters. Both include pitch code and document position, viewport, build,
  need, level, last action and throw result, pieces, options and replay snapshots.
  Member IDs are pseudonymised in the captured state, including snapshot strings.
  Answers are limited to 1,000 Unicode scalars each. History, pieces and the
  after snapshot are dropped in that order to fit 64 KiB. The report uses a
  short-lived unjoined socket, waits for reported, and closes. It carries the
  same client and engine tags as a game record. The review modes `report` and
  `feedback` show the card in each kind.

## Leaving and reconnecting

A dropped socket retries with the same device member ID. Background closes the
socket, retaining the pitch in memory. Foreground rejoins, restores the server
snapshot and recalculates control. Home leaves the room. The earliest connected
successor claims a disconnected host after the server's 15-second grace (the
web and iPhone wait 16 seconds). A permanent leave permits an immediate claim.
Connecting, reconnecting, unreachable, replaced, full and missing pitches all
offer Home. A well-formed unused code creates an empty room on the server's
join. A joiner finding itself the first host there shows Pitch not found.
The protocol has no separate existence lookup.

## Scope and verification

A simulator build constructs its socket URL from 127.0.0.1 and a numeric port.
The device endpoint lives in RoomsConfiguration. Local tests import rooms-dev
as a library with in-memory storage. The review harness seats invented players
through the web Room client and loads its engine from the existing checkout.
Review images and baselines are in docs/review/online. Run the online snapshot
script with the simulator app path and --web pointing at the web checkout.
The two phone sizes use the same scenarios and the existing tile comparator.
With --landscape left or right the same scenarios run on a phone on its side,
named `<phone>-landscape-<mode>.png` (the 16e turned right, the Pro Max left).
The match takes the web's wide arrangement, SHOUT beside MENU, and the lobby
and menu cards scroll from their titles (docs/RENDER.md "A phone on its side").
The plan block at the far edge and the raise and punishment bar are the solo
screen's own views, shown online only to the player who acts; the online review
scenarios watch, so their pictures show neither, and the solo pictures stand
for both.
With --ipad the same scenarios run on the iPad mini and the iPad Pro 13-inch
(`ipad-mini-<mode>.png`, `ipad-pro-13-<mode>.png`, and `-landscape-` turned left):
the same screens on a bigger screen (docs/RENDER.md "An iPad"), the cards at the
web's widths and centred, e.g. [the lobby](review/online/ipad-mini-host.png),
[on its side](review/online/ipad-pro-13-landscape-host.png),
[Send feedback](review/online/ipad-mini-feedback.png) and
[a match, watching](review/online/ipad-pro-13-landscape-flight.png).

| On its side | Small iPhone | Large iPhone |
| --- | --- | --- |
| Play online | [16e](review/online/iphone-16e-landscape-entry.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-entry.png) |
| Join a pitch | [16e](review/online/iphone-16e-landscape-join.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-join.png) |
| Lobby, sharing | [16e](review/online/iphone-16e-landscape-share.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-share.png) |
| Lobby, host | [16e](review/online/iphone-16e-landscape-host.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-host.png) |
| Lobby, guest | [16e](review/online/iphone-16e-landscape-guest.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-guest.png) |
| A match, watching | [16e](review/online/iphone-16e-landscape-flight.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-flight.png) |
| SHOUT | [16e](review/online/iphone-16e-landscape-shout.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-shout.png) |
| Handoff | [16e](review/online/iphone-16e-landscape-handoff.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-handoff.png) |
| Winner | [16e](review/online/iphone-16e-landscape-winner.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-winner.png) |
| Pitch menu | [16e](review/online/iphone-16e-landscape-menu.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-menu.png) |
| Send feedback, a throw | [16e](review/online/iphone-16e-landscape-report.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-report.png) |
| Send feedback, something else | [16e](review/online/iphone-16e-landscape-feedback.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-feedback.png) |
| Pitch not found | [16e](review/online/iphone-16e-landscape-notFound.png) | [17 Pro Max](review/online/iphone-17-pro-max-landscape-notFound.png) |

The phone uses the pointer dial, native sharing, pickers and a HUD for the phone upright or on its side.
Open-pitch discovery, archived replay playback, embeds, browser shortcuts,
and the browser's full menu are outside this screen. The phone does
not resume a room after process termination. A player can rejoin by link or
code with the same member ID. An incoming pitch link uses the same join flow
as a pasted link. See [Universal Links](UNIVERSAL-LINKS.md) for activation.
