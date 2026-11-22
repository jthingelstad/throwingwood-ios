import KubbRenderer
import SwiftUI
import UniformTypeIdentifiers

/// Home: the title plate over the four buttons, or, where the screen is too short for
/// that (an iPhone on its side, a short window), the plate beside them.
struct HomeCard: View {
  let model: GameModel
  var body: some View {
    ViewThatFits(in: .vertical) {
      VStack {
        title
        Spacer()
        buttons
      }.padding(.top, 22).padding(.bottom, 44)
      HStack(spacing: 40) {
        title
        buttons
      }.frame(maxHeight: .infinity).padding(.vertical, 12)
    }
  }

  private var title: some View {
    VStack(spacing: -5) {
      Text("KUBB").font(displayFont(82))
      Text("THROWING WOOD").font(displayFont(30))
    }.padding(.horizontal, 20).modifier(Plate())
  }

  private var buttons: some View {
    VStack(spacing: 12) {
      Button {
        model.solo()
      } label: {
        Text("PLAY THE COMPUTER").frame(maxWidth: .infinity)
      }
      .buttonStyle(WoodButton(accent: true))
      Button {
        model.screen = .onlineEntry
      } label: {
        Text("PLAY ONLINE").frame(maxWidth: .infinity)
      }
      .buttonStyle(WoodButton())
      Button {
        model.openPractice()
      } label: {
        Text("PRACTICE").frame(maxWidth: .infinity)
      }
      .buttonStyle(WoodButton())
      Button {
        model.openSettings()
      } label: {
        Text("SETTINGS").frame(maxWidth: .infinity)
      }
      .buttonStyle(WoodButton())
    }.frame(maxWidth: 280)
  }
}

/// Play the computer (the 1.0 design, direction A, scene first): the name row, Scene as
/// seven picture tiles drawn by the app's own renderer, Surface under it only where the
/// scene leaves one (Black & White), then Computer (Kid first), Opening, Raising and Wind
/// as segmented bars, the rows the engine's card for the chosen scene
/// (`SoloOptions.cardRows`, `pitch.optionRows`); no Kubbs row, the scene decides the set.
/// HOME quiet at the left, START go at the right.
struct MatchOptionsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    CardScreen(width: 440) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Play the computer").cardTitle()
        // the player's name is the device's (Settings); this card's rows are the
        // game's, its Computer level the match's `computer` option
        PlayerLine(model: model)
        Rule()
        ForEach(model.pitch?.options.cardRows(model.selections) ?? []) { row in
          if row.id == "scene", let pitch = model.pitch {
            Text(row.label).labelStyle().accessibilityHidden(true)
            SceneTiles(scenery: pitch.scene.scenery, row: row, value: binding(row))
          } else {
            FormRow(row.label) { full in
              Segmented(label: row.label, choices: row.choices.map { ($0[0], $0[1]) }, value: binding(row), full: full)
            }
          }
        }
      }
    } buttons: {
      ButtonRow {
        QuietButton("HOME", action: model.home)
      } trailing: {
        Button(action: model.start) { Text("START").frame(minWidth: 110) }
          .buttonStyle(WoodButton(accent: true))
      }
    }
  }
  private func binding(_ row: MatchOption) -> Binding<String> {
    Binding(
      get: { model.selections[row.id] ?? row.choices.first?[0] ?? "" },
      set: { v in
        guard let options = model.pitch?.options else { return }
        // a new scene brings its own ground and set (the engine's card's defaults)
        model.selections = row.id == "scene" ? options.choosing(scene: v, model.selections) : {
          var s = model.selections
          s[row.id] = v
          return options.starting(s)
        }()
      })
  }
}

/// The Scene row's picture tiles (the design's `.tiles`, the web's SYSTEM.md "Scene
/// tiles"), one per scene in the engine's row: each scene's postcard of the pitch as the
/// app's own renderer draws it (`PitchScene.postcard`'s low camera, so its sky and scenery
/// show), on the scene's own ground and set, its name under it in the buttons' capitals
/// (Londrina Solid 16: the web's Inter 14 does not fit TOURNAMENT on a third of the 16e's
/// card), two lines where it needs them (BLACK & WHITE). They wrap, 8 pt apart, three a row on a
/// screen under 600 pt wide (the seventh centred on a row of its own) and four a row from
/// 600 (four and three, centred); at the accessibility text sizes each tile is a row, its
/// picture beside its name. The chosen tile's name inverted, ink with paper type, and its
/// plate raised by the hard shadow, so the choice is told by fill and shape, not colour.
/// Every tile at least 48 pt tall. VoiceOver reads the group as Scene and each tile as the
/// bar's parts are ("Camping, selected, 3 of 7"), in the row's order. The solo card, the
/// practice menu and the lobby (the host's).
struct SceneTiles: View {
  /// The pieces the postcards show (the pitch behind the card).
  let scenery: PitchScene
  let row: MatchOption
  @Binding var value: String
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    let names = row.choices.map { (id: $0[0], name: $0[1]) }
    Group {
      if type.isAccessibilitySize {
        VStack(spacing: 8) {
          ForEach(Array(names.enumerated()), id: \.offset) { i, scene in tile(i, scene, count: names.count, wide: true) }
        }
      } else {
        CentredRows(columns: screen.size.width >= 600 ? 4 : 3, spacing: 8) {
          ForEach(Array(names.enumerated()), id: \.offset) { i, scene in tile(i, scene, count: names.count, wide: false) }
        }
        // room for the chosen tile's hard shadow
        .padding(.trailing, TW.controlShadow).padding(.bottom, TW.controlShadow)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.label)
  }

