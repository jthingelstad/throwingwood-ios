# The iPhone pitch

Practice opens on grass. The surface picker changes the ground in the current session. Tap the pitch to put the circle there (a tap on or beside a standing kubb aims at it), or drag anywhere to move the circle by the finger's travel; lifting snaps it to a kubb it is near. Press the dial near six, wind back on the left, flick through six and lift on the right. Bringing the arm back slowly lets it down. The blue range is the release angle. The orange range is the backswing. Practice takes batons and the engine's `pointer` tune.

## Picture and clock

`KubbRenderer.PitchRenderer.draw(in:size:camera:scene:)` takes a top-left-origin Core Graphics context. Size is in points. The renderer saves and restores the caller's graphics state. Its only persistent geometry is the immutable, seeded ground texture and the six default stakes. A render never calls Lua.

- The camera is the engine's eye, orthonormal basis, focal length and principal point. In eye space, depth clips at 0.05 m. Projection divides right and up by depth, inverts screen y and applies the principal point. Landscape centres the 400 × 240 reference frame at `min(width/400, height/240)`. The portrait fit is described below. Sky and ground extend to every edge. The same transform casts drag points back onto z = 0.
- The scene accepts surface, set, posed items, advantage line, target, arc, thrower, raise footprints and punishment keep-out circles. The local z axis runs along each piece. Kubb, king, baton and stake extents, six stake positions, paint and team bands, light direction, hard shadows and near-plane clipping follow the web renderer. Nearby overlapping boxes use separating planes to correct depth order. The arc stops 0.45 m short of its target so the kubb stays visible.
- `PitchSession` owns the main-actor engine for practice and solo. A tap or target drag calls `setTarget` (`AimDrag`). A display tick consumes at most one pointer frame. `ThrowInput` isolates input sampling, lift and cancellation. The pointer implementation uses forward degrees from six, preserving touch boundaries and accumulating elapsed time between samples. Its stationary feed matches the web's stop detection. The display link sleeps on a still, unattended pitch and stops outside the active scene.
- The release frame already contains the applied throw. Decode its tracks, index moving bodies by id once, and retain static poses. Between samples, interpolate position and normalize the shortest-path quaternion blend. The session's one `showAt` call per moving frame supplies the camera, speed and dial. The typed playback response skips its redundant items array. The release tick can make both calls. Reaching rest holds the last picture for 0.8 s, then one `view` loads the next aim. Result feedback stays for six seconds into that aim.
- Timeline bursts follow world anchors. Flash, pop, the second KLAK, king crown and wood chips run on elapsed display time while the session can slow flight time. The engine supplies the flag and verdicts. Off-target words go first. The display face is Londrina Solid Black, with its OFL in the app bundle.

## Portrait framing

When height exceeds 1.05 times width, the scale is `1.3 × width / 400`. Frame y = 112 sits at 33% of screen height. The projected target gets 40 reference pixels of horizontal room; the pan is bounded by the cropped reference frame. The current pan applies immediately and survives release. The same fit projects the wood, target circle, burst anchors and plan, and casts touch points back onto the pitch. Human placement uses the web's separate still framing at 42% height, with 1.8× magnification for raising and 1× for punishment. These are host presentation transforms on the same cameras. The centred far base kubb on fresh grass measures **15.84 pt** on the 390 pt iPhone 16e and **17.87 pt** on the 440 pt iPhone 17 Pro Max, toe to top before the ink outline.

The dark stripe next to the former flight dial is the airborne baton's hard ground shadow. The renderer projects its shadow by (+0.55z, −0.30z) onto the ground. At tick 22 of the engine 0.5.0 practice throw, its centre in the original 390 × 844 framing is (317.44, 684.96) pt. A raster regression removes only the baton and measures the changed foreground pixels around that projection. The shadow stays, the dial and plan controls disappear during flight, and the pitch extends to the bottom.

## Review pictures

Each image is a real iOS 26.2 simulator capture of the app with a synthetic match. The five original 640 × 384 landscape renderer PNGs remain byte-identical. The portrait suite covers the HUD and cards on both screen sizes.

