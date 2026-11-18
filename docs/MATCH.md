# The offline solo match

The home screen opens practice or a match against the computer. PLAY THE COMPUTER resumes an unfinished solo game or opens its options. START creates a new match. REMATCH returns to the options. The match menu pauses the clock and provides level, score sheet, home and resignation.

## Session contract

- `PitchSession` owns one main-actor Lua state. The app gets the six selectors from `room.constants`. It uses LEVELS for level and MATCH_OPTIONS and OPTION_DEFAULTS for the other five. Club is the web solo default. The host supplies the local Gregorian start date, a random 31-bit seed and a name for each side. Side A plays first and side B is the computer.
- On `new` and `restore`, set control to sides A and CPU true. Adopt the session's `view`. A throw need supplies the thrower, projectile, position in the turn and standing counts. A human handoff pauses until THROW. Lua handles the computer's own raises and handovers. A CPU throw advances through ordinary `frame({dt})` calls including its think and windup.
- While aiming, the pointer dial supplies arm angles. A tap or drag places the target. Plan toggles the engine's overhead camera. ARC and TILT or SPIN use `stepArc` and `stepSide`. Drag the stance mark directly or enable WALK and drag to walk. After an aim command, read the session's dial so a stationary player sees the updated release ranges before winding back. The session constrains all movement. The minimap tracks the thrower's frame on either side.
- A release has already advanced the match. Save the raw snapshot, play the recording and keep the releasing side's HUD until rest. The controller gets camera and speed from `showAt` and interpolates the recording's poses. SKIP enters the settled view. Rulings, bursts and verdict words come from the engine.
- For `need.kind == raise`, draw the lying kubb and the session's numbered end footprints. Match the selected end's `which` to the one-based index in `choices`. An automatic raise omits the index. For punishment the touch ray meets the ground, the cursor stays within the supplied bounds, and `checkPunish` decides whether PLACE IT is available. Both use `apply` and load the resulting view.
- An over need shows the winner even if a resignation retained a previous handoff in the session. The end card takes its winner, reason and statistics from `need`. The sheet displays `sheet().shown` by default. Show positions, COPY and SAVE use the complete Planet Kubb Notation text returned by the session. SAVE uses the session's filename and the iOS file picker.
- The app writes the opaque UTF-8 snapshot atomically in Application Support at match start and after each committed action. A cold launch restores the session and reestablishes control. During flight the committed throw is already in that file. Cold restoration opens at the next decision. An ordinary background/foreground cycle preserves the in-memory camera and pauses display time. Home keeps an unfinished save for the next PLAY THE COMPUTER. Home after a win clears the finished save.

## Throw reports

Practice and solo both offer Report a Throw in the menu. The player can tap several
pieces on the overhead pitch or choose their names when pieces overlap. The card
freezes the last throw’s rest positions, including pieces collected at the end of a
turn. Send includes the selected IDs and poses, the written account and the replay
state. A failed send keeps the draft open. Resuming a solo save starts its report
history at that checkpoint.

## Differences from browser solo

Both clients use the same pointer tune, options, computer, rules, raises, punishments and notation. Native controls use a paused match menu, native option pickers, a compact turn rail with batons left and both sides' standing counts, numbered end labels and a smaller schematic minimap. The winner shows hits as a fraction. The sheet exports through Files. The touch name field counts extended grapheme clusters. The browser counts UTF-16 code units.

The app hides the dial in flight, keeps the pitch full height and applies the target pan immediately. The current browser source still draws a promptless dial in playback and eases its aim pan. Quartz wood, ink, chips and text metrics differ slightly from Canvas. Saving and resuming a private match on the phone is deliberate. The sound and haptic cues share the playback clock. See [Pitch feedback](FEEL.md). Browser links to rules and the notation guide, full how-to overlays, keyboard/mouse shortcuts and web release controls are outside the native screen. Simulator timing, physical touch comfort and VoiceOver pitch manipulation still need device evaluation.

## Verification

`SoloTests` plays an uncapped, seeded computer match on both sides through the production controller and a separate engine. It compares the hash at every release and the finished sheet. It also restores an atomic mid-flight save, checks the next release, tests projected legal end selection and punishment refusal/placement, and exercises the actual option, plan and stance calls.

The five raw simulator checkpoints in `ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/solo/` come only from a synthetic match. Regenerate them with `node tools/solo-fixtures.mjs <web-checkout>` on engine 0.4.0. A second engine plans the scripted human's throws. Every checkpoint is the original match's untouched snapshot. The fixtures are test resources. Simulator review reads one copied into the app's temporary directory. The installed device app only reads its own local save.

See [the review pictures and snapshot command](RENDER.md).
