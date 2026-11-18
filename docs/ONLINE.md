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
card and watch a readable snapshot. The iPhone uses strict admission. The web
still temporarily admits untagged older tabs.

## One match, two clocks

PitchController owns the authoritative native session, room version and
compare-and-set writes. OnlinePitch gives the solo screen's PitchSession a
separate presentation session. That separation lets the network advance while
the board is still showing the preceding throw. The display clock only advances
the dial or computer while the room grants that seat control. A player can
choose a legal end for a raise or place a punishment kubb using the same board
controls as solo. The host runs the computer. Spectators see the thrower's
camera. A WATCH handoff closes after 2.5 seconds, or on the next action.

The dial releases an engine action. The room controller applies it, then sends
the tagged rider with the committed snapshot and hash. A remote action is
verified in the controller and queued for presentation. The board applies it,
checks the hash, and plays its recording using showAt. A gap or disagreement
restores the room snapshot. After a win the host can put everyone back in
the lobby with the same teams.

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
- Report a throw freezes the displayed action trail when the card opens. Send
  includes the two answers, pitch code and document position, viewport, build,
  need, level, last action and throw result, pieces, options and replay snapshots.
  Member IDs are pseudonymised in the captured state, including snapshot strings.
  Answers are limited to 1,000 Unicode scalars each. History, pieces and the
  after snapshot are dropped in that order to fit 64 KiB. The report uses a
  short-lived unjoined socket, waits for reported, and closes. It carries the
  same client and engine tags as a game record.

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

The phone uses the pointer dial, native sharing, pickers and a portrait HUD.
Open-pitch discovery, archived replay playback, embeds, browser shortcuts,
and the browser's full menu are outside this screen. The phone does
not resume a room after process termination. A player can rejoin by link or
code with the same member ID. An incoming pitch link uses the same join flow
as a pasted link. See [Universal Links](UNIVERSAL-LINKS.md) for activation.
