import KubbRenderer
import SwiftUI
import UniformTypeIdentifiers

struct HomeCard: View {
  let model: GameModel
  var body: some View {
    VStack {
      VStack(spacing: -5) {
        Text("KUBB").font(displayFont(82))
        Text("THROWING WOOD").font(displayFont(30))
      }.padding(.horizontal, 20).modifier(Plate())
      Spacer()
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
          model.screen = .practice
        } label: {
          Text("PRACTICE").frame(maxWidth: .infinity)
        }
        .buttonStyle(WoodButton())
      }.frame(maxWidth: 280)
    }.padding(.top, 22).padding(.bottom, 44)
  }
}

struct MatchOptionsCard: View {
  @Bindable var model: GameModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Play the computer").font(displayFont(37))
      TextField("Your name", text: $model.name)
        .textFieldStyle(.roundedBorder).accessibilityLabel("Your name")
        .onChange(of: model.name) { _, value in
          model.name = String(value.prefix(model.pitch?.options.nameLimit ?? value.count))
        }
      ForEach(model.pitch?.options.rows ?? []) { row in
        HStack {
          Text(row.label).font(.subheadline.weight(.semibold))
          Spacer()
          Menu {
            ForEach(row.choices, id: \.self) { choice in
              Button {
                model.selections[row.id] = choice[0]
              } label: {
                if model.selections[row.id] == choice[0] {
                  Label(choice[1], systemImage: "checkmark")
                } else {
                  Text(choice[1])
                }
              }
            }
          } label: {
            let value = row.choices.first { $0[0] == model.selections[row.id] }?.last ?? ""
            HStack {
              Text(value)
              Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .frame(minWidth: 100, minHeight: 32, alignment: .trailing)
          }.accessibilityLabel(row.label)
        }
        Divider()
      }
      HStack {
        Button("HOME", action: model.home).buttonStyle(WoodButton())
        Spacer()
        Button("START", action: model.start).buttonStyle(WoodButton(accent: true))
      }
    }.modifier(Plate(inset: 20)).frame(maxWidth: 560).padding(18)
      // centred when it fits; on a phone on its side it scrolls from its title
      .frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FitOrScroll())
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Score sheet").font(displayFont(38))
      Text("Planet Kubb Notation").font(.subheadline.weight(.semibold))
      GeometryReader { box in
        ScrollView([.vertical, .horizontal]) {
          Text(verbatim: positions ? sheet.text : sheet.shown.joined(separator: "\n"))
            .font(.system(size: 13, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true).textSelection(.enabled).padding(10)
            // a sheet shorter than its box (an iPad's tall window) starts at the
            // top, as it does where it overflows, not in the box's middle
            .frame(minWidth: box.size.width, minHeight: box.size.height, alignment: .topLeading)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white).border(Color.woodInk)
      Toggle("Show positions", isOn: $positions)
      HStack {
        Button(copied ? "COPIED" : "COPY") {
          UIPasteboard.general.string = sheet.text
          copied = true
        }.buttonStyle(WoodButton())
        Spacer()
        Button("SAVE") { exporting = true }.buttonStyle(WoodButton())
        Button("BACK", action: done).buttonStyle(WoodButton(accent: true))
      }
    }.modifier(Plate())
      // an iPad's: the web's .sheet, min(640px, 100%); a phone keeps its whole
      // width, upright and on its side, as before
      .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 640 : .infinity).padding(16)
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

struct MatchMenu: View {
  @Bindable var model: GameModel
  let pitch: PitchSession
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Match menu").font(displayFont(36))
      if let row = pitch.options.rows.first(where: { $0.id == "level" }) {
        MenuRow("Your level") {
          Picker("Your level", selection: $model.matchLevel) {
            ForEach(row.choices, id: \.self) { c in Text(c[1]).tag(c[0]) }
          }.pickerStyle(.segmented).accessibilityLabel("Your level")
        }
      }
      Text(
        model.meter.kind == .linear
          ? "Tap the pitch to aim, or drag anywhere to move the circle. Draw the knob back toward you, fling it up through the middle and let go on the blue."
          : "Tap the pitch to aim, or drag anywhere to move the circle. Wind back on the left of the dial, flick through six and lift on the right."
      )
      .font(.subheadline)
      FeedbackSettings(feedback: model.feedback, card: true)
      RaisingSetting(model: model)
      MeterSettings(meter: model.meter, card: true)
      ReportButton(model: model).buttonStyle(WoodButton())
      Button("SCORE SHEET", action: model.showSheet).buttonStyle(WoodButton())
      HStack {
        Button("HOME", action: model.home)
        Spacer()
        Button(pitch.need?.resignPending == nil ? "RESIGN" : "RESIGNING…") {
          model.perform {
            try pitch.resign()
            model.screen = .match
          }
        }.disabled(pitch.need?.resignPending != nil)
      }.buttonStyle(WoodButton())
      Button("BACK TO MATCH") { model.screen = .match }.buttonStyle(WoodButton(accent: true))
      VersionFooter(label: pitch.versionLabel)
    }.frame(maxWidth: 330, alignment: .leading).modifier(Plate(inset: 20)).padding(20)
      .modifier(FitOrScroll())
  }
}