| Screen | Small iPhone | Large iPhone |
| --- | --- | --- |
| Home | [16e](review/iphone-16e-home.png) | [17 Pro Max](review/iphone-17-pro-max-home.png) |
| Options | [16e](review/iphone-16e-options.png) | [17 Pro Max](review/iphone-17-pro-max-options.png) |
| Handoff | [16e](review/iphone-16e-handoff.png) | [17 Pro Max](review/iphone-17-pro-max-handoff.png) |
| Aim | [16e](review/iphone-16e-aim.png) | [17 Pro Max](review/iphone-17-pro-max-aim.png) |
| Side view | [16e](review/iphone-16e-plan.png) | [17 Pro Max](review/iphone-17-pro-max-plan.png) |
| ARC held | [16e](review/iphone-16e-arc.png) | [17 Pro Max](review/iphone-17-pro-max-arc.png) |
| TILT held | [16e](review/iphone-16e-tilt.png) | [17 Pro Max](review/iphone-17-pro-max-tilt.png) |
| Linear, right, aim | [16e](review/iphone-16e-linear-right-aim.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-aim.png) |
| Linear, right, ARC held | [16e](review/iphone-16e-linear-right-arc.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-arc.png) |
| Linear, right, TILT held | [16e](review/iphone-16e-linear-right-tilt.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-tilt.png) |
| Linear, left, aim | [16e](review/iphone-16e-linear-left-aim.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left-aim.png) |
| Linear, left, ARC held | [16e](review/iphone-16e-linear-left-arc.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left-arc.png) |
| Linear, left, TILT held | [16e](review/iphone-16e-linear-left-tilt.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left-tilt.png) |
| Nudge, clock, in a match | [16e](review/iphone-16e-clock-nudge.png) | [17 Pro Max](review/iphone-17-pro-max-clock-nudge.png) |
| Nudge, linear right, in a match | [16e](review/iphone-16e-linear-right-nudge.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-nudge.png) |
| Nudge, linear left, in a match | [16e](review/iphone-16e-linear-left-nudge.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left-nudge.png) |
| Flight | [16e](review/iphone-16e-flight.png) | [17 Pro Max](review/iphone-17-pro-max-flight.png) |
| Verdict | [16e](review/iphone-16e-verdict.png) | [17 Pro Max](review/iphone-17-pro-max-verdict.png) |
| Raise | [16e](review/iphone-16e-raise.png) | [17 Pro Max](review/iphone-17-pro-max-raise.png) |
| Raise, two to go | [16e](review/iphone-16e-raisemany.png) | [17 Pro Max](review/iphone-17-pro-max-raisemany.png) |
| Raising automatically | [16e](review/iphone-16e-raiseauto.png) | [17 Pro Max](review/iphone-17-pro-max-raiseauto.png) |
| AUTO ALL | [16e](review/iphone-16e-raiserest.png) | [17 Pro Max](review/iphone-17-pro-max-raiserest.png) |
| Raise, kubb dragged past half way | [16e](review/iphone-16e-raisedrag.png) | [17 Pro Max](review/iphone-17-pro-max-raisedrag.png) |
| Raise, refused end tapped | [16e](review/iphone-16e-raiserefused.png) | [17 Pro Max](review/iphone-17-pro-max-raiserefused.png) |
| Coach, clock, learning | [16e](review/iphone-16e-coach.png) | [17 Pro Max](review/iphone-17-pro-max-coach.png) |
| Coach, clock, after a SLOW flick | [16e](review/iphone-16e-coach-slow.png) | [17 Pro Max](review/iphone-17-pro-max-coach-slow.png) |
| Coach, linear right | [16e](review/iphone-16e-linear-right-coach.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-coach.png) |
| Coach, linear left | [16e](review/iphone-16e-linear-left-coach.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left-coach.png) |
| Coach, linear right, after a SLOW flick | [16e](review/iphone-16e-linear-right-coach-slow.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-coach-slow.png) |
| Punishment | [16e](review/iphone-16e-punish.png) | [17 Pro Max](review/iphone-17-pro-max-punish.png) |
| Computer | [16e](review/iphone-16e-computer.png) | [17 Pro Max](review/iphone-17-pro-max-computer.png) |
| Menu | [16e](review/iphone-16e-menu.png) | [17 Pro Max](review/iphone-17-pro-max-menu.png) |
| Winner | [16e](review/iphone-16e-winner.png) | [17 Pro Max](review/iphone-17-pro-max-winner.png) |
| Sheet | [16e](review/iphone-16e-sheet.png) | [17 Pro Max](review/iphone-17-pro-max-sheet.png) |

