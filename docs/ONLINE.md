# A pitch is a link

Home → Play online → Start a pitch makes a random code. The lobby displays the
canonical HTTPS link, Copy and the system share sheet. Join a pitch accepts
the same link or its code. Both paths pass a PitchLink to the same entry point.
A shared link currently opens the website in a browser.

## From lobby to match

The socket opens when the player starts or joins a pitch. The host initializes
the lobby document. Presence sends the locally remembered name after room.cleanName,
the level and the engines this build carries (`room.announce`, below). The lobby shows names, sides,
watchers, host and connection state. A member can join either team or sit out.
The player's own level is the device's (Settings, `ThrowLevel`): the lobby shows it as a line with a way to Settings and never asks. Team capacity, the levels and match options come from the engine. The host sets
options, invite-only or open access, and starts. An empty side plays as the
computer. The options offered are the `MATCH_OPTIONS` of the engine the next match
would run on (`PitchController.lobbyEngine`, the room's engine counting this member),
and every option is read through that engine's `optionsOf` (since 0.9: the five in
`options` and the engine's own `computer` and `scene` from the document's `settings`,
kubb-engine docs/ROOM.md difference 9), or `lobbyOf`'s `options` on an older engine,
which has no such call. So on 0.9 the host sets Computer (the computer's level,
Beginner, Club or Pro) for the match; once a tester on 0.8 takes a seat, the row goes,
since a 0.8 match would not take it, and a 0.8 client's own writes keep the host's
setting. Scene (Day, Night, Neon, `SceneID.row`, last) is the host's too, written to
the document's `settings.scene` through the same `option` call the web makes; every
seat sees the lobby and the match in it, and the match's start carries it. It is
offered only while the next match's engine takes a scene, like Computer: on 0.8 or
0.7 the row goes and the match is drawn as the day, and a scene a client set stays in
`settings` untouched. An id this build does not draw is the day.

As on the web (`prefs.pitchOptions`), every lobby option the host picks is kept on the
device (`pitch.hostOptions`, one value per key; 0.4's lone `pitch.hostScene` is read
into it), and a new pitch this member hosts opens with them
(`PitchController.prepareLobby(options:)`). Only what that pitch's engine takes goes in
(`takenOptions`): a `MATCH_OPTIONS` key with one of its values (Computer from 0.9) and a
Scene row value where the engine takes a scene. Who can join is not kept, as on the
web. A pitch someone else hosts, or one that already has a document, is never touched.
An open pitch sends the web's counts-only listing on change and
renews it every five minutes while the host is present.

### Engines in one room

A match belongs to the engine major.minor it started on, for its whole life
(kubb-engine docs/ROOM.md "Engines in one match"). The app speaks the engine's
contract for clients that carry several engines ("The room's engine", "Speaking
down"), so a client that carries one (an earlier TestFlight build, a web tab)
agrees with it unchanged (which engines the app carries, and how each is loaded:
docs/ENGINES.md):

- Presence is `room.announce`: `engines`, every major.minor this build carries,
  and the legacy `engine` written as the room's engine with the `+engines` mark
  (`"0.8+engines"`), which an older client reads as `0.8`. The room's engine is
  `room.engineFor` counting this member; before the room is known it is the
  newest. It is announced again whenever the answer changes: a member joins or
  leaves, takes or gives up a seat, or the host changes.
- The lobby asks `engineFor` (the host and the lineup; watchers do not count)
  and shows nothing about versions while there is an engine everyone carries.
  When there is none it says who is on an older version (they update the app or
  reload the page), or that the pitch is on a newer one (update this app, or
  watch); START is disabled, and a version is never named.
- START works the room's engine out again inside the document reducer, from the
  document and presence of that write, not the lobby's, and refuses, writing
  nothing, when there is none (the refusal names the players to tell). Otherwise
  it runs on that engine's own `room.*` calls: `startCheck` and `startMatch` with
  `room.speakAs` members, so the match is stamped `match.engine` with that engine.
- Entering a match (a document, a rejoin, a gap) runs it on the engine of its
  `match.engine`, checked by that engine's `mayPlay`. A match on an engine this
  build does not carry is refused: the version card says plainly to update the
  app (newer) or that the host is on an older version, and the member can watch.
- A seated guest whose host carries no engine this build does sees the same card.

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
  asking: a request already sent is read when it comes back, but nothing it
  leads to (the reel ask after the kept check, a look again, a poll, the
  download) is sent until the card shows again, which sends that request and
  goes on. A deferred ask still names the kept version, so a rematch kept
  meanwhile is answered "moved". There is no push notification.
- The card stays up while the pitch behind it reconnects (coming back from the
  background is one), and while the room sets up a rematch; BACK then goes to
  the pitch as it is now (the lobby). It closes, to the pitch's own screen,
  when a match starts on the pitch (this player may be the next to throw) or
  the pitch is gone (unreachable, not found, full, replaced). A poll that goes unanswered, or a device with no network path,
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

## Sharing a match against the computer

The web's docs/REEL.md "The share card" is the contract: its words are `ShareWords`
(`KubbRooms/Share.swift`), and `ShareTests` checks each one against the web's own
`SHARE_WORDS` in `Fixtures/share-vectors.json` (made by `node tools/share-vectors.mjs
--web <web checkout>`, which only reads that checkout).

- **Where.** The winner card of a finished solo match against the computer (not
  practice, not online) shows MAKE A HIGHLIGHT REEL when the whole match is kept on the
  device and ends on the match shown (`PitchSession.shareableMatch(save:)`: the
  finished file's last hash is the engine's, side B alone is the computer). A finished
  save restored by a build from before the trail has none, and the button is not shown.
- **The card** (`ShareCard.swift`, `SoloShare`): the about line, "Name on the reel"
  with the field prefilled from the match's team name unless the rules refuse it (the
  stand-in "You" in any case, more than 16 characters counted as code points, nothing),
  the sides line, the score sheet line, SHARE AND MAKE THE REEL and NOT NOW. Typing past
  16 characters is cut and says "Up to 16 characters."; spaces around the name are
  trimmed before it goes, as on the web. SHARE is faded while the name will not do.
  NOT NOW closes the card and sends nothing.
