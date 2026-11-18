# The iPhone pitch

Practice opens on grass. The surface picker changes the ground in the current session. Drag the circle to aim and lift to snap to a kubb. Press the dial near six, wind back on the left, flick through six and lift on the right. Bringing the arm back slowly lets it down. The blue range is the release angle. The orange range is the backswing. Practice takes batons and the engine's `pointer` tune.

## Picture and clock

`KubbRenderer.PitchRenderer.draw(in:size:camera:scene:)` takes a top-left-origin Core Graphics context. Size is in points. The renderer saves and restores the caller's graphics state. Its only persistent geometry is the immutable, seeded ground texture and the six default stakes. A render never calls Lua.

- The camera is the engine's eye, orthonormal basis, focal length and principal point. In eye space, depth clips at 0.05 m. Projection divides right and up by depth, inverts screen y and applies the principal point. Landscape centres the 400 × 240 reference frame at `min(width/400, height/240)`. The portrait fit is described below. Sky and ground extend to every edge. The same transform casts drag points back onto z = 0.
- The scene accepts surface, set, posed items, advantage line, target, arc, thrower, raise footprints and punishment keep-out circles. The local z axis runs along each piece. Kubb, king, baton and stake extents, six stake positions, paint and team bands, light direction, hard shadows and near-plane clipping follow the web renderer. Nearby overlapping boxes use separating planes to correct depth order. The arc stops 0.45 m short of its target so the kubb stays visible.
- `PitchSession` owns the main-actor engine for practice and solo. A target drag calls `setTarget`. A display tick consumes at most one pointer frame. `ThrowInput` isolates input sampling, lift and cancellation. The pointer implementation uses forward degrees from six, preserving touch boundaries and accumulating elapsed time between samples. Its stationary feed matches the web's stop detection. The display link sleeps on a still, unattended pitch and stops outside the active scene.
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
| Plan | [16e](review/iphone-16e-plan.png) | [17 Pro Max](review/iphone-17-pro-max-plan.png) |
| Flight | [16e](review/iphone-16e-flight.png) | [17 Pro Max](review/iphone-17-pro-max-flight.png) |
| Verdict | [16e](review/iphone-16e-verdict.png) | [17 Pro Max](review/iphone-17-pro-max-verdict.png) |
| Raise | [16e](review/iphone-16e-raise.png) | [17 Pro Max](review/iphone-17-pro-max-raise.png) |
| Punishment | [16e](review/iphone-16e-punish.png) | [17 Pro Max](review/iphone-17-pro-max-punish.png) |
| Computer | [16e](review/iphone-16e-computer.png) | [17 Pro Max](review/iphone-17-pro-max-computer.png) |
| Menu | [16e](review/iphone-16e-menu.png) | [17 Pro Max](review/iphone-17-pro-max-menu.png) |
| Winner | [16e](review/iphone-16e-winner.png) | [17 Pro Max](review/iphone-17-pro-max-winner.png) |
| Sheet | [16e](review/iphone-16e-sheet.png) | [17 Pro Max](review/iphone-17-pro-max-sheet.png) |

### Drawing details

- Quartz rasterizes the ink edges and dashes. Grass blades use short batches of filled, hard-edged shapes and sand/snow specks have square ends. Their positions still use the web seed. The playfield and dial use at most two backing pixels per point for the moving-frame budget. SwiftUI controls and text use display resolution.
- Batons have 24-sided circular cross-sections with a projected cap, highlight and bands. The web constructs analytic ellipses. End-grain rings and pith, crown interiors, cheese spots and some bevels use simpler paths. Small differences appear on close wood and around silhouettes. These are presentation approximations. Positions in moving pieces use the recording's 1e−5 quantization; the session camera uses its full-precision playback.
- The provisional dial uses the web's angle convention, zones, prompt, power and release targets and last-throw dots. It has a simpler face, hand, ticks and knob. The native burst uses its own text metrics, short chip animation and crown path. Labels use the system face, display words use Londrina. The native screen stacks its verdict under the heading. These UI differences are intentional.

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
