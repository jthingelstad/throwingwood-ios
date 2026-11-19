import KubbRenderer
import KubbRooms
import SwiftUI

extension EnvironmentValues {
  @Entry var reportViewport: CGSize = .zero
}

struct ReportButton: View {
  let model: GameModel
  @Environment(\.reportViewport) private var size
  @Environment(\.displayScale) private var scale

  var body: some View {
    Button("SEND FEEDBACK") {
      model.perform {
        guard let board = model.pitch else { return }
        model.report =
          try model.online?.captureReport(size: size, scale: scale)
          ?? board.captureReport(size: size, scale: scale)
        model.reportReturn = model.screen == .practice ? .practice : .match
        model.screen = .report
      }
    }
  }
}

/// The feedback card (the web's src/ui/report.js): "A throw looked wrong" (two answers and
/// pieces to mark) or "Something else" (one box), sent with the game as it stood when the
/// card opened (PitchReport).
struct ReportCard: View {
  enum Kind: String, CaseIterable, Identifiable {
    case `throw`, feedback
    var id: String { rawValue }
    var label: String { self == .throw ? "A throw looked wrong" : "Something else" }
  }

  static let throwNote =
    "This sends what you typed with this game as it stands (its options, names and throws), so the throw can be played again and tested. It is kept privately and not published."
  static let feedbackNote =
    "This sends what you typed with this game as it stands (its options, names and throws). It is kept privately and not published."
  static let failures = [
    "too-many": "Too many sent at once. Try again in a moment.",
    "too-big": "That is too long to send.",
    "timeout": "The server did not answer.",
    "uncertain": "The server did not answer.",
    "closed": "The server could not be reached.",
    "unavailable": "Feedback cannot be sent from here.",
  ]

  let model: GameModel, report: PitchReport
  @State private var kind: Kind
  @State private var happened = ""
  @State private var should = ""
  @State private var text = ""
  @State private var selected: Set<String> = []
  @State private var sending = false
  @State private var sent = false
  @State private var status = ""

  init(model: GameModel, report: PitchReport, kind: Kind? = nil) {
    self.model = model
    self.report = report
    _kind = State(initialValue: kind ?? (report.hasLastThrow ? .throw : .feedback))
  }

  private var ready: Bool {
    let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return kind == .throw ? !(blank(happened) && blank(should)) : !blank(text)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Send feedback").font(displayFont(36))
        if sent {
          Text("Sent, thank you.")
          Button("BACK TO THE PITCH", action: close).buttonStyle(WoodButton())
        } else {
          Picker("What is it about?", selection: $kind) {
            ForEach(Kind.allCases) { Text($0.label).tag($0) }
          }.pickerStyle(.segmented).disabled(sending)
            .onChange(of: kind) { status = "" }
          if kind == .throw {
            if !report.candidates.isEmpty {
              DisclosureGroup(selected.isEmpty ? "Mark pieces" : "Mark pieces (\(selected.count))") {
                ReportPiecePicker(pieces: report.candidates, selected: $selected)
              }.disabled(sending)
            }
            field("What happened?", $happened, limit: PitchReport.answerChars, lines: 2...5)
            field("What should have happened?", $should, limit: PitchReport.answerChars, lines: 2...5)
          } else {
            field(
              "What would you like to tell us?", $text, limit: PitchReport.feedbackChars,
              lines: 4...8,
              hint: "A problem, an idea, something you liked or did not. Anything.")
          }
          Text(kind == .throw ? Self.throwNote : Self.feedbackNote).font(.footnote)
          if !status.isEmpty { Text(status) }
          HStack {
            Button(sending ? "SENDING…" : "SEND", action: send).disabled(sending || !ready)
            Button("CANCEL", action: close).disabled(sending)
          }.buttonStyle(WoodButton())
        }
      }.modifier(Plate())
        // an iPad's: the web's .report, min(560px, 100%), centred; a phone keeps
        // its whole width, as before
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 560 : .infinity)
        .padding(16).frame(maxWidth: .infinity)
    }.scrollDismissesKeyboard(.interactively)
  }

  private func send() {
    sending = true
    let kind = kind
    Task {
      defer { sending = false }
      do {
        let message =
          kind == .throw
          ? try report.message(happened: happened, should: should, selected: selected)
          : try report.feedback(text)
        if let online = model.online {
          try await online.room.sendPitchReport(message)
        } else {
          try await RoomsClient.sendReport(
            message, url: RoomsConfiguration.url, appVersion: GameModel.version)
        }
        sent = true
      } catch {
        let why = (error as? RoomError).flatMap { Self.failures[$0.code] } ?? "Try again in a moment."
        status = "\(kind == .throw ? "The report" : "Your feedback") was not sent. \(why)"
      }
    }
  }

  private func close() {
    model.report = nil
    model.screen = model.reportReturn
  }

  private func field(
    _ label: String, _ value: Binding<String>, limit: Int, lines: ClosedRange<Int>,
    hint: String? = nil
  ) -> some View {
    VStack(alignment: .leading) {
      Text(label).font(.subheadline.bold())
      if let hint { Text(hint).font(.footnote) }
      TextField("", text: value, axis: .vertical).lineLimit(lines)
        .textFieldStyle(.roundedBorder).accessibilityLabel(label)
        .accessibilityHint(hint ?? "").disabled(sending)
        .onChange(of: value.wrappedValue) { _, text in
          if text.unicodeScalars.count > limit {
            value.wrappedValue = String(text.unicodeScalars.prefix(limit))
          }
        }
    }
  }
}