struct MatchScreen: View {
  let model: GameModel, pitch: PitchSession, revision: Int, playing: Bool
  @Environment(\.meterRoom) private var meterRoom
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    if let n = pitch.need {
      ZStack {
        if screen.wide {
          wide(n)
        } else {
          tall(n)
        }
        if let c = pitch.handoff {
          modal { handoff(c) }
        } else if let w = n.winner {
          modal { winner(n, w) }
        }
      }
    }
  }

  /// A phone held upright: the rail across the top, the plan along the bottom.
  private func tall(_ n: MatchNeed) -> some View {
    VStack(spacing: 8) {
      HStack {
        rail(n)
        menuButton
      }.modifier(Plate(inset: 9))
      captions(n)
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

  /// A phone on its side (WideLayout, the web's wide screen): the rail top
  /// left, SHOUT and MENU top right (moved in beside a linear meter at that
  /// edge), the captions between them, the plan in one
  /// block at the screen's edge away from the clock (WideLayout.plan), the
  /// panels and SKIP in the clock's corner.
  private func wide(_ n: MatchNeed) -> some View {
    let size = screen.size, safe = screen.safe
    let side = model.meter.side
    let meter = model.meter.layout(
      bounds: CGRect(origin: .zero, size: size),
      safe: UIEdgeInsets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right))
    // the linear meter takes its edge's whole height: the rail or MENU moves in beside it
    let railBox = WideLayout.rail(size: size, safe: safe, meter: meter)
    let menuBox = WideLayout.menu(size: size, safe: safe, meter: meter)
    let tray: CGFloat = model.online == nil ? 0 : WideLayout.trayWidth
    // under the floor beside SHOUT (a narrow window), a line of their own under
    // the header row; the stack may grow down to the first frame under it
    let captionBox = WideLayout.captionRoom(size: size, safe: safe, trayWidth: tray, meter: meter, side: side)
    let plan = WideLayout.plan(meter: meter, size: size, safe: safe, side: side, trayWidth: tray)
    // the held slider's caption grows from the block's side toward the middle
    let from: Alignment = (plan.edge ?? (side == .right ? .left : .right)) == .left ? .topLeading : .topTrailing
    let corner: Alignment = side == .left ? .bottomLeading : .bottomTrailing
    let edge: Edge.Set = side == .left ? .leading : .trailing
    return ZStack(alignment: .topLeading) {
      Color.clear
      HStack { rail(n) }.modifier(Plate(inset: 9))
        .frame(width: railBox.width, alignment: .leading)
        .offset(x: railBox.minX, y: railBox.minY)
      menuButton.modifier(Plate(inset: 4))
        .frame(width: menuBox.width, height: menuBox.height)
        .offset(x: menuBox.minX, y: menuBox.minY)
      captions(n, held: from, room: captionBox.size)
        .frame(width: captionBox.width, height: captionBox.height, alignment: .top)
        .clipShape(Rectangle().inset(by: -4))  // the plates' shadows, inside captionGap
        .offset(x: captionBox.minX, y: captionBox.minY)
      if let online = model.online {
        // the tray beside MENU, the shouts under it
        VStack(alignment: .trailing, spacing: 6) {
          shoutButton(online)
          shouts(online)
        }
        .frame(width: 220, alignment: .trailing)
        .offset(x: menuBox.minX - WideLayout.shoutGap - 220, y: menuBox.minY)
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
      if !playing && pitch.canAim && !((n.kind == "raise" || n.kind == "punish") && pitch.acceptsInput) {
        // TILT and STAND at the screen's edge, ARC and SIDE VIEW toward the middle
        plans
          .frame(
            width: plan.block.width, height: plan.block.height,
            alignment: plan.edge == .left || (plan.edge == nil && side == .left) ? .bottomLeading : .bottomTrailing)
          .offset(x: plan.block.minX, y: plan.block.minY)
      }
    }
    // flexible, so the screen it fills is the whole screen without growing the
    // safe area's container (a fixed frame did, widening the board under it)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ignoresSafeArea()
  }

  private func rail(_ n: MatchNeed) -> some View {
    Group {
      VStack(alignment: .leading, spacing: 1) {
        Text(
          n.cpu == true || (model.online != nil && !pitch.acceptsInput)
            ? "WATCH  ·  TURN \(n.turn ?? 1)" : "TURN \(n.turn ?? 1)"
        )
        .font(.caption2.bold()).tracking(1.4)
        Text(
          (model.online != nil && !playing && model.online?.turnLabel.isEmpty == false)
            ? model.online!.turnLabel : (n.setup?.thrower?.name ?? n.team ?? "Match")
        ).font(displayFont(27)).lineLimit(1)
      }
      Spacer()
      VStack(alignment: .trailing) {
        if let s = n.setup {
          let left = s.of - s.n + (playing ? 0 : 1)
          Text(
            s.projectile == "baton"
              ? "\(left) \(left == 1 ? "baton" : "batons") left" : "Kubb \(s.n) of \(s.of)"
          )
          .font(.subheadline.bold())
        }
        if let counts = n.standing {
          Text(
            model.online == nil
              ? "You \(counts["A"] ?? 0)  ·  CPU \(counts["B"] ?? 0)"
              : "A \(counts["A"] ?? 0)  ·  B \(counts["B"] ?? 0)"
          )
          .font(.caption).accessibilityLabel(
            model.online != nil
              ? "Kubbs standing, team A \(counts["A"] ?? 0), team B \(counts["B"] ?? 0)"
              : "Kubbs standing, you \(counts["A"] ?? 0), computer \(counts["B"] ?? 0)")
        }
      }
    }
  }

  private var menuButton: some View {
    Button {
      model.screen = .menu
    } label: {
      Image(systemName: "ellipsis.circle").font(.title2).frame(width: 35, height: 38)
    }.accessibilityLabel("Match menu")
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
        Text("SLOW MOTION").font(.caption.bold()).modifier(Plate(inset: 5))
      } else if let stand = pitch.standCaption, n.kind == "throw" {
        SliderCaption(text: stand, maxWidth: wide).aligned(from)
      } else if let held = pitch.held, n.kind == "throw" {
        SliderCaption(text: PlanScale.caption(held, kubb: pitch.throwsKubb), maxWidth: wide).aligned(from)
      } else if let wind = pitch.windText, n.kind == "throw" {
        Text(wind).font(.caption.bold()).modifier(Plate(inset: 5))
      }
      if let cut, let result = model.result, n.kind == "throw" { Verdict(result: result, cut: cut, row: row) }
    }
  }

  private func shoutButton(_ online: OnlinePitch) -> some View {
    Menu("SHOUT") {
      ForEach(OnlinePitch.words, id: \.self) { w in Button(w) { online.shout(w) } }
    }
    .buttonStyle(WoodButton())
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
    } else if !playing && pitch.canAim {
      plans.padding(meterRoom.edge, meterRoom.width)
    } else if playing {
      HStack {
        Spacer()
        tool("SKIP", label: "Skip playback") {
          if let online = model.online { try online.skip() } else { try pitch.skipPlayback() }
        }
      }
    }
  }

  private var plans: some View {
    PlanControls(model: model, pitch: pitch, revision: revision)
  }

  private func tool(
    _ text: String, label: String, on: Bool = false, _ action: @escaping () throws -> Void
  ) -> some View {
    Button {
      model.perform(action)
    } label: {
      Text(text).font(displayFont(16)).frame(minWidth: 43, minHeight: 31)
        .modifier(Plate(fill: on ? .woodGold : .woodPaper, inset: 4))
    }.accessibilityLabel(label)
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
        if !raisingAuto, let why = pitch.placement?.label { Text(why).font(.caption.bold()) }
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
          Text(placementTitle(n).uppercased()).font(.caption.bold()).tracking(1.4)
            .lineLimit(1)
          Spacer(minLength: 0)
          if let why = barWhy(n) {
            Text(why).font(displayFont(15)).foregroundStyle(.white).lineLimit(1)
              .padding(.horizontal, 8).padding(.vertical, 1)
              .background(Color(red: 0.86, green: 0.25, blue: 0.22), in: RoundedRectangle(cornerRadius: 3))
          }
        }
        if n.kind == "punish" {
          Text("Drag or tap a spot clear of the circles.").font(.subheadline)
        } else {
          placementWords(n)
        }
      }
      placementButtons(n, gap: 8).fixedSize()
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

  /// `gap`: 6 pt on the panel, 8 in the bar (the web's .panel .row).
  @ViewBuilder private func placementButtons(_ n: MatchNeed, gap: CGFloat = 6) -> some View {
    if n.kind == "punish" {
      Button("PLACE IT") { model.perform { try pitch.placePunishment() } }
        .buttonStyle(WoodButton(accent: true)).disabled(pitch.placement?.ok != true)
    } else if raisingAuto {
      HStack(spacing: gap) {
        Button("BY HAND") { model.raiseByHand() }
          .accessibilityHint("Choose the end for each kubb again")
        if !pitch.raiseAutomatically {
          Button("REST OF GAME") { model.raiseAutomatically = true }
            .accessibilityHint("Raise every kubb automatically for the rest of this match")
        }
      }.buttonStyle(WoodButton())
    } else {
      HStack(spacing: gap) {
        Button("AUTO") { model.perform { try pitch.raise() } }
          .accessibilityHint("Stand this kubb on the end the game chooses")
        if (n.n ?? 1) < (n.of ?? 1) {
          Button { model.perform { pitch.raiseRest() } } label: {
            Text("AUTO ALL").lineLimit(1).fixedSize()
          }
          .accessibilityHint("Stand this kubb and the rest of this turn's on the ends the game chooses")
        }
      }.buttonStyle(WoodButton())
    }
  }

  private func modal<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ZStack {
      Color.black.opacity(0.26).ignoresSafeArea()
      content().frame(maxWidth: 330).modifier(Plate(inset: 20)).padding(22).modifier(FitOrScroll())
    }
  }

  private func handoff(_ c: MatchNeed.Handoff) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("TURN \(c.turn)").font(.caption.bold()).tracking(1.5)
      Text(c.toName).font(displayFont(44))
      if let took = c.took, let from = c.fromName {
        Text("\(from) took \(took.field) field and \(took.base) base kubbs.")
      }
      Text(
        c.kubbs > 0
          ? "Throw \(c.kubbs) kubbs in, then \(c.batons) batons." : "Throw \(c.batons) batons.")
      HStack {
        Text(c.baseText.joined(separator: "\n")).font(.caption.bold())
        Spacer()
        Canvas { ctx, size in
          ctx.withCGContext { cg in
            pitch.scene.scenery.drawMap(
              in: cg, rect: CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
          }
        }.frame(width: 62, height: 98)
      }
      Button(model.online != nil && !pitch.acceptsInput ? "WATCH" : "THROW") {
        model.perform { pitch.dismissHandoff() }
      }.buttonStyle(
        WoodButton(accent: true))
    }.frame(maxWidth: .infinity, alignment: .leading)
      .task(id: "\(c.turn)-\(pitch.acceptsInput)") {
        guard model.online != nil, !pitch.acceptsInput else { return }
        do { try await Task.sleep(for: .milliseconds(2500)) } catch { return }
        if !pitch.acceptsInput { model.perform { pitch.dismissHandoff() } }
      }
  }

  private func winner(_ n: MatchNeed, _ w: MatchNeed.Winner) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(n.short ?? "GAME").font(.caption.bold()).tracking(1.2)
      Text("\(w.winnerName) wins").font(displayFont(40))
      if let how = n.how { Text(how) }
      Text("\(w.turns) turns  ·  \(w.hits ?? 0) of \(w.thrown ?? 0) batons hit").font(
        .subheadline.bold())
      if let minutes = w.minutes {
        Text(minutes == 0 ? "Under a minute" : "\(minutes) min").font(.caption)
      }
      HStack {
        if let online = model.online {
          if online.isHost {
            Button("REMATCH") { model.runOnline { try await online.rematch() } }.buttonStyle(
              WoodButton(accent: true))
          }
        } else if model.sealed == nil {
          Button("REMATCH") { model.screen = .options }.buttonStyle(WoodButton(accent: true))
        }
        Button("SCORE SHEET", action: model.showSheet).buttonStyle(WoodButton())
      }
      // a finished pitch with its replay (the web's docs/REEL.md); a match against the
      // computer once shared (the share card first, ShareCard.swift); a shared match
      // opened by its code, whose reel is of its kept match
      if let sealed = model.sealed {
        let code = sealed.code
        let shown = model.reel?.code == code && model.reel?.match == sealed.match
        Button {
          model.openReel(code: code, match: sealed.match)
        } label: {
          Text(ReelWords.button(shown ? model.reel?.phase : nil)).lineLimit(1).minimumScaleFactor(0.8)
        }.buttonStyle(WoodButton())
      } else if model.online == nil, model.share != nil {
        Button(action: model.openShare) {
          Text(model.shareButton).lineLimit(1).minimumScaleFactor(0.8)
        }.buttonStyle(WoodButton())
      } else if let code = model.onlineReelCode {
        let match = model.online?.controller.finishedReplay
        let shown = model.reel?.code == code && model.reel?.match == match
        Button {
          model.openReel(code: code, match: match)
        } label: {
          Text(ReelWords.button(shown ? model.reel?.phase : nil)).lineLimit(1).minimumScaleFactor(0.8)
        }.buttonStyle(WoodButton())
      }
      Button("HOME", action: model.home).font(.caption.bold()).padding(.vertical, 8)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .onAppear { model.prepareShare() }
  }
}

