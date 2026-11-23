# A pitch is a link

Home → Play online → Start a pitch makes a random code. The lobby displays the
canonical HTTPS link, Copy and the system share sheet. Join a pitch accepts
the same link or its code. Both paths pass a PitchLink to the same entry point.
A shared link currently opens the website in a browser.

## From lobby to match

The socket opens when the player starts or joins a pitch. The host initializes
the lobby document. Presence sends the device's name, a generated one, as it is, and
the engines this build carries (`pitch.announce`, below). The lobby shows names, sides,
watchers, host and connection state. A member can join either team or sit out.
The player's name is the device's (`PlayerName`), picked in the lobby's You row (the name row, "Names" below) or in Settings; a change goes to the room at once (`profile`). A member sends no level: engine 0.13 throws every person on one meter, and the lineup takes "club" for a member that names none (AGENTS.md "Levels are the computer's"). Team capacity, the computer's levels and match options come from the engine. The host sets
options, invite-only or open access, and starts. An empty side plays as the
computer. The options offered are the `MATCH_OPTIONS` of the engine the next match
would run on (`PitchController.lobbyEngine`, the room's engine counting this member),
and every option is read through that engine's `optionsOf` (since 0.9: the five in
`options` and the engine's own `computer` and `scene` from the document's `settings`,
kubb-engine docs/PITCH.md difference 9), or `lobbyOf`'s `options` on an older engine,
which has no such call. The Kubbs row is not offered (`OnlinePitch.hiddenRows`, the web's HIDDEN_ROWS: the 1.0
design's scene decides the set); the room's stored set is left as it is, Classic unless an
older client chose another, and the match plays it. So on 0.9 the host sets Computer (the computer's level,
Beginner, Club or Pro) for the match; once a tester on 0.8 takes a seat, the row goes,
since a 0.8 match would not take it, and a 0.8 client's own writes keep the host's
setting. Scene (the engine's seven, first, from the lobby engine's `pitch.optionRows({ scene })`) is the host's too, written to
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
An open pitch's host sends `open {seats, state}` when either changes, and a new host
sends it afresh (`open: null` when the pitch is invite only); the pitch server lists it
on `GET /open` while the host is there.

### Engines in one room

A match belongs to the engine major.minor it started on, for its whole life
(kubb-engine docs/PITCH.md "Engines in one match"), and the app carries only the
engines we decide to support, today the newest alone (docs/ENGINES.md). It still
speaks the engine's contract for clients that carry several ("The pitch's engine",
"Speaking down"), so an older build or a web tab that carries several agrees with it:

- Presence is `pitch.announce`: `engines`, every major.minor this build carries, and
  the legacy `engine` written as the room's engine with the `+engines` mark
  (`"1.0+engines"`). The room's engine is `pitch.engineFor` counting this member;
  before the room is known it is the newest. It is announced again whenever the
  answer changes.
- The lobby asks `engineFor` (the host and the lineup; watchers do not count) and
  shows nothing about versions while there is an engine everyone carries. When there
  is none (a player on an older build, which carries no 1.0, or on a newer one) the
  lobby says who must update in the web's plain words (`VersionWords.lobby`), never
  naming a version, and START is disabled:
  - this device is the one without the room's engine: "This pitch needs the newest
    version of the game. Update to play.";
  - players on an older version (or naming none): "Ola has an older version of the
    game. This pitch needs the newest version of the game. Ola: update to play.";
  - players on a newer version: "Ola has a newer version of the game than this app.
    Update the app to play, or Ola can watch."
- START works the room's engine out again inside the document reducer, from the
  document and presence of that write, and refuses, writing nothing, when there is
  none or this build does not carry it; a refusal by the engine's own `startCheck`
  says "Ola is on another version of the game. This pitch needs the newest version of
  the game: update to play." A match is never started on an engine the app does not
  have.
