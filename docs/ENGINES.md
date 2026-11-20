# Engines the app carries

A match belongs to the engine it was started on: its `match.engine` major.minor, for
its whole life (kubb-engine docs/VERSIONING.md). A new minor can change how a throw
goes (0.8.0 changed a person's baton planned under 2 m), so a match from an older minor
only plays on, or back, as it was on that minor's engine. The app carries the newest
engine and the older minors it still plays, one per major.minor, laid out as the web's
`vendor/engine/` and `vendor/engines/` (the web's docs/ENGINES.md).

## Vendoring

| Folder | What |
| --- | --- |
| `ThrowingWoodKit/Sources/KubbEngine/Engine/` | the newest (`TAG` in `scripts/vendor-engine.sh`) |
| `ThrowingWoodKit/Sources/KubbEngine/Engines/<major.minor>/` | each of `OLDER`, laid out the same way |
| `ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden/` | the newest's golden driver and corpus |
| `ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/engines/<major.minor>/golden/` | each older one's |

`scripts/vendor-engine.sh sync` writes every one from its own tag; `check` verifies each
against its own `engine.json` and corpus, and fails on an engine folder `OLDER` does not
name. None is ever edited. Today: 0.9 (v0.9.0, corpus 0.9.0, 13 matches), 0.8
(v0.8.2, corpus 0.8.0, 13 matches) and 0.7 (v0.7.4, corpus 0.5.0, 12 matches). 0.8 stays
for testers on build 121 and kept 0.8 matches; 0.7 for build 113 and kept 0.7 matches.
Each older engine is about 0.8 MB and loads only when a match on it is met. `GoldenTests` plays every carried engine's corpus.

## In the app

`Engine.carried` lists them newest first (read from the bundle), `Engine(minor:)` makes
one, and each is a Lua state of its own, made the first time something needs it: a
session that never meets an older match never loads an older engine.

- **New play is on the newest**: a solo match, practice, and the engine a member
  announces before the room is known.
- **Online** (docs/ONLINE.md "Engines in one room"): the member announces every engine
  it carries (`room.announce`), the room's engine is `room.engineFor` of the host and
  the players, START stamps the match with it, and the pitch (`EngineShelf` in
  `PitchController`, `PitchSession.useEngine` for the board) plays each match on its
  own engine.
- **A kept solo match** resumes on the engine its trail names (docs/MATCH.md "The
  replay trail"), so its share, score sheet and report are that engine's.
- **A shared match opened by its code** (a sealed pitch) is restored on the engine its
  kept replay names (`engine`, `room.replayOf`'s copy of `match.engine`).
- An engine this build does not carry is never guessed at: a match on it is refused
  with the version card, and a kept one with nothing naming a carried engine plays on
  the newest, as before there were several.