  private func tile(_ i: Int, _ scene: (id: String, name: String), count: Int, wide: Bool) -> some View {
    let on = value == scene.id
    let picture = Canvas { ctx, size in
      ctx.withCGContext { cg in
        PitchRenderer.draw(
          in: cg, size: size, camera: PitchScene.postcard, scene: scenery.dressed(scene.id), look: scene.id)
      }
    }
    .aspectRatio(96 / 56, contentMode: .fit)
    // the system's button face (Londrina Solid capitals): TOURNAMENT in Inter 14 needs
    // about 100 pt and a third of the 16e's card gives 93, and nothing goes under 14 pt
    let name = Text(scene.name).font(displayFont(16, relativeTo: .subheadline))
      .textCase(.uppercase).lineLimit(wide ? nil : 2).multilineTextAlignment(wide ? .leading : .center)
      .fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(on ? Color.woodPaper : Color.woodInk)
    return Button {
      value = scene.id
    } label: {
      Group {
        if wide {
          HStack(spacing: 0) {
            picture.frame(width: 96)
            Rectangle().fill(Color.woodInk).frame(width: TW.line)
            name.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: TW.touch, alignment: .leading)
              .frame(maxHeight: .infinity).background(on ? Color.woodInk : Color.woodBaton)
          }
        } else {
          VStack(spacing: 0) {
            picture
            Rectangle().fill(Color.woodInk).frame(height: TW.line)
            name.padding(.horizontal, 1).padding(.vertical, 6)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
              .background(on ? Color.woodInk : Color.woodBaton)
          }
          .frame(minHeight: 48)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
      .background(
        RoundedRectangle(cornerRadius: TW.controlRadius).fill(on ? Color.woodDrop : .clear)
          .offset(x: TW.controlShadow, y: TW.controlShadow))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(scene.name)
    .accessibilityValue(SegmentWords.value(index: i, count: count, selected: on))
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// Rows of `columns` equal tiles, `spacing` apart, a short last row centred (the web's
/// flex-wrap with justify-content: center); each row as tall as its tallest tile.
struct CentredRows: Layout {
  let columns: Int
  let spacing: CGFloat
  private func width(_ proposal: ProposedViewSize) -> CGFloat {
    let w = proposal.width ?? 320
    return max(1, (w - spacing * CGFloat(columns - 1)) / CGFloat(columns))
  }
  private func rows(_ subviews: Subviews, _ w: CGFloat) -> [(range: Range<Int>, height: CGFloat)] {
    stride(from: 0, to: subviews.count, by: columns).map { start in
      let r = start..<min(subviews.count, start + columns)
      let h = r.map { subviews[$0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
      return (r, h)
    }
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = width(proposal)
    let rs = rows(subviews, w)
    let h = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rs.count - 1))
    return CGSize(width: proposal.width ?? w * CGFloat(columns) + spacing * CGFloat(columns - 1), height: h)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let w = width(ProposedViewSize(width: bounds.width, height: nil))
    var y = bounds.minY
    for (range, h) in rows(subviews, w) {
      let rowWidth = CGFloat(range.count) * w + spacing * CGFloat(range.count - 1)
      var x = bounds.minX + (bounds.width - rowWidth) / 2
      for i in range {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: h))
        x += w + spacing
      }
      y += h + spacing
    }
  }
}

private struct NotationFile: FileDocument {
  static let readableContentTypes = [UTType.plainText]
  let text: String
  init(_ text: String) { self.text = text }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
      let contents = String(data: data, encoding: .utf8)
    else { throw CocoaError(.fileReadCorruptFile) }
    text = contents
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

struct SheetCard: View {
  let sheet: ScoreSheet, done: () -> Void
  @State private var positions = false
  @State private var copied = false
  @State private var exporting = false
  @State private var exportError: String?
  var body: some View {
    // an iPad's: the web's .sheet, min(640px, 100%); a phone keeps its whole width
    CardScreen(width: UIDevice.current.userInterfaceIdiom == .pad ? 640 : 760, fill: true) {
     VStack(alignment: .leading, spacing: 12) {
      Text("Score sheet").cardTitle()
      Text("Planet Kubb Notation").labelStyle()
      GeometryReader { box in
        ScrollView(.vertical) {
          // a line longer than the box (the rules, a comment) wraps inside it rather
          // than running past its right edge unseen; COPY and SAVE keep the text as it is
          Text(verbatim: positions ? sheet.text : sheet.shown.joined(separator: "\n"))
            .font(.system(size: 14, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(10)
            // a sheet shorter than its box (an iPad's tall window) starts at the
            // top, as it does where it overflows, not in the box's middle
            .frame(width: box.size.width, alignment: .topLeading)
            .frame(minHeight: box.size.height, alignment: .topLeading)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(skin.isDay ? Color.white : Color.woodPaper).border(Color.woodInk)
      // the switch went: a segmented bar, as every two-way choice is
      FormRow("Show positions") { full in
        Segmented(onOff: "Show positions", value: $positions, full: full)
      }
     }
    } buttons: {
      HStack(spacing: 12) {
        Button(copied ? "COPIED" : "COPY") {
          UIPasteboard.general.string = sheet.text
          copied = true
        }.buttonStyle(WoodButton())
        Button("SAVE") { exporting = true }.buttonStyle(WoodButton())
        Spacer(minLength: 0)
        Button("BACK", action: done).buttonStyle(WoodButton(accent: true))
      }
    }
      .fileExporter(
        isPresented: $exporting, document: NotationFile(sheet.text),
        contentType: .plainText, defaultFilename: sheet.name
      ) { result in
        if case .failure(let error) = result { exportError = error.localizedDescription }
      }
      .alert(
        "Save failed",
        isPresented: Binding(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } })
      ) {
        Button("Close") {}
      } message: {
        Text(exportError ?? "")
      }
  }
}

/// The match menu (the 1.0 design): a two by two grid of plain buttons (Settings,
/// Score sheet, How to throw, Feedback), this match's Raising, BACK TO THE MATCH as go,
/// RESIGN and HOME quiet, the version at the foot.
struct MatchMenu: View {
  @Bindable var model: GameModel
  let pitch: PitchSession
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    let footInRows = FootInRows.at(type, wide: screen.wide)
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: TW.rowGap) {
        Text("Match menu").cardTitle()
        MenuGrid(model: model)
        // this match's own (the menu's Raising); the device's are in Settings
        RaisingSetting(model: model)
        if footInRows { VersionFooter(label: pitch.versionLabel) }
      }
    } buttons: {
      VStack(alignment: .leading, spacing: 8) {
        if screen.wide {
          // on its side a phone is about 390 pt tall: RESIGN and HOME quiet beside the go,
          // last in its row, so the rows above are shown whole
          HStack(spacing: 12) {
            resign
            QuietButton("HOME", action: model.home)
            back.frame(maxWidth: 220)
          }
        } else {
          back
          HStack {
            resign
            Spacer()
            QuietButton("HOME", action: model.home)
          }
        }
        if !footInRows { VersionFooter(label: pitch.versionLabel) }
      }
    }
  }

  private var back: some View {
    Button {
      model.screen = .match
    } label: {
      Text("BACK TO THE MATCH").lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
    }.buttonStyle(WoodButton(accent: true))
  }

  private var resign: some View {
    QuietButton(pitch.need?.resignPending == nil ? "RESIGN" : "RESIGNING…") {
      model.perform {
        try pitch.resign()
        model.screen = .match
      }
    }.disabled(pitch.need?.resignPending != nil)
  }
}

/// The menus' two by two grid of plain buttons: SETTINGS, SCORE SHEET, HOW TO THROW and
/// FEEDBACK (the 1.0 design). At the largest text sizes, one under another.
struct MenuGrid: View {
  let model: GameModel
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    let columns = Array(
      repeating: GridItem(.flexible(), spacing: 12), count: type >= .accessibility3 ? 1 : 2)
    LazyVGrid(columns: columns, spacing: 12) {
      SettingsButton(model: model)
      Button(action: model.showSheet) { Text("SCORE SHEET").frame(maxWidth: .infinity) }
      Button(action: model.openHowTo) { Text("HOW TO THROW").frame(maxWidth: .infinity) }
      ReportButton(model: model, title: "FEEDBACK")
    }
    .buttonStyle(WoodButton())
    .lineLimit(1).minimumScaleFactor(0.7)
  }
}

/// The practice pitch's menu (the web's menu on the practice pitch, its words): SETTINGS,
/// HOW TO THROW and FEEDBACK as the menus' plain buttons, then the practice's own Scene
/// (the seven picture tiles, as on the solo card and the web's MENU) and Surface only
/// where the scene leaves one (Black & White's three, a segmented bar),
/// BACK TO THE PITCH as go, HOME quiet, the version at the foot. A change of Scene starts
/// a new practice in it, as on the web.
struct PracticeMenu: View {
  @Bindable var model: GameModel
  @Environment(\.dynamicTypeSize) private var type
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    // on a screen on its side, or at the largest text sizes, the version goes with the
    // rows (as the match menu's), so the pinned foot leaves the rows their room
    let footInRows = FootInRows.at(type, wide: screen.wide)
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: TW.rowGap) {
        Text("Menu").cardTitle()
        // three across on a screen on its side, so the Scene tiles come into view
        // one under another at the largest text sizes, as the match menu's grid
        let columns = Array(
          repeating: GridItem(.flexible(), spacing: 12), count: type >= .accessibility3 ? 1 : screen.wide ? 3 : 2)
        LazyVGrid(columns: columns, spacing: 12) {
          SettingsButton(model: model)
          Button(action: model.openHowTo) { Text("HOW TO THROW").frame(maxWidth: .infinity) }
          ReportButton(model: model, title: "FEEDBACK")
        }
        .buttonStyle(WoodButton())
        .lineLimit(1).minimumScaleFactor(0.7)
        if let options = model.offline?.options, options.takesScene,
          let rows = options.card(model.practiceScene)?.rows
        {
          ForEach(rows.filter { $0.id == "scene" || $0.id == "surface" }) { row in
            if row.id == "scene", let pitch = model.offline {
              Text(row.label).labelStyle().accessibilityHidden(true)
              SceneTiles(
                scenery: pitch.scene.scenery, row: row,
                value: Binding(get: { model.practiceScene }, set: { model.practiceScene = $0 }))
                .disabled(model.playing)
            } else if row.id == "surface" {
              FormRow(row.label) { full in
                Segmented(
                  label: row.label,
                  choices: row.choices.compactMap { c in Surface(rawValue: c[0]).map { ($0, c[1]) } },
                  value: Binding(get: { model.surface }, set: { model.setPracticeSurface($0) }), full: full)
              }
              .disabled(model.playing)
            }
          }
        }
        if footInRows, let label = model.pitch?.versionLabel { VersionFooter(label: label) }
      }
    } buttons: {
      VStack(alignment: .leading, spacing: 8) {
        let back = Button {
          model.screen = .practice
        } label: {
          Text("BACK TO THE PITCH").lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
        }.buttonStyle(WoodButton(accent: true))
        if screen.wide {
          // on its side: HOME quiet at the left and the go at the right, in one row
          HStack(spacing: 12) {
            QuietButton("HOME", action: model.home)
            Spacer(minLength: 0)
            back.frame(maxWidth: 220)
          }
        } else {
          back
          HStack {
            Spacer()
            QuietButton("HOME", action: model.home)
          }
        }
        if !footInRows, let label = model.pitch?.versionLabel { VersionFooter(label: label) }
      }
    }
  }
}