- Entering a match (a document, a rejoin, a gap) runs it on the engine of its
  `match.engine`, checked by that engine's `mayPlay`. A match on an engine this build
  does not carry is refused and never played: the version card ("A newer version":
  "This pitch is playing on a newer version of the game. Update to play."; "An older
  version": "This pitch is playing on an older version of the game, which this app no
  longer plays. This pitch needs the newest version of the game: the host must update
  to play.") with WATCH, which shows it from its snapshots as the web does.
- A seated guest whose host carries no engine this build does sees the same card.

The review pictures of the two cards (docs/review/online `newer` and `older`) are the
old rooms harness's and keep the earlier words until a pitch server harness makes them
again.

### Names

Every name on a pitch is a generated one (AGENTS.md "Names are generated"; the web's
docs/MULTIPLAYER.md "Names", PROTOCOL.md section 6a). A client is not proof, and a
check that reads only some of a snapshot's fields can always be got round (a forged
start can keep generated names in `opts.teams` and put typed text in `save.game.teams`,
which `restore` builds the match from), so the engine judges whatever arrives whole
(engine 0.13.4, `names.check` and `restore`'s strict door; kubb-engine docs/SESSION.md
"A match from outside"). `names.valid` stays the check for a single name (the name row,
the share card's name). Nothing shows a refusal's `from` or `text` (a forged path can
carry submitted text).

- **A member's and a team's name** (`PitchController.shownNames`, `nameOf`,
  `teamNameOf`): `names.check({ document, members })` of the lobby, kept while the
  document and members are the same. A member's name it refuses (or none) is "Player n",
  n its place on its side (as the engine's lineup numbers a player with no name; a
  watcher, its place on the pitch); a team's is "Team A" / "Team B"; a player of the
  match who has left is the match's own name for them, checked. The lobby, the turn line
  ("Player 2 throws"), the shouts and the version lines use it. In the lobby two members
  with one name are told apart, by the pitch's order: "Mighty Maple", "Mighty Maple II",
  "III" (`Names.apart`); the name itself is never changed.
- **A side of several** plays under a team name the host rolls when the side first has
  two players (`rollTeamNames`) and may change in its name row ("Team A's name"),
  written to the document's own top-level `teamNames` (`{"A": "Birch Batons"}`, the
  web's `setTeamName`; the engine's reducers keep a key they do not know). The lobby
  shows it under the side as PLAYS AS: the host's name row, everyone else the name. A
  side of one plays under its player's name (the engine's matchOptions).
- **START** checks every name first (`checkedLineup`: a player's name that fails is
  "Player n"; `teamNamed`: a side of several takes the lobby's team name, or one rolled
  then), so an honest host never starts a match the pitch server would refuse.
- **This member** sends only a generated name (`setMe`, `profile`); the pitch server
  drops any other. A write it refuses `bad-name` reads as any refused write: "The pitch
  did not take that. Try again." (the web's words).
- **A match's snapshot**, wherever it is adopted (`PitchController.begin`: a `start`,
  entering, a rejoin, joining part way, every resync): `names.check({ snap })`, then
  `restore` with `{ snap, names: "check" }`, which refuses it before anything changes. A
  refusal is `State.namesRefused` and `Stage.namesRefused`: "Cannot show this match" and
  "This match has a name the game did not make, so it cannot be shown.", with HOME; the
  match is never shown or played. The board adopts a snapshot through the strict door too
  (`OnlinePitch.restore`): a watch-only match on an engine this build lacks, which the
  controller hands over unchecked, is refused there, and the refusal belongs to that
  match (its `n`) through every refresh until another match or the lobby.
- **A shared match opened by its code** (a sealed pitch): its kept replay whole,
  `names.check({ replay })`, and its last snapshot through the strict door
  (`PitchSession.restoreFromOutside`), the same card on refusal. The app has no replay
  viewer, so it never calls `replayLoad` itself.
- **A share** (`ShareMessage.make`): the engine renames only a start its own options make
  (`renameStart`), and judges the renamed start and log (`names.check({ replay })`); a
  refusal is "This match did not pass the check, so it cannot be shared."

### Computer players