- **The message** (`ShareMessage.make`, section 13 of the web's docs/ROOMS.md): one
  `{t: "share", id: 1, g: {client, engine, start, log, end}}` on a socket of its own
  (`RoomsClient.share`), in 30000-byte parts when long, closed once answered, with a
  45 s wait for the answer. `start` and `log` come from the engine's `renameStart`
  with the name typed, as on the web; `engine` is the version the match was played on,
  and a match from another major.minor than the running engine is refused here as
  `engine`. `client` is `"ios"`, which the server checks and drops: it is never kept,
  and the kept record is the same as a web share's. Nothing else about the device is
  sent. The log's numbers are written as JavaScript writes them, so the message is
  byte for byte the web's apart from `client` (the vectors check the bytes). Before
  sending, the same "too long" checks as the web's: 256 KB, 1000 actions, a 16 KB
  start, and the log as the kept document would hold it against the engine's
  `LOG_BUDGET`.
- **Answers** (`ShareState`, the web's reducer, walked against the web's vectors): a
  code opens the reel card; `engine`, `does-not-replay` and `too-long` stay; `busy`,
  `unavailable` and `too-many` start over when the card opens again; a `failed` error
  gives TRY AGAIN once (the same message again), then "This match could not be shared.
  Not this time."; no connection (`timeout`, `closed`, `unavailable`, or no network
  path, when nothing is sent) gives TRY AGAIN as often as pressed. A share is
  idempotent on the server, so TRY AGAIN after a lost answer gives one link.
- **After the answer** the reel card opens for the returned code with "The link:
  https://throwingwood.com/p/<code>", COPY LINK and, once the reel is done, SHARE (the
  card's own share sheet). The code is kept in memory for that winner card: the button
  then opens the reel card directly. If the share card was closed while checking, the
  reel is not asked until the card is opened again (nothing is sent off screen), where
  the web starts it at once.
- **A sealed pitch.** A pitch code that is a shared match answers the join `sealed`
  (`OnlinePitch.Stage.sealed`). The app reads its kept replay (`RoomsClient.kept`) and
  restores its last snapshot on a board of its own: the winner card, with SCORE SHEET,
  MAKE A HIGHLIGHT REEL for that code and HOME, and no REMATCH. No replay player.
  While it loads the card says "Joining the pitch…"; if it cannot be read, the web's
  words: "Could not show the match" and TRY AGAIN.
- **Verification.** `ShareTests` and `SoloShareTests` in the Kit; `node
  tools/rooms-test.mjs --web <web checkout>` sends the iPhone's message for the
  vector match to the web's rooms server with the web's own share check (on
  127.0.0.1, with a stand-in reel renderer that writes nothing) and checks the code,
  the same code again, the server's `engine` and `does-not-replay`, a sealed join and
  the reel request. Review pictures: `python3 tools/share-snapshots.py <simulator-app>`
  (`--landscape left`, `--ipad`, `--sim-prefix`), into `build/share-shots/`, with no
  network (SHARE_REVIEW stand-ins) and only invented names.

## What travels

- Joining sends the code, the persistent random member ID, name, level and
  the engines carried (`engine` as the room's engine with `+engines`, and
  `engines`). Name edits and a change of the level in Settings update presence (the same `setMe`; in a match it also applies to the player's next throw). Host and
  connection changes come from the rooms service.
- Changed aim state goes as an ephemeral aim cast at most five times a second.
  The four shout choices are casts, limited to one per 700 ms. Up to four
  shouts stay visible for 2.6 seconds. Neither cast identifies the application.
- A set carries the lobby or match document. The action rider carries c and e
  for the recorder: c is left to the engine's default, `web`, as a browser's is,
  so no peer or kept recording tells a phone from a browser; e is the full
  version of the match's engine, as the web sends.
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
With --scene night or neon (capture only) the host picks the scene in the lobby
before the picture, named `<phone>-<scene>[-landscape]-<mode>.png`, e.g.
[the night lobby](review/online/iphone-16e-night-host.png) and
[neon](review/online/iphone-17-pro-max-neon-host.png). `node tools/rooms-test.mjs`
checks that a scene crosses both ways on the local rooms server: the native host's
night and neon reach the web guest's `settings.scene` and its match view, and a web
host's neon and then night reach the native guest's lobby and match.
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