/// The menu's Raising: By hand or Automatic, for the rest of this match. Shown once this
/// device has been asked to raise in the match (the web's menu-raise): a match whose own
/// Raising option is Automatic never asks.
struct RaisingSetting: View {
  @Bindable var model: GameModel
  var body: some View {
    if model.pitch?.raiseSeen == true {
      MenuRow("Raising") {
        Picker("Raising", selection: $model.raiseAutomatically) {
          Text("By hand").tag(false)
          Text("Automatic").tag(true)
        }.pickerStyle(.segmented)
      }
    }
  }
}

/// ARC over SIDE VIEW on the left of the dial, TILT or SPIN over STAND on the
/// right, their feet level. With the linear meter on the left the two swap, so
/// the shorter TILT column sits beside the meter, under its prompt tab. On a
/// phone on its side the two are one block beside the clock, ARC next to it
/// (the web's wide `.plans`).
struct PlanControls: View {
  let model: GameModel, pitch: PitchSession, revision: Int
  @Environment(\.meterRoom) private var meterRoom
  @Environment(\.screenGeometry) private var screen
  var body: some View {
    if screen.wide {
      HStack(alignment: .bottom, spacing: 10) {
        if model.meter.side == .left {
          reported(arc, 0)
          reported(side, 1)
        } else {
          reported(side, 1)
          reported(arc, 0)
        }
      }
    } else {
      let mirrored = meterRoom.width > 0 && meterRoom.edge == .leading
      HStack(alignment: .bottom) {
        if mirrored { reported(side, 1) } else { reported(arc, 0) }
        Spacer()
        if mirrored { reported(arc, 0) } else { reported(side, 1) }
      }
    }
  }