/// How to throw, from a menu's grid: the words the match menu said before 1.0, for the
/// meter this device shows, on a card of their own. DONE goes back to the menu.
struct HowToCard: View {
  let model: GameModel
  var body: some View {
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: TW.rowGap) {
        Text("How to throw").cardTitle()
        Text(
          model.meter.kind == .linear
            ? "Tap the pitch to aim, or drag anywhere to move the circle. Draw the knob back toward you, fling it up through the middle and let go on the solid mark."
            : "Tap the pitch to aim, or drag anywhere to move the circle. Wind back on the left of the dial, flick through six and lift on the right."
        )
        .font(bodyFont(17)).fixedSize(horizontal: false, vertical: true)
      }
    } buttons: {
      ButtonRow {
        EmptyView()
      } trailing: {
        Button { model.screen = model.howToReturn } label: { Text("DONE").frame(minWidth: 96) }
          .buttonStyle(WoodButton(accent: true))
      }
    }
  }
}

struct MatchScreen: View {
  let model: GameModel, pitch: PitchSession, revision: Int, playing: Bool
  @Environment(\.meterRoom) private var meterRoom
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    if let n = pitch.need {
      ZStack {
        if pitch.handoff != nil {
          // the hand-off: the pitch dimmed under the header (the design's), the card at the foot
          SkinDim().ignoresSafeArea().accessibilityHidden(true)
        }
        // behind the winner card nothing reads through the dim (the build list's
        // accessibility: "the dimmed header behind the winner card"): the screen under
        // it is the pitch alone
        if n.winner == nil || pitch.handoff != nil {
          Group {
            if screen.wide {
              wide(n)
            } else {
              tall(n)
            }
          }
          .accessibilitySortPriority(10)
        }
        // VoiceOver's order: the header, the prompt and distance, the meter, the tray,
        // the minimap (the build list's)
        MeterReader(model: model, pitch: pitch, need: n, playing: playing).accessibilitySortPriority(9)
        if !playing && pitch.canAim && !((n.kind == "raise" || n.kind == "punish") && pitch.acceptsInput) {
          tray.accessibilitySortPriority(8)
        }
        MapReader(model: model, pitch: pitch, need: n).accessibilitySortPriority(7)
        if pitch.freeOn && pitch.handoff == nil && n.winner == nil {
          FreeViewControls(model: model, pitch: pitch, revision: revision)
        }
        if let c = pitch.handoff {
          handoffCard(c).accessibilitySortPriority(20)
        } else if let w = n.winner {
          winner(n, w)
        } else if let banner = model.online?.watchHandoff {
          watchBanner(banner.handoff)
        }
      }
      .accessibilityElement(children: .contain)
    }
  }

  /// A phone held upright: the header across the top, the plan along the bottom.
  private func tall(_ n: MatchNeed) -> some View {
    VStack(spacing: 8) {
      header(n, nameSize: 24)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
          if model.headerBottom != $0 { model.headerBottom = $0 }
        }
      // the minimap hangs under the header's right end: the captions keep left of it, and
      // above what the next throw is aimed at (WideLayout.verdictBand)
      let band = WideLayout.verdictBand(
        size: screen.size, safe: screen.safe, headerBottom: model.headerBottom ?? (screen.safe.top + 66),
        aimTop: playing ? nil : pitch.aimTop(in: screen.size), tall: screen.size.height)
      captions(n, room: band.size)
        .frame(maxWidth: .infinity, maxHeight: band.height, alignment: .top)
        .clipShape(Rectangle().inset(by: -4))
        .padding(.trailing, WideLayout.uprightMinimap(size: screen.size, safe: screen.safe).width + 8)
      Spacer()
      if let online = model.online {
        HStack {
          shoutButton(online)
          Spacer()
          shouts(online)
        }.padding(meterRoom.edge, !playing && pitch.canAim ? meterRoom.width : 0)
      }
      bottom(n)
    }.padding(.horizontal, 12)
  }

  /// A phone on its side (WideLayout, the web's wide screen): the header top
  /// left with MENU inside it, SHOUT top right (moved in beside a linear meter at that
  /// edge), the captions between them, the plan in one
  /// block at the screen's edge away from the clock (WideLayout.plan), the
  /// panels and SKIP in the clock's corner.
  private func wide(_ n: MatchNeed) -> some View {
    let size = screen.size, safe = screen.safe
    let side = model.meter.side
    let meter = model.meter.layout(
      bounds: CGRect(origin: .zero, size: size),
      safe: UIEdgeInsets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right))
    // the linear meter takes its edge's whole height: the header or SHOUT moves in beside it
    let railBox = WideLayout.rail(size: size, safe: safe, meter: meter)
    let shoutBox = WideLayout.shout(size: size, safe: safe, meter: meter)
    let tray: CGFloat = model.online == nil ? 0 : WideLayout.trayWidth
    // under the floor beside SHOUT (a narrow window), a line of their own under
    // the header row; the stack may grow down to the first frame under it
    let captionBox = WideLayout.verdictClear(
      WideLayout.captionRoom(size: size, safe: safe, trayWidth: tray, meter: meter, side: side),
      aimTop: playing ? nil : pitch.aimTop(in: size))
    let plan = WideLayout.plan(meter: meter, size: size, safe: safe, side: side, trayWidth: tray)
    // the held slider's caption grows from the block's side toward the middle
    let from: Alignment = plan.edge == .left ? .topLeading : .topTrailing
    let corner: Alignment = side == .left ? .bottomLeading : .bottomTrailing
    let edge: Edge.Set = side == .left ? .leading : .trailing
    return ZStack(alignment: .topLeading) {
      Color.clear
      header(n, nameSize: 22, fills: true)
        .frame(width: railBox.width, height: railBox.height)
        .offset(x: railBox.minX, y: railBox.minY)
      captions(n, held: from, room: captionBox.size)
        .frame(width: captionBox.width, height: captionBox.height, alignment: .top)
        .clipShape(Rectangle().inset(by: -4))  // the plates' shadows, inside captionGap
        .offset(x: captionBox.minX, y: captionBox.minY)
      if let online = model.online {
        // SHOUT top right, the shouts under it
        VStack(alignment: .trailing, spacing: 6) {
          shoutButton(online)
          shouts(online)
        }
        .frame(width: 220, alignment: .trailing)
        .offset(x: shoutBox.maxX - 220, y: shoutBox.minY)
      }
      if (n.kind == "raise" || n.kind == "punish") && pitch.acceptsInput && WideLayout.isShort(size) {
        // a bar along the bottom (WideLayout.bar); its measured height keeps the
        // scene's working parts above it (PitchSession.stillFloor)
        let bar = WideLayout.bar(height: 0, size: size, safe: safe)
        placementBar(n)
          .frame(width: bar.width)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            pitch.stillFloor = Double(safe.bottom + WideLayout.barLift + h)
            model.refresh()
          }
          .onDisappear { pitch.stillFloor = nil; model.refresh() }
          .padding(.leading, bar.minX)
          .padding(.bottom, safe.bottom + WideLayout.barLift)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      }
      Group {
        if (n.kind == "raise" || n.kind == "punish") && pitch.acceptsInput && !WideLayout.isShort(size) {
          placement(n).frame(maxWidth: 360)
            .padding(edge, (side == .left ? safe.left : safe.right) + WideLayout.margin)
            .padding(.bottom, safe.bottom + 8)
        } else if playing {
          tool("SKIP", label: "Skip playback") {
            if let online = model.online { try online.skip() } else { try pitch.skipPlayback() }
          }
          .padding(edge, (side == .left ? safe.left : safe.right) + WideLayout.margin)
          .padding(.bottom, safe.bottom + 10)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
    }
    // flexible, so the screen it fills is the whole screen without growing the
    // safe area's container (a fixed frame did, widening the board under it)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ignoresSafeArea()
  }

  /// The header (the 1.0 design's shared header, the rail): "Turn 4 · baton 2 of 6" over
  /// the thrower's name in sentence case, the base kubbs standing for each side as two
  /// numbers on the team colours (Team A marigold, Team B violet; spoken as the web
  /// says them, "Kubbs standing: Mighty Maple 5, Computer 5"), and MENU as a word inside the plate, upright and on
  /// its side. VoiceOver reads it in that order: the turn, the name, the counts, Menu.
  /// `fills`: on its side the plate fills the header's frame (WideLayout.rail).
  private func header(_ n: MatchNeed, nameSize: CGFloat, fills: Bool = false) -> some View {
    let online = model.online != nil
    // where the WATCH tab says so (a throw this device watches, its meter drawn), the
    // line drops "Watch"; an observer's wide view and a raise it watches keep it
    let watching = (n.cpu == true || (online && !pitch.acceptsInput)) && (n.kind != "throw" || pitch.wideOn)
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 0) {
        Text(
          pitch.engineRaising.map { HeaderWords.engineRaise(turn: n.turn ?? 1, k: $0.k, of: $0.of, placed: $0.placed) }
            ?? HeaderWords.line(
              turn: n.turn ?? 1, n: n.setup?.n, of: n.setup?.of, projectile: n.setup?.projectile, watching: watching,
              at: n.kind == "throw" ? pitch.railAt : nil)
        )
        // upright the line may take two lines at the larger text sizes; on its side
        // the header's plate has a fixed height
        .labelStyle().foregroundStyle(Color.woodMuted).lineLimit(fills ? 1 : 2).minimumScaleFactor(0.7)
        Text(
          (online && !playing && !pitch.raiseShowing && model.online?.turnLabel.isEmpty == false)
            ? model.online!.turnLabel
            : (pitch.engineRaising.flatMap { r in r.side.flatMap { n.teams?[$0] } }
              ?? n.setup?.thrower?.name ?? n.team ?? "Match")
        )
        .font(displayFont(nameSize, relativeTo: .title2)).foregroundStyle(Color.woodInk)
        .lineLimit(1).minimumScaleFactor(0.6)  // the widest name fits (NameFitTests)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      if let counts = n.standing {
        let a = counts["A"] ?? 0, b = counts["B"] ?? 0
        HStack(spacing: 4) {
          teamNumber(a, fill: Color(skin.teamA), ink: Color(skin.onTeamA))
          teamNumber(b, fill: Color(skin.teamB), ink: Color(skin.onTeamB))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HeaderWords.counts(a: a, b: b, teamA: n.teams?["A"], teamB: n.teams?["B"]))
      }
      Button {
        model.screen = .menu
      } label: {
        Text(HeaderWords.menu).font(displayFont(17, relativeTo: .headline)).foregroundStyle(Color.woodInk)
          .lineLimit(1).fixedSize()
          .padding(.horizontal, 12).frame(minHeight: TW.touch)
          .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.controlRadius))
          .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: 2))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(HeaderWords.menuLabel)
    }
    .padding(.leading, 8)
    .frame(maxHeight: fills ? .infinity : nil)
    .modifier(Plate(fill: .woodBaton, inset: 5))
    // a plate over the pitch beside two numbers and MENU: its words stop growing at the
    // first accessibility size, where the line still takes two lines and the widest name
    // one (at AX3XL the line took three and the name was cut, "Brave Bi...")
    .dynamicTypeSize(.xSmall ... .accessibility1)
  }

  /// A side's base kubbs standing: a chip on the team's colour.
  private func teamNumber(_ count: Int, fill: Color, ink: Color) -> some View {
    Text("\(count)").font(bodyFont(16, .bold, relativeTo: .headline)).monospacedDigit()
      .foregroundStyle(ink).frame(minWidth: 30)
      .padding(.horizontal, 4).padding(.vertical, 3)
      .background(fill, in: RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.chipLine))
  }

  /// `held`: on a phone on its side, where the held slider's or STAND's caption
  /// sits in the top strip (nil: centred, as upright). `room`: on its side, the
  /// room the stack has (WideLayout.captionRoom). Where all of it does not fit,
  /// the verdict gives way while a slider is held (its words are live), else the
  /// wind does, then the verdict's rest and words (the flag beside them first in
  /// a wide room); the room is never shorter than the flag alone, and the frame
  /// clips so nothing reaches a control.
  @ViewBuilder private func captions(_ n: MatchNeed, held from: Alignment? = nil, room: CGSize? = nil) -> some View {
    if let room {
      let live = model.slow || (n.kind == "throw" && (pitch.standCaption != nil || pitch.held != nil))
      ViewThatFits(in: .vertical) {
        captionStack(n, held: from, top: true, verdict: .full)
        if live {
          captionStack(n, held: from, top: true, verdict: .short)
          captionStack(n, held: from, top: true, verdict: nil)
          // a held slider's words across a short, wide room take fewer lines
          captionStack(n, held: from, top: true, verdict: nil, wide: room.width)
        } else {
          captionStack(n, held: from, top: false, verdict: .full)
          if room.width >= 300 { captionStack(n, held: from, top: false, verdict: .full, row: true) }
          captionStack(n, held: from, top: false, verdict: .short)
          captionStack(n, held: from, top: false, verdict: .flag)
        }
      }
    } else {
      captionStack(n, held: from, top: true, verdict: .full)
    }
  }

  @ViewBuilder private func captionStack(
    _ n: MatchNeed, held from: Alignment?, top: Bool, verdict cut: Verdict.Cut?, row: Bool = false,
    wide: CGFloat = 180
  ) -> some View {
    VStack(spacing: 8) {
      if !top {
      } else if model.slow {
        Text("SLOW MOTION").font(bodyFont(14, .bold, relativeTo: .footnote)).modifier(Plate(inset: 5))
      } else if let stand = pitch.standCaption, n.kind == "throw" {
        SliderCaption(text: stand, maxWidth: wide).aligned(from)
      } else if let held = pitch.held, n.kind == "throw" {
        SliderCaption(text: PlanScale.caption(held, kubb: pitch.throwsKubb, drive: pitch.isDrive), maxWidth: wide).aligned(from)
      } else if let wind = pitch.windText, n.kind == "throw" {
        Text(wind).font(bodyFont(14, .bold, relativeTo: .footnote)).modifier(Plate(inset: 5))
      }
      // the engine's own raise watched: the last throw's verdict waits (its time does not run)
      if let cut, let result = model.result, n.kind == "throw", pitch.raiseWatch != .engine {
        Verdict(result: result, cut: cut, row: row)
      }
    }
  }

  /// An observer has no SHOUT (the web's docs/OBSERVER.md): it watches.
  @ViewBuilder private func shoutButton(_ online: OnlinePitch) -> some View {
    if !online.observing {
      Menu("SHOUT") {
        ForEach(OnlinePitch.words, id: \.self) { w in Button(w) { online.shout(w) } }
      }
      .buttonStyle(WoodButton())
    }
  }

  private func shouts(_ online: OnlinePitch) -> some View {
    VStack(alignment: .trailing) {
      ForEach(Array(online.shouts.enumerated()), id: \.offset) { _, s in
        Text(s).font(displayFont(20)).modifier(Plate(inset: 5))
      }
    }
  }

  @ViewBuilder private func bottom(_ n: MatchNeed) -> some View {
    if (n.kind == "raise" || n.kind == "punish") && pitch.acceptsInput {
      // the web's .panel, min(520px, 100% - 24px), centred: an iPad's is not a strip
      placement(n).frame(maxWidth: 520)
    } else if playing {
      // the bottom corner away from the meter (the web's): the right beside the clock,
      // the left beside a linear meter at the right
      HStack {
        if !skipAtLeft { Spacer() }
        tool("SKIP", label: "Skip playback") {
          if let online = model.online { try online.skip() } else { try pitch.skipPlayback() }
        }
        if skipAtLeft { Spacer() }
      }
    }
  }

  /// The set-up tray (TrayView): upright at the edge beside the clock away from the
  /// throwing thumb, on its side at the edge away from the meter.
  private var tray: some View {
    let size = screen.size, safe = screen.safe
    let meter = model.meter.layout(
      bounds: CGRect(origin: .zero, size: size),
      safe: UIEdgeInsets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right))
    let f = TrayView.frames(
      size: size, safe: safe, meter: meter, side: model.meter.side, online: model.online != nil,
      headerBottom: model.headerBottom)
    return TrayView(model: model, pitch: pitch, revision: revision, tray: f)
      .ignoresSafeArea()
  }

  /// Upright, SKIP stands at the left where a linear meter is at the right.
  private var skipAtLeft: Bool {
    let size = screen.size, safe = screen.safe
    let m = model.meter.layout(
      bounds: CGRect(origin: .zero, size: size),
      safe: UIEdgeInsets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right))
    return m.linear?.side == .right
  }

  /// SKIP (the 1.0 design): a plain button of normal size, 48 pt tall.
  private func tool(
    _ text: String, label: String, _ action: @escaping () throws -> Void
  ) -> some View {
    Button {
      model.perform(action)
    } label: {
      Text(text).frame(minWidth: 72)
    }
    .buttonStyle(WoodButton())
    .accessibilityLabel(label)
  }

  private func placement(_ n: MatchNeed) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(placementTitle(n)).font(displayFont(28))
      if n.kind == "punish" {
        Text(pitch.placement?.label ?? "Drag or tap a spot clear of the circles.").font(.subheadline)
        placementButtons(n)
      } else {
        placementWords(n)
        placementButtons(n)
        if !raisingAuto, let why = pitch.placement?.label { Text(why).font(bodyFont(14, .bold, relativeTo: .footnote)) }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).modifier(Plate())
  }

  /// A phone on its side (WideLayout.bar, the web's game.css .panel): the kicker
  /// on the first row with a refused spot's reason beside it, the words under it,
  /// the buttons in one row at the right across both rows. It covers grass only:
  /// the scene keeps its lowest working point 8 pt above it (WideLayout.stillLift).
  private func placementBar(_ n: MatchNeed) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(placementTitle(n)).labelStyle().lineLimit(1)
          Spacer(minLength: 0)
          if let why = barWhy(n) {
            Text(why).font(displayFont(15)).foregroundStyle(Color(skin.onWarn)).lineLimit(1)
              .padding(.horizontal, 8).padding(.vertical, 1)
              .background(Color(skin.warn), in: RoundedRectangle(cornerRadius: 3))
          }
        }
        if n.kind == "punish" {
          Text("Drag or tap a spot clear of the circles.").font(.subheadline)
        } else {
          placementWords(n)
        }
      }
      placementButtons(n, gap: 8, spread: false).fixedSize()
    }
    .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(Plate(inset: 0))
  }

  private func placementTitle(_ n: MatchNeed) -> String {
    "\(n.kind == "raise" ? "Raise" : "Punishment kubb") \(n.n ?? 1) of \(n.of ?? 1)"
  }

  private var raisingAuto: Bool { pitch.raiseAutomatically || pitch.raisingRest }

  /// The bar's reason chip: a refused spot (punishment) or a refused end (raise).
  private func barWhy(_ n: MatchNeed) -> String? {
    if n.kind == "punish" { return pitch.placement?.ok == false ? pitch.placement?.label : nil }
    return raisingAuto ? nil : pitch.placement?.label
  }

  @ViewBuilder private func placementWords(_ n: MatchNeed) -> some View {
    if raisingAuto {
      Text(
        pitch.raiseAutomatically
          ? "Raising automatically for the rest of the game." : "Raising the rest automatically."
      ).font(.subheadline)
    } else {
      // The kubb on the pitch is the control (RaiseTouch): END 1 and END 2 stay for
      // VoiceOver only, as actions on this text, which names the end on each side.
      let ends = pitch.raiseEndNames()
      Text(
        "Touch the kubb or drag it to the end to stand it on. The menu's Raising does it for the rest of the game."
      ).font(.subheadline)
        .accessibilityLabel(
          "A kubb lying, to be stood up: \(ends.map(\.name).joined(separator: ", ")). Tap the kubb nearer the end to stand it on, or use the actions."
        )
        .accessibilityActions {
          ForEach(ends.filter(\.ok), id: \.index) { e in
            Button("Stand it on \(e.name)") { model.perform { try pitch.raise(end: e.which) } }
          }
        }
    }
  }

  /// The raise and punishment panel's buttons (the 1.0 design's two-slot rule): the
  /// automatic choices plain at the left (AUTO and AUTO ALL; BY HAND and REST OF GAME),
  /// the one confirming action go at the right (PLACE IT), in every state. A state with
  /// nothing for a slot leaves it empty. `gap`: 6 pt on the panel, 8 in the bar (the
  /// web's .panel .row); `spread`: the panel's row spans its width, the slots at its
  /// ends.
  @ViewBuilder private func placementButtons(_ n: MatchNeed, gap: CGFloat = 6, spread: Bool = true) -> some View {
    HStack(spacing: gap) {
      HStack(spacing: gap) { automatic(n) }.buttonStyle(WoodButton())
      if spread { Spacer(minLength: 0) }
      confirming(n)
    }
  }

  /// The left slot: the automatic choices, plain.
  @ViewBuilder private func automatic(_ n: MatchNeed) -> some View {
    if n.kind == "punish" {
      EmptyView()
    } else if raisingAuto {
      Button("BY HAND") { model.raiseByHand() }
        .accessibilityHint("Choose the end for each kubb again")
      if !pitch.raiseAutomatically {
        Button("REST OF GAME") { model.raiseAutomatically = true }
          .accessibilityHint("Raise every kubb automatically for the rest of this match")
      }
    } else {
      Button("AUTO") { model.perform { try pitch.raiseWatched() } }
        .accessibilityHint("Stand this kubb on the end the game chooses")
      if (n.n ?? 1) < (n.of ?? 1) {
        Button { model.perform { pitch.raiseRest() } } label: {
          Text("AUTO ALL").lineLimit(1).fixedSize()
        }
        .accessibilityHint("Stand this kubb and the rest of this turn's on the ends the game chooses")
      }
    }
  }

  /// The right slot: the one confirming action, go. A raise by hand is confirmed on the
  /// kubb itself (RaiseTouch), so it has none.
  @ViewBuilder private func confirming(_ n: MatchNeed) -> some View {
    if n.kind == "punish" {
      Button("PLACE IT") { model.perform { try pitch.placePunishment() } }
        .buttonStyle(WoodButton(accent: true)).disabled(pitch.placement?.ok != true)
    }
  }

  /// The hand-off (the 1.0 design): a short card at the foot of the screen, the pitch
  /// dimmed above it under the header: the title ("Your turn", or the team's turn this
  /// device watches), one line of what the thrower faces (HandoffWords.line, from the
  /// engine's rail) and one go button. No turn number and no minimap: the header says
  /// the turn. The computer's turn has no card (the engine gives none): the header, the
  /// WATCH tab and the faded meter (BoardView).
  private func handoffCard(_ c: MatchNeed.Handoff) -> some View {
    let own = !(model.online != nil && !pitch.acceptsInput)
    let words = VStack(alignment: .leading, spacing: 8) {
      // a Kid match says so over the title (the web's handoffKid)
      if let kid = HandoffWords.kid(pitch.need) {
        Text(kid).labelStyle().fixedSize(horizontal: false, vertical: true)
      }
      Text(HandoffWords.title(c, own: own)).cardTitle(screen.wide ? 32 : 40)
        .lineLimit(1).minimumScaleFactor(0.6)
      Text(HandoffWords.line(c, at: pitch.railAt)).font(bodyFont(18, relativeTo: .body))
        .fixedSize(horizontal: false, vertical: true)
    }
    let go = Button {
      model.perform { pitch.dismissHandoff() }
    } label: {
      Text(own ? "THROW" : "WATCH").font(displayFont(28, relativeTo: .title)).frame(maxWidth: .infinity, minHeight: 52)
    }
    .buttonStyle(WoodButton(accent: true))
    // on a phone on its side the card is a short strip at the foot, its words beside
    // THROW (stacked it stood 190 of the 390 pt, over the middle of the pitch)
    return Group {
      if screen.wide {
        HStack(alignment: .center, spacing: 16) {
          words.frame(maxWidth: .infinity, alignment: .leading)
          go.frame(width: 170)
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          words
          go.padding(.top, 8)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: TW.cardRadius))
    .overlay(RoundedRectangle(cornerRadius: TW.cardRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
    .background(
      RoundedRectangle(cornerRadius: TW.cardRadius).fill(Color.woodDrop)
        .offset(x: TW.cardShadow, y: TW.cardShadow))
    .frame(maxWidth: screen.wide ? 600 : 420)
    .padding(.horizontal, TW.cardSide)
    .padding(.bottom, screen.wide ? 12 : max(8, 48 - screen.safe.bottom))
    .modifier(FitOrScroll())
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .accessibilityElement(children: .contain)
    .task(id: "\(c.turn)-\(pitch.acceptsInput)") {
      guard model.online != nil, !pitch.acceptsInput else { return }
      do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
      if !pitch.acceptsInput { model.perform { pitch.dismissHandoff() } }
    }
  }

  /// Someone else's turn, while this device watches (`OnlinePitch.watchHandoff`): the
  /// handoff card's words as a banner under the rail for 2.5 s, so their dial shows
  /// beneath it. Touches go through to the pitch.
  private func watchBanner(_ c: MatchNeed.Handoff) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("TURN \(c.turn)").font(.caption.bold()).tracking(1.5)
      if let kid = HandoffWords.kid(pitch.need) { Text(kid).font(.subheadline.bold()) }
      Text(c.toName).font(displayFont(30))
      if let took = c.took, let from = c.fromName {
        Text("\(from) took \(took.field) field and \(took.base) base kubbs.").font(.subheadline)
      }
      Text(HandoffWords.throwLine(c, watcher: true)).font(.subheadline)
    }
    .frame(maxWidth: 330, alignment: .leading)
    .modifier(Plate(inset: 12))
    .padding(.top, screen.wide ? 64 : 78)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .allowsHitTesting(false)
    .transition(.opacity)
    .accessibilityElement(children: .combine)
  }

  /// The winner card (the 1.0 design): REMATCH as go; SCORE SHEET plain (the app has
  /// no replay viewer, so no WATCH REPLAY); one SHARE button, which opens the share card
  /// and then the reel; HOME quiet.
  private func winner(_ n: MatchNeed, _ w: MatchNeed.Winner) -> some View {
    CardScreen(width: 400) {
      VStack(alignment: .leading, spacing: 10) {
        Text(n.short ?? "GAME").labelStyle().foregroundStyle(Color.woodMuted)
        Text("\(w.winnerName) wins").cardTitle(40)
        if let how = n.how { Text(how).font(bodyFont(17)).fixedSize(horizontal: false, vertical: true) }
        // the match's figures as chips, on two lines where one does not hold them
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { turns(w); hits(w); minutes(w) }
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) { turns(w); minutes(w) }
            hits(w)
          }
          VStack(alignment: .leading, spacing: 8) { turns(w); hits(w); minutes(w) }
        }
        .accessibilityElement(children: .combine)
      }
    } buttons: {
      VStack(alignment: .leading, spacing: 10) {
        if screen.wide {
          // on its side a phone is about 390 pt tall: the buttons share one row, REMATCH
          // last in it (the one go colour), so the figures above are not scrolled away
          HStack(spacing: 12) {
            Button(action: model.showSheet) { Text("SCORE SHEET").frame(maxWidth: .infinity) }
            shareButton
            rematchButton
          }
          .buttonStyle(WoodButton()).lineLimit(1).minimumScaleFactor(0.7)
        } else {
          rematchButton
          HStack(spacing: 12) {
            Button(action: model.showSheet) { Text("SCORE SHEET").frame(maxWidth: .infinity) }
            shareButton
          }
          .buttonStyle(WoodButton()).lineLimit(1).minimumScaleFactor(0.7)
        }
        QuietButton("HOME", action: model.home)
      }
    }
    .onAppear { model.prepareShare() }
  }

  /// REMATCH, the winner card's go: the host's online, a match against the computer's
  /// options; none for a sealed pitch opened by its code.
  @ViewBuilder private var rematchButton: some View {
    if let online = model.online {
      if online.isHost {
        Button { model.runOnline { try await online.rematch() } } label: {
          Text("REMATCH").frame(maxWidth: .infinity)
        }.buttonStyle(WoodButton(accent: true))
      }
    } else if model.sealed == nil {
      Button { model.screen = .options } label: { Text("REMATCH").frame(maxWidth: .infinity) }
        .buttonStyle(WoodButton(accent: true))
    }
  }

  private func turns(_ w: MatchNeed.Winner) -> some View { Text("\(w.turns) turns").modifier(Chip()) }
  private func hits(_ w: MatchNeed.Winner) -> some View {
    Text("\(w.hits ?? 0) of \(w.thrown ?? 0) batons hit").modifier(Chip())
  }
  @ViewBuilder private func minutes(_ w: MatchNeed.Winner) -> some View {
    if let minutes = w.minutes { Text(minutes == 0 ? "Under a minute" : "\(minutes) min").modifier(Chip()) }
  }

  /// The winner card's one SHARE (the web's word, its src/ui/cards.js): a finished pitch
  /// with its replay (the web's docs/REEL.md); a match against the computer (the share
  /// card first, ShareCard.swift); a shared match opened by its code, whose reel is of
  /// its kept match. The card it opens says how the reel stands.
  @ViewBuilder private var shareButton: some View {
    if let sealed = model.sealed {
      Button { model.openReel(code: sealed.code, match: sealed.match) } label: { share }
    } else if model.online == nil, model.share != nil {
      Button(action: model.openShare) { share }
    } else if let code = model.onlineReelCode {
      Button { model.openReel(code: code, match: model.online?.controller.finishedReplay) } label: { share }
    }
  }
  private var share: some View { Text("SHARE").frame(maxWidth: .infinity) }
}