### Drawing details

- Quartz rasterizes the ink edges and dashes. Grass blades use short batches of filled, hard-edged shapes and sand/snow specks have square ends. Their positions still use the web seed. The playfield and dial use at most two backing pixels per point for the moving-frame budget. SwiftUI controls and text use display resolution.
- Batons have 24-sided circular cross-sections with a projected cap, highlight and bands. The web constructs analytic ellipses. End-grain rings and pith, crown interiors, cheese spots and some bevels use simpler paths. Small differences appear on close wood and around silhouettes. These are presentation approximations. Positions in moving pieces use the recording's 1e−5 quantization; the session camera uses its full-precision playback.
- The provisional dial uses the web's angle convention, zones, prompt, power and release targets and last-throw marks. It has a simpler face, hand, ticks and knob. The native burst uses its own text metrics, short chip animation and crown path. Labels use the system face, display words use Londrina. The native screen stacks its verdict under the heading. These UI differences are intentional.

## The meter

The throw's meter is the player's choice, kept on the device: MENU (practice) or the match menus, Meter, Clock or Linear (`pitch.meter`, clock by default), and Side, Left or Right (`pitch.meterSide`, right by default) for the linear meter. `KubbRenderer/ThrowMeter.swift` holds the geometry and which touches each meter claims, and both feed the same `PointerDial`: the clock its finger's angle about the centre, the linear meter `meterPoint(arm:)` for the knob's height. The engine and its `pointer` tune do not know which meter is on the screen.

