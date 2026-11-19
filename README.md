# Throwing Wood for iPhone

Kubb: Throwing Wood for iPhone. Kubb is the Swedish lawn game of throwing
wooden batons at wooden blocks. Throwing Wood began on the Playdate and plays
in a browser at [throwingwood.com](https://throwingwood.com); this is the
iPhone version, which plays on an iPad too: the same game on a bigger screen.

## What's here

Choose **Play online**, **Practice** or **Play the computer**. In practice, pick a surface and tap
a kubb, or drag anywhere to move the circle onto it. Wind back on the left of the dial, flick through six and
lift inside the blue release range. The solo match adds the full turn order,
plan and stance controls, raising, punishment placement and the computer's throws.
At the end, open the Planet Kubb Notation score sheet or start a rematch.
An interrupted solo match resumes on this device. Online, share a pitch link or join
by link or code. Pick a team or watch from the same lobby as friends playing on the web.

The dial ticks as your arm crosses a target band. Wood knocks on impact and
the king rings when it falls. Sound follows the silent switch and mixes with
other audio. Sound and haptics have independent switches in the match menu
and the practice surface menu. Both start on. [Sound and haptics](docs/FEEL.md).

[Online pitches](docs/ONLINE.md) · [How the match works](docs/MATCH.md) · [iPhone and iPad review pictures](docs/RENDER.md)

- `ThrowingWoodKit/` is a Swift package. `KubbEngine` runs the game engine,
  a tagged release of [kubb-engine](https://github.com/jthingelstad/kubb-engine)
  (the same Lua the Playdate and web versions run), in Lua 5.4, with musl's
  math library compiled in so every result matches the web's WebAssembly
  engine to the last bit. Its tests play the engine's golden matches and
  check every hash against the engine's own corpus.
- `KubbRenderer` draws the pitch with Core Graphics and plays the engine’s recordings.
  [Renderer contract, frame timings and review pictures](docs/RENDER.md).
- `KubbRooms` in that package is the Foundation WebSocket client and native
  pitch controller. Its contract and local cross-play checks are in
  [docs/ROOMS-CLIENT.md](docs/ROOMS-CLIENT.md).
- `ThrowingWood/` is the SwiftUI app (iOS 26, iPhone and iPad).
- `scripts/` vendors the engine and the C sources, checks the C never calls
  Apple's libm, stamps the version, and uploads to TestFlight.

## The engine

The release the app runs is `TAG` in `scripts/vendor-engine.sh`. To move to
another, change it, run `scripts/vendor-engine.sh sync` (it reads the
kubb-engine checkout beside this one, at that tag), then run the tests.

## Building

Xcode 26. Open `ThrowingWood.xcodeproj`, or run the tests headless:

```sh
swift test --package-path ThrowingWoodKit
```

To sign a device build, put `DEVELOPMENT_TEAM = <team id>` in
`Config/Signing.local.xcconfig` (ignored by git).

## Licenses

The app is MIT (`LICENSE`). Lua is MIT (`ThrowingWoodKit/Sources/CLua/LICENSE`)
and musl is MIT (`ThrowingWoodKit/Sources/CMusl/COPYRIGHT`); each has a
`NOTICE.md` saying what was taken and how it was changed.

The display face is Londrina Solid Black, distributed under the [SIL Open Font License](ThrowingWood/Fonts/OFL-LondrinaSolid.txt).
