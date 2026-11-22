# Sound and haptics on the pitch

Practice, solo, both online seats and watchers use the same presentation clock.
SOUND and HAPTICS start on. The practice surface menu and both match menus
store the two switches independently in device preferences. The app requests
an ambient audio session that mixes with music or podcasts and obeys the
silent switch. [Apple's ambient audio category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/ambient).

## The clock

An input frame can deliver several ordered band edges, including both edges of a
band. Only local human input goes through `ThrowInput.feedback`. Aiming,
standing, cancelling, remote aim casts and the computer's wind-up stay quiet.
Once the baton leaves, recording cues are delivered on the first displayed
`showAt(t)` frame that reaches their engine timestamp. This includes slow
motion. A spectator's cues follow the visible pitch even when the next network
action has arrived. SKIP discards the remaining recording and stops active
sounds and pattern tails. A new hand-off or win can still follow the skip.

## Sounds

| Sound | Engine event | Level and playback |
| --- | --- | --- |
| Wood knocks, takes 1–9 | Each piece's first touch, plus each additional wood pair in `timeline.contacts` | Linear gain `0.8 × weight × (0.25 + 0.75s)`, where `s` is the engine's strength. Weight is 1 for the king and 0.9 otherwise. A first touch and its contact share the same knock. |
| King's chord | Start of a king burst | Triangle waves at 523.25, 783.99 and 1046.5 Hz, starting 0, 70 and 140 ms apart. Each attacks to 0.18 in 12 ms, decays exponentially to 0.001 at 700 ms and ends at 750 ms. |
| Baton landing | First ground impact on grass, sand or snow | The web has no ground recordings for any surface. These cues are haptic only. |

The nine WAVs match the web originals byte for byte. The chord follows
the web synthesis. [File-by-file NOTICE](../ThrowingWoodKit/Sources/KubbRenderer/Sounds/NOTICE.md).

The audio engine preloads the WAVs and chord. Each strike picks a different
take from the previous one, preferring free voices. Pitch and duration vary
together. Thirteen precomputed rates span 0.94–1.06 in 0.01 steps. Busy takes
can overlap other voices. An old recording with only first touches uses the
original web volume. A wood pair is heard once per throw, at its first positive
normal impulse. Its strength is the largest point impulse in that step divided
by 2 N·s, capped at 1. The baton landing uses the same curve at its own first
ground contact.

## The other pitches

The Tournament's neighbouring pitches are heard, quiet and far (the owner, 2026-11-22:
"We should hear the sounds from the other pitches."; `NeighbourSounds.swift`, the web's
src/game/neighbour-sound.js and its numbers and rule). The engine's neighbour recording is
small (kubb-engine session/neighbours.lua: only the bodies that moved, 25 poses a second),
and from engine 0.16.0 carries `hits` (the first contact on each body struck, `{ t, id,
strength }`, strength 0 to 1, an impulse of 2 N s being 1) and `landing` (`{ t, strength }`,
the thrown piece's first touch of the ground). The cues come from those, on the field's own
clock (`TournamentNeighbours.clock`, which stops while the match is paused). Each body knocks
once, at its first hit; a share s = 0.35 + 0.65 x strength sets how loud:

| Cue | From the recording | Gain at the pitch beside | Played as |
| --- | --- | --- | --- |
| Hit | A kubb's first hit, the kubb toppled (its body has a `toppleT`) | 0.22 x s | A knock take at rate 0.9 (± 6%) |
| King | The king's first hit, the king toppled | 0.33 x s (1.5 times) | The same, louder |
| Tap | A kubb's (or a stake's) first hit, left standing | 0.22 x s x 0.45 | A knock take at rate 0.945 (0.9 x 1.05, ± 6%): a tap, not a fall |
| Land | `landing.t` | 0.12 x s (0.55 times) | A knock take at rate 0.72 (± 6%): a thud on grass, not wood on wood |