Engine 0.17 (kubb-engine docs/PITCH.md "Computer seats"; the owner, 2026-11-22: "in online
play we should be able to add computer players to the match, with a specified level. I may
have three friends and we want to play a team of three computers (two at club and one at
pro). Or we want to play 2 v 2 where Tyler and I each have a pro computer player as a
partner."). A team holds people and computer players together, six at most, each computer
at its own level. The web is the reference for every number and word (its docs/SYSTEM.md
"Computer seats", src/ui/lobby.js); the words are `SeatWords`.

- **The rules are the engine's.** The host's ADD COMPUTER (under each team, plain) calls
  `pitch.addComputer` with a generated player name nobody on the pitch has, from this
  device's own draw (`PitchController.addComputer`, the web's freshSeatName), at Club and
  last in the team's order; a seat's level bar (Beginner | Club | Pro) calls
  `setComputerLevel`, ↑ and ↓ and TO A / TO B call `moveComputer` (up and down to the
  document's place of the row beside it, across last in the other team's order) and REMOVE
  (quiet) `removeComputer`. Every refusal (a full side, a match running, not the host, a
  level a seat may not have) is the reducer's, which changes nothing. ADD COMPUTER and JOIN
  are off for a side of six, people and seats together, and the head counts both ("3 of 6").
- **The rows** (`OnlinePitch.roster`, from `lobbyOf`'s teams, in throwing order): a member
  as before, a seat as `SeatRow`: the host's three lines under a 2 pt ink rule (the name and
  " · computer", the level bar, the moves and REMOVE), everyone else's one line, "Bold Birch
  · computer · Pro". A seat's name shows only where `names.check({ document, members })`
  passes its `computers.<id>.name`, else "Computer" (`PitchController.seatName`). VoiceOver
  reads a seat as one group, "Bold Birch, computer, Pro, 2 of 3 in Team A", its controls
  "Bold Birch's level", "Move Bold Birch up", "Move Bold Birch down", "Move Bold Birch to
  Team B" and "Remove Bold Birch", ADD COMPUTER "Add a computer player to Team A", and each
  change the host makes is said once ("Bold Birch joins Team A at Club.", "Bold Birch now
  plays at Pro.", "Bold Birch moves up.", "Bold Birch moves to Team B.", "Bold Birch is off
  the team."; `OnlinePitch.seatNews`).
- **Kid.** With the Computer setting Kid every seat reads Kid in place of its level (its
  own level kept for when Kid goes) and the team says "Kid match: every computer plays as
  Kid." The Computer row is "An empty side plays as" (the engine's levels) while a side has
  nobody and no seat; with no empty side and a seat on the pitch it is "Kid match", Off |
  On (On is Kid, Off sets it back to Club); with neither it is not shown.
- **START.** `startCheck`'s refusals of the lineup itself (`why`: `person`, `size`,
  `level`) show the engine's `text` in the lobby's note (`PitchController.startRefusal`);
  the lobby stays a lobby. The engine's `engineFor` is asked with the document as it is,
  seats and all: from engine 1.0.0 a seat carries the pitch's engine, so `engineFor` leaves
  seats out of the players it asks (kubb-engine docs/PITCH.md "Computer seats";
  `ComputerSeatTests`). Engines 0.17 and 0.18 counted a seat as a player carrying none, and
  the app took the seats out first; that workaround went with them. A side of several, seats counted, plays under a team name.