/// The menu's Raising: By hand or Automatic, for the rest of this match, a segmented
/// bar. Shown once this device has been asked to raise in the match (the web's
/// menu-raise): a match whose own Raising option is Automatic never asks.
struct RaisingSetting: View {
  @Bindable var model: GameModel
  var body: some View {
    if model.pitch?.raiseSeen == true {
      FormRow("Raising") { full in
        Segmented(
          label: "Raising", choices: [(false, "By hand"), (true, "Automatic")],
          value: $model.raiseAutomatically, full: full)
      }
    }
  }
}

extension View {
  /// Set to one side of the width it is given, or as it is (nil).
  @ViewBuilder fileprivate func aligned(_ alignment: Alignment?) -> some View {
    if let alignment { frame(maxWidth: .infinity, alignment: alignment) } else { self }
  }
}

/// The app's version at the foot of a menu, in small type (VersionLabel.swift):
/// `0.2 (0.8.1)`, then the build number and any older engine this build also plays.
struct VersionFooter: View {
  let label: VersionLabel
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Throwing Wood \(label.text)")
      ForEach(label.detail, id: \.self) { Text($0) }
    }
    .font(bodyFont(14, relativeTo: .footnote)).foregroundStyle(Color.woodMuted)
    .accessibilityElement(children: .combine)
  }
}