- **The clock** keeps its place and size: radius `min(0.22 W, 0.12 H, 114)` pt, centre 42 pt above the bottom safe area. Its colours are the app's own (system red and grey), not the web's palette.
- **The linear meter** (`LinearMeterHUD.swift`) is a port of the web's `src/render/linear.js`, its tune number for number: two columns in one ink frame with a hard shadow, the lane (targets) toward the screen's centre and the channel (the wood knob) toward the edge, the prompt a tab at the knob's home. The knob's home is the clock's 6, the middle of the track; the backswing runs down, toward the player, and the forward swing up, on one scale. The box is 0.2 of the width (64 to 96 pt) and 0.47 of the height, at least 390 pt and at most 450 pt, the web's, and stands 7 pt off the edge and the bottom safe area, under the minimap. A screen that cannot give it 320 pt of track (a phone on its side, a short phone) shows the clock. Its words: DRAW BACK, FLING!, BACK TO MIDDLE. The plan's sliders and buttons are padded clear of it through the `\.meterRoom` environment value (`MeterRoom`: the edge and the width the meter takes). With the meter on the left the plan's two columns swap, TILT or SPIN over WALK beside the meter and ARC over SIDE VIEW at the far edge, so the shorter column sits under the prompt tab and the tall ARC never covers it. The sliders are SwiftUI views over the board, so a press on one never reaches `BoardView` (never a throw), and a press on the meter never reaches a slider.
- **Red** starts at `max(overDeg, powerHi)` on both meters: the engine's overpower cost counts from the power target's top (core/throwplan), so a long throw's target past 11 o'clock is never drawn as overpowered.
- **The last throw** (the engine's `lastBack` and `lastStop`) is a faded ghost of the knob where it was, 60% of its size at 45% opacity, so it reads as "where your last throw went" and never as a target. The web draws the same.

### Touches

In `BoardView.touchesBegan`, in this order. Anything a step does not claim falls to the next.

1. Raise and punishment phases: the raise is a touch on the kubb (a tap, a tap by an end's number, or a drag that tips it; docs/MATCH.md), punishment as before.
2. `MeterLayout.first`: the clock's ring, within 1.25 radii of its centre (the throw at once, as always); the linear knob, 46 pt up or down from home, across the body and 6 pt either side of it (the throw at once, grabbed relatively: the press point is home); the rest of the linear body and its shadow (swallowed, never a throw).
3. Walking, the thrower (44 pt), as before.
4. `MeterLayout.after`: beside the clock's ring, 1.25 to 2.1 radii; the linear meter's throw zone, y ≥ 0.6 of the height. Beside the ring where a tap could not aim (`tapCouldAim`, the tap rule `target(tap: true)` uses), the press is the throw at once. Otherwise the press waits: one that moves more than 10 pt (`MeterLayout.tapSlop`) is the throw, a stroke from the knob's home for the zone, and one that does not is a tap on the pitch.
5. The aim (`AimDrag`): a tap puts the circle there, a drag anywhere else moves it from where it is. A tap that waited in step 4 aims the same way (`tapAim`).

A stroke from the zone or beside the ring feeds the engine the press on one frame and the finger on the next, so a quick first move still arms the swing. A finger beside the ring is drawn as a spoke from the knob to it.

### The nudge

When a player is stuck on their own throw, a ghost of the knob makes one good throw on the meter with a ghost fingertip where the finger goes: a slow draw back (0.9 s), a beat, a fast flick (0.25 s), then a second's rest, until the next press. `ThrowNudge.swift` (pure, the web's `src/game/nudge.js` numbers) says when and where on the timeline; `NudgeHUD.swift` draws it. It counts only eligible time (the player's own aim in practice or a match, no finger down, the side view closed and no slider held, the dial idle; a held slider counts as input) on the wall clock, and the display link sleeps until it is due. A device with fewer than 3 throws (`pitch.throwsMade`, capped at 9) is nudged after 8 s in the aim without a press on the meter; any device after two presses on the meter in a row that made no throw (0.8 s after the last); a learned one after 30 s with no input. A tap in the throw zone or beside the ring keeps it away 1.5 s. The fingertip is beside the ring (1.6 radii) on the clock in practice; in a match the plan's sliders sit beside the ring, so it presses the knob instead. On the linear meter it is in the throw zone on the meter's inner side, between the two slider columns. While the engine says WIND BACK the plate follows the ghost. Reduce Motion shows a still picture at the back with the strokes' arrows. Drawing only: the ghost is never fed to the engine.

### The coach line

While a device is learning (fewer than 3 throws, `pitch.throwsMade`) a few words sit just over the meter's prompt and follow the stroke: PULL BACK TO THE ORANGE MARK at rest, NO RUSH GOING BACK while drawing back short of the power band, NOW FLICK FAST AND STOP ON THE BLUE MARK from the band through the flick. After a throw of this player's own that the engine called SLOW, the next throw is coached on any device, led by SLOW FLICK. FLICK FASTER. in an ink box. `KubbRenderer/Coach.swift` is the web's `src/game/coach.js` (its tests ported in `CoachTests`); `CoachHUD.swift` draws it as the web's hud.js `showCoach`: over the clock's plate, centred, or from the linear meter's inner edge over its tab; 13 pt heavy, upper case, balanced lines, at most 280 pt wide and short of any plan column level with it (up to 76 pt above its foot, read from the columns' frames). It shows only in the player's own aim with no finger down, never with the nudge's ghost, and takes no touches. The face is the system's heavy font, not the web's CSS face. Drawing only: never fed to the engine, sent or recorded.

`python3 tools/meter-snapshots.py <simulator-app> --device <name or udid>` captures every meter, side, mark and nudge frame under `build/meter-shots/` (`PITCH_REVIEW` modes `wind`, `beside`, `marks` and `nudge`; `NUDGE_AT` freezes the nudge at a time, `NUDGE_STILL` shows the still picture, `THROWS_MADE` sets `pitch.throwsMade` for the coach, 9 by default). The review tools launch with `-pitch.throwsMade 9` so the coach stays away, and 0 for the coach shots.

| Meter | Small iPhone | Large iPhone |
| --- | --- | --- |
| Linear, right | [16e](review/iphone-16e-linear-right.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right.png) |
| Linear, left | [16e](review/iphone-16e-linear-left.png) | [17 Pro Max](review/iphone-17-pro-max-linear-left.png) |
| Last throw, linear | [16e](review/iphone-16e-linear-marks.png) | [17 Pro Max](review/iphone-17-pro-max-linear-marks.png) |
| Last throw, clock | [16e](review/iphone-16e-clock-marks.png) | [17 Pro Max](review/iphone-17-pro-max-clock-marks.png) |
| Beside the ring | [16e](review/iphone-16e-clock-beside.png) | [17 Pro Max](review/iphone-17-pro-max-clock-beside.png) |
| Nudge, clock | [16e](review/iphone-16e-nudge-clock.png) | [17 Pro Max](review/iphone-17-pro-max-nudge-clock.png) |
| Nudge, linear | [16e](review/iphone-16e-nudge-linear.png) | [17 Pro Max](review/iphone-17-pro-max-nudge-linear.png) |
| Coach, clock, winding in the band | [16e](review/iphone-16e-clock-coach-wind.png) | [17 Pro Max](review/iphone-17-pro-max-clock-coach-wind.png) |
| Coach, linear right, winding in the band | [16e](review/iphone-16e-linear-right-coach-wind.png) | [17 Pro Max](review/iphone-17-pro-max-linear-right-coach-wind.png) |

## Prior practice frame measurements

These Step D measurements used the original centred framing on the iPhone 17 simulator, iOS 26.2. A 120 Hz frame allows 8.33 ms. The Kit test advances a real dial throw in 1/120 s steps and times each step from the session call through interpolation, ground and piece rasterization and bitmap flush. The bitmap is 390 × 844 points at 2×. Release-time physics is measured separately. Timings are milliseconds.

| Measurement | Samples | Median | p95 | p99 | Max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Session call, decode and interpolate | 319 | 0.27 | 0.70 | 1.47 | 4.74 |
| Same update plus synchronous world raster | 319 | 2.14 | 4.43 | 6.17 | 9.16 |
| Running app, update and UIKit draw including HUD | 145 | 0.81 | 0.99 | 1.48 | 1.85 |
| Running app, display callback interval | 144 | 16.67 | 16.69 | 16.77 | 33.26 |

Release took 12.07 ms in the full suite. The Kit's slowest frame crossed the 8.33 ms budget. The running app requested the screen's maximum refresh and the simulator delivered approximately 60 Hz. Its draw timings measure the app's work before compositing. Physical ProMotion cadence and touch feel still need device testing.

## Reproduce locally

1. Run the usual Kit tests. Five fixed, bundled scenes cover fresh grass/classic, sand/USA, snow/Minnesota, mid-match/Wisconsin and plan/Sweden. Each 16 × 16 tile must have mean absolute RGB channel error below 4/255 against its native PNG. This permits antialiasing variation while protecting small kubbs. The projection test checks inversion and near-plane rejection on two aspect ratios.
2. The scripted practice test drives a second independent engine with the same input. It samples its camera and bodies throughout playback and compares SHA-256 of the canonical recording and settled view from each engine. The engine reserves its built-in match hash for match snapshots. The match golden suite still checks all 437 actions.
3. Run `node tools/render-review.mjs ../kubb.thingelstad.xyz` from the iOS worktree with the web dependencies and Chrome available. It rewrites the five synthetic JSON inputs here and generates web PNGs under `build/review/`. Playwright intercepts a loopback origin and serves renderer modules from the read-only web checkout. To export corresponding native PNGs, run `PITCH_RENDER_OUT="$PWD/build/review" swift test --package-path ThrowingWoodKit --filter RendererTests.snapshot`. Inspect the pictures before replacing any checked-in baseline. Join native first and web second horizontally for the comparison.
4. For simulator stills, launch the installed simulator build with `SIMCTL_CHILD_PITCH_REVIEW=aim`, `flight` or `rest` and `xcrun simctl launch --terminate-running-process <simulator> com.throwingwood.app`. Capture with `xcrun simctl io <simulator> screenshot <file.png>`. These modes snap to the next kubb and freeze the ordinary renderer at a reproducible tick. For display timings use `timing` and capture stdout. This mode plays the scripted release on the live display link and writes a single local timing summary. The review harness compiles only for Simulator.
5. For the frame-budget test use the Kit's simulator command with `-configuration Release ENABLE_TESTABILITY=YES -parallel-testing-enabled NO`. Local room conformance and cross-play commands are in [ROOMS-CLIENT.md](ROOMS-CLIENT.md).


For the solo snapshots, build the simulator app with `xcodebuild -project ThrowingWood.xcodeproj -scheme ThrowingWood -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build`. Run `python3 tools/solo-snapshots.py build/dd/Build/Products/Debug-iphonesimulator/ThrowingWood.app`. The script waits for each scene, captures to `build/solo-snapshots/` and checks every 24-point tile against the corresponding review PNG (mean RGB error below 4/255). The comparison masks the simulator-composited home indicator and Pro Max camera cutout. Use `--capture-only` to inspect a proposed new set before copying it. See [the session contract](MATCH.md) for checkpoint provenance.