private struct ReportPiecePicker: View {
  let pieces: [ReportPiece]
  @Binding var selected: Set<String>

  var body: some View {
    let left = min(0, pieces.map(\.y).min() ?? 0) - 0.6
    let right = max(8, pieces.map(\.y).max() ?? 8) + 0.6
    let top = min(-2.5, pieces.map(\.x).min() ?? 0) - 0.5
    let bottom = max(2.5, pieces.map(\.x).max() ?? 0) + 0.5
    GeometryReader { geo in
      let dx = geo.size.width / (right - left)
      let dy = geo.size.height / (bottom - top)
      ZStack(alignment: .topLeading) {
        Color(red: 0.33, green: 0.45, blue: 0.31)
        Rectangle().stroke(.white).frame(width: 8 * dx, height: 5 * dy).offset(
          x: -left * dx, y: (-2.5 - top) * dy)
        Rectangle().fill(.white).frame(width: 1, height: 5 * dy).offset(
          x: (4 - left) * dx, y: (-2.5 - top) * dy)
        ForEach(pieces) { p in
          toggle(p, compact: true)
            .position(x: (p.y - left) * dx, y: (p.x - top) * dy)
            .zIndex(selected.contains(p.id) ? 2 : (p.kind == "stake" ? 0 : 1))
        }
      }
    }.aspectRatio(1.8, contentMode: .fit).accessibilityHidden(true)
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 75))], spacing: 5) {
      ForEach(pieces) { p in toggle(p, compact: false) }
    }
  }

  private func toggle(_ p: ReportPiece, compact: Bool) -> some View {
    let suffix = p.id.hasPrefix(p.kind) ? String(p.id.dropFirst(p.kind.count)) : p.id.uppercased()
    let label = [p.kind.capitalized, suffix].filter { !$0.isEmpty }.joined(separator: " ")
    return Button {
      if !selected.insert(p.id).inserted { selected.remove(p.id) }
    } label: {
      Text(compact ? (p.kind == "stake" ? "•" : p.id.uppercased()) : label)
        .font(compact ? .system(size: 10, weight: .bold) : .caption.bold())
        .padding(compact ? 3 : 6)
        .background(
          selected.contains(p.id) ? Color.woodGold : .woodPaper,
          in: RoundedRectangle(cornerRadius: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.woodInk))
    }.buttonStyle(.plain).accessibilityLabel(label)
      .accessibilityAddTraits(selected.contains(p.id) ? .isSelected : [])
  }
}