/// The watcher's free camera controls (the web's watch-view.js): RESET VIEW low on the
/// left once the view has moved, and the hint until the first move or 8 s. Nothing is
/// stored.
private struct FreeViewControls: View {
  let model: GameModel, pitch: PitchSession, revision: Int
  @Environment(\.screenGeometry) private var screen
  @State private var hintOver = false
  var body: some View {
    let safe = screen.safe
    ZStack(alignment: .bottomLeading) {
      Color.clear
      if !hintOver && !pitch.freeCamera.touched {
        Text("Drag to look around. Pinch to zoom.")
          .font(bodyFont(14, .bold, relativeTo: .footnote)).modifier(Plate(inset: 6))
          .frame(maxWidth: .infinity)
          .padding(.bottom, safe.bottom + 64)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
      if pitch.freeCamera.moved {
        Button("RESET VIEW") {
          model.perform { pitch.resetView(reduced: UIAccessibility.isReduceMotionEnabled) }
        }
        .buttonStyle(WoodButton())
        .accessibilityHint("Back to the view of the whole pitch")
        .padding(.leading, safe.left + 12)
        .padding(.bottom, safe.bottom + 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .ignoresSafeArea()
    .task {
      do { try await Task.sleep(for: .seconds(FreeCam.hintTime)) } catch { return }
      withAnimation { hintOver = true }
    }
  }
}