- **The match.** Who acts is the engine's (`controlFor`, `mayAct`): the host's device runs
  every computer, a side's or a seat's, through its board's frames, and everyone else
  holds at the release and draws the action when it arrives; a person never acts for a
  computer partner. A team with a person raises and places by its people, a team of
  computers by itself at its strongest level. While a computer player throws, the header's
  line ends "· computer · pro" (the web's hud.js, its line lower case after the first word)
  and the name under it is "Bold Birch throws" (`actorDescription`; a side the computer
  plays whole still says "Computer throws"); a turn that opens with one says "Bold Birch
  throws first · computer · Pro" under the hand-off's line and on the watched turn's banner
  (`card.handoff.throwerCpu`). A computer's throw has no hand-off card, only the WATCH tab.
  `ComputerSeatTests` (the reducers, six a team, a lineup of computers refused, a 2 v 2
  with a pro partner each side in step between two controllers, every action stamped) and
  `ComputerSeatLobbyTests` (the phone host's lobby, and a phone joining a pitch that
  already holds seats, through to a computer player's throw).

## One match, two clocks

PitchController owns the authoritative native session, room version and
compare-and-set writes. OnlinePitch gives the solo screen's PitchSession a
separate presentation session. That separation lets the network advance while
the board is still showing the preceding throw. The display clock only advances
the dial or computer while the room grants that seat control. A player can
choose a legal end for a raise or place a punishment kubb using the same board
controls as solo, including AUTO ALL and the match's Raising (in the
online menu too); automatic raising acts only while this seat holds control. The host runs the computer. Spectators see the thrower's
camera. Someone else's turn shows its hand-off as a banner over the top
(`HandoffBanner`, `MatchCards.watchBanner`, 2.5 seconds) instead of the modal card, so
the thrower's live dial is seen under it; the thrower's own card stays modal.

The dial releases an engine action. The controller applies it and sends it at once as
an `act` (`id`, `n`, `seq`, `a`, `h`, `snap`, `over` on the last, `c: "ios"`), never
waiting for the last one's `ok` (docs/ROOMS-CLIENT.md). A remote action is verified in
the controller and queued for presentation. A peer's throw waits for its aim to play
out first (`AimBuffer.holdFor`: at most 250 ms, none when the last aim is more than
1.5 s older than the throw), so a watcher sees the swing let go and then the throw.
The board applies it, checks the hash, and plays its recording using showAt; a `raise`
of the kubb on the screen is watched tipping up at the sender's pace (docs/MATCH.md),
faster for each action waiting behind it. The queue waits while the board plays a throw
or watches a raise, and drains on the first frame the board is free, judged from the
state rather than from the moment it ended, so a playback or raise ended anywhere else (a
tap's skip, `OnlinePitch.skip` and `skipRaise`, or a resync) never leaves an action
unapplied (Codex on PR #46). What a watched raise allows is below ("A watched raise online").
A gap or disagreement restores the head snapshot. After a win the host can put everyone back in
the lobby with the same teams.

### A watched raise online

A raise is watched tipping up (docs/MATCH.md) while the board still shows the raise need
and the engine may already be past it, so what may happen then is decided in one place:
`RaiseWatch` (what is watched) and `Seat.decide` (what the seat makes of it), both in
KubbRenderer; `RaiseWatchTests` and `OnlineRaiseTests` hold every row with an outcome
(Codex on PR #46, three findings in this seam). Whose raise, and when:

- **This device's own, lead-in** (`ownLeadIn`): AUTO ALL, REST OF GAME or the menu's
  Raising: Automatic has scheduled the kubb's `raise`; the kubb lies, the action is not
  yet applied or sent. AUTO has no lead-in.
- **This device's own, tipping** (`ownTipping`): the action has been applied and sent
  (the write may still be landing); the kubb tips up, then stands. Between two kubbs
  nothing is watched until the next need is adopted and the seat gives the right to act
  again after the write lands.
- **Another member's, arriving** (`arriving`): already applied from the queue, tipping at
  the sender's pace, faster for each action waiting behind it.
- **The engine's own** (`engine`): the raises the engine made itself and the punishment
  kubbs it placed (a lobby's Raising: Automatic), from engine 0.16.0's
  `need.setup.settled`, played after the throw before them on every member's and
  observer's board, each in the frame the list gives (`OnlineRaiseTests` holds its queue
  and skip).

| | Own, lead-in | Own, tipping | Arriving | Engine |
| --- | --- | --- | --- | --- |
| New input (gestures, the tray, the meter) | Blocked; a tap skips | Blocked; a tap skips | Blocked; a tap skips | Blocked; a tap skips |
| Submitting | Its scheduled action keeps its authority and is sent when the kubb tips | Already sent; the write lands as any other | Nothing to send | Nothing to send |
| The seat (a shout, a member joining or leaving, a seat change) | Keeps the right to act while the pitch still gives it; if it does not (moved off the team, the seat changed, an action arrived, the pitch closed) the unsent action is dropped before it is applied: nothing sent, the engine untouched, the kubb lying | No right to act while the write is out; the tick seats again after | No right to act until it ends; the tick seats again on the first free frame | As arriving |
| Hand-off banner | None | None | None until it ends | None until it ends |
| Another member's aim | Not drawn | Not drawn | Not drawn; the newest is drawn on the first frame after | As arriving |
| Incoming actions | Wait in the queue (and drop the unsent raise, as the match moved on) | Wait in the queue | Wait; drained on the first free frame, judged from the state | As arriving |
| A resync, a rematch | The show is cleared, its action never applied | The show is cleared | The show is cleared, the queue with it | As arriving |
| The pitch closing, the app in the background | The unsent action is dropped (background) or the board let go (closing); the resync on return starts afresh | Frames stop; the resync on return clears it | As tipping | As tipping |

The header keeps the raise's words, and the meter, nudge, coach, minimap and their
readers stay away, in every column.

The pace between actions is one tune, `Pacing` (KubbRenderer), the web's
src/game/pacing.js: 0.8 s rest after a throw, 0.4 s before the first kubb of a turn's automatic raise and a beat of at most 0.5 s a kubb after it (4 s a whole raise at most). Every screen
and every client waits the same, so a watcher keeps up with the thrower.

## The highlight reel

When the finished match has a kept replay (`PitchController.finishedReplay`:
the engine's `pitch.replayOf` is not null, the same test as the web's WATCH
REPLAY), the winner card adds a button, MAKE A HIGHLIGHT REEL. It opens the reel
card (`ReelCard.swift`), which holds a pitch code and, optionally, the match it
is for (`HighlightReel` in KubbRenderer), so a solo match uses it once a share has
given it a code ("Sharing a match against the computer" below). The web's docs/REEL.md "The iPhone" is
the contract, and the card's words (`ReelWords`) are the web's, word for word.
The card's title is "Highlight reel" in every state.

- First the card checks that the pitch still keeps this match, with the API's
  read-only `GET replay?pitch=` (docs/ROOMS-CLIENT.md), which starts nothing: the
  same `n`, and the same hash when both have one. A just-ended match's keep may
  still be on its way, so it looks 4 times, 2.5 seconds apart, before it says
  "This match has no replay, so it cannot have a reel." When the room keeps a
  newer match (a rematch since), it says "This pitch has moved on to a newer
  match." Opened with a code alone there is nothing to compare, and any kept
  replay is taken.
- Then it asks the API with `POST reel {pitch, v}`. Every `reel` request (the first, each poll, a reopened card, TRY
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
offline also turned left (`--landscape left`) and on both iPads upright and turned
(`--ipad`, `--ipad --landscape left`); `tools/review-set.sh reel` takes them all. An iPad
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
(`KubbPitch/Share.swift`), and `ShareTests` checks each one against the web's own
`SHARE_WORDS` in `Fixtures/share-vectors.json` (made by `node tools/share-vectors.mjs
--web <web checkout>`, which only reads that checkout).

- **Where.** The winner card of a finished solo match against the computer (not
  practice, not online) shows MAKE A HIGHLIGHT REEL when the whole match is kept on the
  device and ends on the match shown (`PitchSession.shareableMatch(save:)`: the
  finished file's last hash is the engine's, side B alone is the computer). A finished
  save restored by a build from before the trail has none, and the button is not shown.
- **The card** (`ShareCard.swift`, `SoloShare`): the about line, "Name on the reel"
  with its name row (no text field: "Names" below), starting from the name the match
  was played under when it is a generated name, else the device's name
  (`ShareName.fromMatch`), the sides line, the score sheet line, SHARE AND MAKE THE
  REEL and NOT NOW. A name that does not pass (none can come from the row) fades SHARE
  and, once pressed, says "Pick a name for your side.", as does the server's refusal
  `why: "name"`. NOT NOW closes the card and sends nothing.
- **The message** (`ShareMessage.make`, section 13 of the web's docs/ROOMS.md): one
  `g: {client, engine, start, log, end}` sent to the API as `POST share {g}`
  (`PitchAPI.share`), with a 45 s wait for the answer. `start` and `log` come from the engine's `renameStart`
  with the name picked, as on the web; `engine` is the version the match was played on,
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
- **A sealed pitch.** A pitch code that is a shared match has nobody on it; a join
  that finds no pitch asks the API's `replay`, whose `sealed` says it is one
  (`OnlinePitch.Stage.sealed`). The app reads that kept replay and
  restores its last snapshot on a board of its own: the winner card, with SCORE SHEET,
  MAKE A HIGHLIGHT REEL for that code and HOME, and no REMATCH. No replay player.
  While it loads the card says "Joining the pitch…"; if it cannot be read, the web's
  words: "Could not show the match" and TRY AGAIN. A kept replay made on an engine this
  build does not carry is not shown: the card says "This match was made on an older
  version of the game and can no longer be replayed." with HOME and no TRY AGAIN (review
  state `sealedold`; docs/ENGINES.md).
- **Verification.** `ShareTests` and `SoloShareTests` in the Kit, and `ReelTests`
  for the API's answers against an injected fetch. The old cross-play script against the
  rooms server (`tools/rooms-test.mjs`) went with it; a share has not been sent to the
  pitch server's API stand-in from the app yet.
- **Pictures** in docs/review/share (`tools/review-set.sh share`, 2026-11-22): every
  state on both phones upright, and the winner, card, long card, checking, failed and
  shared states on their side and on both iPads, e.g. [the card](review/share/iphone-16e-card.png)
  and [the reel's card after a share](review/share/iphone-17-pro-max-shared.png). The
  sealed pitch's `sealed` and `sealedold` are not among them: the solo fixture they
  restore through the engine's check from outside is refused today.

## What travels

- Joining (`/ws?pitch=<code>`, no Origin) sends the persistent random member ID, the
  role, name and the engines carried (`engine` as the room's engine with
  `+engines`, and `engines`), and on a rejoin the document version and the `n` and `seq`
  of the last action held (own actions in flight not counted). A name change in
  Settings goes as `me`.
  Members, host and connection changes come from the pitch server, which picks the host.
- Aim goes as a cast `{t: "aim", s, k, c}` (`k` counts this device's samples, `c` its
  clock) at most 15 a second and only when it changed; the aim just before a release
  goes with `all: true`, which the pitch never thins. The four shouts are casts too,
  one per 700 ms, and spend an aim slot. Up to four shouts stay visible for 2.6
  seconds. Neither cast identifies the application.
- Lobby writes are compare-and-set `set {base, doc}`; START is one `start {base, doc,
  n, h, snap, meta}`, the document getting only the match header `{n, players, cpu,
  host, engine}` and `meta` being `{v: 1, setup, engine, version, players, cpu}`.
- Each action is one `act` with `c: "ios"`. The pitch server keeps the match from
  `start`, the acts and `over`; nothing else is sent to record a shared match (no
  `keep`, no `game` message for it).
- SEND FEEDBACK freezes the displayed action trail when the card opens. A throw
  report (`kind: "throw"`) sends the two answers; Something else
  (`kind: "feedback"`) sends one trimmed text of up to 2000 characters. Both include
  the pitch code (`pitch`), the document version and the match's head as the client
  holds it (`match: {n, seq}`), viewport, build, need, level, last action and throw
  result, pieces, options and replay snapshots. Member IDs are pseudonymised in the
  captured state, including snapshot strings. Answers are limited to 1,000 Unicode
  scalars each. History, pieces and the after snapshot are dropped in that order to
  fit 64 KiB. It goes to the API as `POST report {r}` with the same client and engine
  tags as a game record. The review modes `report` and `feedback` show the card in
  each kind.

## Observers and open games

The web's docs/OBSERVER.md, its numbers and words. `?observe=1` on a `/p/` link
(`PitchLink.observe`; `url` never carries it) joins as an observer: a member with
no seat (`PitchController(observing:)`). It never acts and never writes the
document: `prepareLobby` never runs, `reduce`, `start`, `take`, `frame`, `commit`,
`castAim` and `shout` refuse, its control has no sides and `mayAct` is false. It
never hosts: the pitch server never hands the host to an observer (PROTOCOL.md
section 3), so there is nothing to step back from.

An observer joins with a member id of its own, never the player's
(`ObserverMemberIDStore`, kept for the app's run, as the web keeps `observerId()` for
the tab; `MemberIDStore.joining(observing:)` picks it). The room gives a join with a
known id that member's place, so a host who left its pitch and tapped WATCH on it
would otherwise come back as a host that never acts, and the pitch would stall
(the web's review finding, 2026-11-20).

- **In a match** the board watches (`PitchSession.watching`) in the wide view and
  the free camera (docs/RENDER.md "The watcher's wide view"). No SHOUT. The hand-off
  card names both teams with their base kubbs (`HandoffWords`, "NORTH BASE 5") and
  says "They throw 6 batons."; WATCH, and it closes by itself after 2.5 s.
- **Between matches** the observer's own card (`WatchCard`): PITCH code, Watching,
  "Waiting for Maple to start the match." / "Nobody has picked a side yet.", each
  team, who is watching with "(you)", JOIN THIS PITCH (the link without observe) and
  HOME. The web's WATCH THE LAST MATCH is not here: the app has no replay viewer.
- **An empty pitch**: the observer's join made the room, so it leaves at once and
  shows No game here (`Stage.noGame`) with JOIN THIS PITCH and HOME. The words point
  to the Play online screen, where the app lists open games, not the web's page.
- **Open games** (`OpenGames`, `OpenGamesSection`): under START A PITCH and JOIN A
  PITCH, the pitch server's `GET /open` (`PitchAPI.openGames`, 10 s deadline), each row "3 of 12 on the pitch · in play · made 4 min ago"
  with JOIN and WATCH. A look every 30 s while the screen shows and the app is in
  front; codes outside the server's pattern are left out. Never a name.

Review modes: `observe`, `observemoved` (the view turned, lower and closer),
`watchcard`, `noGame` and `opengames` (two open pitches listed by invented hosts).
Pictures in docs/review/observer: the 16e upright and on its side, the iPad Pro 13
after a move, Night, the card, No game here and the list.

## Leaving and reconnecting

A dropped socket retries with the same device member ID: the first time at a random
wait under 300 ms, then 1 s doubling to 10 s, each a quarter either way at random (the
web's numbers). The device coming online or the app becoming active retries at once
(or sends a `ping` on an open socket). The literal `ping` goes after 20 s with nothing
heard, and no answer in 10 s means a dead socket. A lobby write or START unanswered in
10 s reconnects to find out. The rejoin resumes by sequence (the missed actions, or the
whole match from its head when too far behind) and actions still on their way go again
with the same ids, answered once. Background closes the socket, keeping the pitch in
memory; foreground rejoins. Home leaves the pitch. The pitch server hands the host on
by itself when the host leaves or is away; nobody claims it. Still not connected after
8 s, the screen says it cannot reach the server and the client keeps trying; a drop
after joining stays RECONNECTING. `replaced`, and a join refused as full, no-pitch,
bad-member, bad-role, already-joined or bad-message, end the client for good. Every
such state offers Home.

## Scope and verification

The addresses live in `PitchConfiguration`, one value each: the pitch server
(`wss://throwingwood-pitches.throwingwood.workers.dev`), the API
(`https://throwingwood.com/api/`) and the site. A Debug build takes
`PITCH_SERVER_URL`, `PITCH_API_URL` and `REELS_URL` from the environment, and a
simulator build defaults to 127.0.0.1 (the pitch server's `wrangler dev` on 8797, the
API stand-in on 8798). The Kit's tests run against `FakePitch`, an in-process pitch
server written from PROTOCOL.md, and `LocalPitchServerTests` plays a short match over
real sockets against the pitch server's own `wrangler dev` on 127.0.0.1 when
`PITCH_LOCAL_URL` names it. The review harness that made the pictures below
(`tools/online-snapshots.py` and `online-review.mjs`) seated its invented players
through the web's old Room client and its local rooms server, and was removed with
them on 2026-11-21. A harness on the pitch server's `wrangler dev` is open; the app's
simulator checkpoints (`ONLINE_REVIEW`, `OnlineReview.swift`) stay for it, and the
modes below are its scenarios.
Review images and baselines are in docs/review/online.
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
[neon](review/online/iphone-17-pro-max-neon-host.png).
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
Archived replay playback, embeds, browser shortcuts,
and the browser's full menu are outside this screen. The phone does
not resume a room after process termination. A player can rejoin by link or
code with the same member ID. An incoming pitch link uses the same join flow
as a pasted link. See [Universal Links](UNIVERSAL-LINKS.md) for activation.