A body that toppled with no hit listed (none should) still knocks at its `toppleT`, at full
weight. Nothing is read from the poses.

The gain is `0.22 x min(1, (8 / d)^1.5)` times the cue's weight, d being the metres
between the neighbour's origin and the player's: the pitch beside (8 m) about 10 dB under
the player's own knock (0.72 at full strength), the row ahead and behind (14.4 m) 0.09,
under 0.02 not played. Pan is where the pitch's middle lies across the camera's view, at
most 0.8 either way (`AVAudioPlayerNode.pan` into the stereo mixer). At most three sound at
once, on three voices of their own, so a neighbour never takes a voice from the player's
throw: a new one takes a free voice, else the faintest sounding when it is louder, else
it is not played. A cue more than 0.3 s behind the clock is dropped, and none is played
within 0.25 s either side of the player's own knock (`PitchSession.ownKnockNear`). They
obey SOUND only, never HAPTICS, and stop with the pitch: none in the background, while
paused or under Reduce Motion, where no neighbours run.


## Core Haptics transients

Times are milliseconds after the engine event. Each tuple gives time,
intensity and sharpness. Intensities and sharpness use the Core Haptics 0–1 scale.

| Cue | Event | (ms, intensity, sharpness) |
| --- | --- | --- |
| Tick | Own arm enters or exits the power or release band | (0, 0.18, 0.75) per edge |
| Release | Own input frame releases the throw | (0, 0.78, 0.65) |
| Contact | A recorded wood pair strikes | (0, 0.15 + 0.80s, 0.65) |
| Landing | Baton first hits grass, sand, snow or the grid | (0, 0.10 + 0.35s, 0.20 grass / 0.10 sand / 0.04 snow / 0.55 grid) |
| Ring | A ground impact of strength 0.1 or more in a scene that rings (Techno), but within 30 ms of the baton's landing | (0, 0.08 + 0.3s, 0.9) |
| King down | King burst on the displayed throw | (0, 0.90, 0.32), (85, 0.66, 0.18) |
| Win | Newly displayed winner is the solo player's side or the online member's playing side | (0, 0.40, 0.45), (95, 0.72, 0.70) |
| Hand-off | Presentation opens the engine's hand-off card | (0, 0.32, 0.40) |

Hardware capability and the HAPTICS switch gate the haptic engine. Each
pattern starts immediately. The app keeps active players so a skip or
background transition can stop a second pulse already scheduled.

## Measurement and device review

On an iPhone 17 simulator running iOS 26.2, nine warm knocks reached their
first non-silent mixer sample in **12.6–22.5 ms**, median **17.5 ms**. The
simulator I/O buffer was 2.67 ms. With the neighbours' three voices and their lower takes
added (2026-11-22, same simulator) nine warm knocks took **12.5–22.3 ms**, median **18.4 ms**,
and eight neighbour sounds (hits and landings, panned) **12.9–22.5 ms**, median **15.7 ms**. This fits two 60 Hz display frames (33.3 ms).
The timing test compares the cue's host time to the timestamp of the first
PCM sample exceeding 0.001. Speaker, Bluetooth and physical display latency
still need measurement on an iPhone.

The feedback fixtures are excerpts of synthetic recordings made under wasmoon
with the app's tagged engine. Regenerate them with
`node tools/feel-fixtures.mjs <web checkout>`. The clean hit also drives
the actual display controller twice, once through slow motion to rest and
once with SKIP before impact. The double, three surface misses and king
fixture pin event time, gain and pattern. The simulator verifies the pulse
data and the callback clock. It cannot reproduce the feel of Core Haptics.

All haptic intensities, sharpnesses and spacings, the 2 N·s saturation point,
knock gain floor and surface differences are provisional. Judge ticks during
a fast swing, simultaneous wood/ground cues, soft landings, king weight and
win/hand-off distinction by hand. Check the physical silent switch, other
audio, system haptic preferences, interruptions, route changes, Bluetooth and
ProMotion sync on a phone.