  /// Where a column is, for the coach line (BoardView keeps it clear of them).
  private func reported(_ column: some View, _ key: Int) -> some View {
    column
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.planFrames[key] = $0 }
      .onDisappear { model.planFrames[key] = nil }
  }

  private var arc: some View {
    let enabled = pitch.canAim
    return VStack(spacing: 12) {
      ArcSlider(
        release: pitch.release, loft: pitch.arcDegrees,
        held: pitch.held == .arc ? pitch.heldFraction : nil, enabled: enabled,
        slide: { f, phase in model.perform { pitch.slide(.arc, to: f, phase: phase) } },
        step: { s in model.perform { try pitch.stepPlan(.arc, by: s) } })
      tool("SIDE VIEW", label: "Side view", on: pitch.plan) { try pitch.togglePlan() }
    }
  }

  private var side: some View {
    let enabled = pitch.canAim
    return VStack(spacing: 12) {
      SideSlider(
        value: pitch.sideStep ?? 0, kubb: pitch.throwsKubb,
        held: pitch.held == .side ? pitch.heldFraction : nil, enabled: enabled,
        slide: { f, phase in model.perform { pitch.slide(.side, to: f, phase: phase) } },
        step: { s in model.perform { try pitch.stepPlan(.side, by: s) } })
      StandPlate(
        span: pitch.standSpan, thrower: pitch.standPoint, held: pitch.standHeld, enabled: enabled,
        valueText: pitch.standValueText,
        stand: { fx, fy, phase in model.perform { pitch.stand(fx: fx, fy: fy, phase: phase) } },
        step: { dx, dy in model.perform { try pitch.standStep(dx: dx, dy: dy) } })
    }
  }

  private func tool(
    _ text: String, label: String, on: Bool, _ action: @escaping () throws -> Void
  ) -> some View {
    Button {
      model.perform(action)
    } label: {
      Text(text).font(displayFont(16)).frame(minWidth: 84, minHeight: 34)
        .modifier(Plate(fill: on ? .woodGold : .woodPaper, inset: 4))
    }.accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
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
    .font(.caption2).foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}
