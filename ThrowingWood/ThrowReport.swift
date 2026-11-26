import KubbRenderer
import KubbPitch
import SwiftUI

extension EnvironmentValues {
  @Entry var reportViewport: CGSize = .zero
}

/// SEND FEEDBACK (the practice menu), or FEEDBACK in a match menu's grid (the 1.0
/// design's word there), filling its cell.
struct ReportButton: View {
  let model: GameModel
  var title = "SEND FEEDBACK"
  @Environment(\.reportViewport) private var size
  @Environment(\.displayScale) private var scale

  var body: some View {
    Button {
      model.perform {
        guard let board = model.pitch else { return }
        model.report =
          try model.online?.captureReport(size: size, scale: scale)
          ?? board.captureReport(size: size, scale: scale)
        model.reportReturn = model.screen == .practice || model.screen == .practiceMenu ? .practice : .match
        model.screen = .report
      }
    } label: {
      Text(title).frame(maxWidth: title == "FEEDBACK" ? .infinity : nil)
    }
  }
}

/// The feedback card (the web's src/ui/report.js): "A throw looked wrong" (two answers) or
/// "Something else" (one box), either with a picture of the pitch to paint on where there
/// is one (PaintPicture), sent with the game as it stood when the card opened
/// (PitchReport).
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
  @State private var paint = ReportPaint(brush: 0)
  @State private var sending = false
  @State private var sent = false
  @State private var status = ""
  @FocusState private var typing: String?

  init(model: GameModel, report: PitchReport, kind: Kind? = nil) {
    self.model = model
    self.report = report
    _kind = State(initialValue: kind ?? (report.hasLastThrow ? .throw : .feedback))
    #if targetEnvironment(simulator)
      // the "painted" review: a stroke over the near kubbs and a dab at the far ones
      if ProcessInfo.processInfo.environment["MATCH_REVIEW"] == "painted" {
        _paint = State(
          initialValue: ReportPaint(
            brush: 0.25,
            strokes: [
              (0..<12).map { CGPoint(x: -1.8 + Double($0) * 0.3, y: 0.2 + sin(Double($0) / 2) * 0.3) },
              [CGPoint(x: 0.4, y: 7.6)],
            ]))
      }
    #endif
  }

  private var ready: Bool {
    let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return kind == .throw ? !(blank(happened) && blank(should)) : !blank(text)
  }

  var body: some View {
    // an iPad's: the web's .report, min(560px, 100%), centred; a phone keeps its whole
    // width, as before. SEND and CANCEL are the card's pinned button row, so on a phone
    // on its side (about 390 pt tall) they stay in view while the rows above them scroll
    CardScreen(width: UIDevice.current.userInterfaceIdiom == .pad ? 560 : 760) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Send feedback").cardTitle()
        if sent {
          Text("Sent, thank you.")
        } else {
          Segmented(
            label: "What is it about?", choices: Kind.allCases.map { ($0, $0.label) }, value: $kind, full: true
          ).disabled(sending)
            .onChange(of: kind) { status = "" }
          if kind == .throw {
            field("What happened?", $happened, limit: PitchReport.answerChars, lines: 2...5)
            field("What should have happened?", $should, limit: PitchReport.answerChars, lines: 2...5)
          } else {
            field(
              "What would you like to tell us?", $text, limit: PitchReport.feedbackChars,
              lines: 4...8,
              hint: "A problem, an idea, something you liked or did not. Anything.")
          }
          if !report.candidates.isEmpty {
            PaintPicture(pieces: report.candidates, paint: $paint, disabled: sending)
          }
          Text(kind == .throw ? Self.throwNote : Self.feedbackNote).font(bodyFont(14, relativeTo: .footnote))
          if !status.isEmpty { Text(status) }
        }
      }
    } buttons: {
      if sent {
        Button("BACK TO THE PITCH", action: close).buttonStyle(WoodButton())
      } else {
        HStack {
          Button(sending ? "SENDING…" : "SEND", action: send).disabled(sending || !ready)
          Button("CANCEL", action: close).disabled(sending)
        }.buttonStyle(WoodButton())
      }
    }
    // the keyboard goes with a drag down the rows, or DONE over it
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { typing = nil }.font(bodyFont(17, .bold))
      }
    }
  }

  private func send() {
    sending = true
    let kind = kind
    Task {
      defer { sending = false }
      do {
        let message =
          kind == .throw
          ? try report.message(happened: happened, should: should, paint: paint)
          : try report.feedback(text, paint: paint)
        // the same call online or not: no member id goes with a report
        try await PitchConfiguration.client.report(message)
        sent = true
      } catch {
        let why = (error as? PitchError).flatMap { Self.failures[$0.code] } ?? "Try again in a moment."
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
    ReportField(
      label: label, value: value, limit: limit, lines: lines, hint: hint, typing: $typing, sending: sending)
  }
}

/// One answer box: its label, any hint, and the field. Where the card is short (a phone
/// on its side with the keyboard up, `cardShort`) the field keeps to three lines, so the
/// line being typed stays in view over the keyboard.
private struct ReportField: View {
  let label: String
  @Binding var value: String
  let limit: Int, lines: ClosedRange<Int>, hint: String?
  var typing: FocusState<String?>.Binding
  let sending: Bool
  @Environment(\.cardShort) private var short

  var body: some View {
    VStack(alignment: .leading) {
      Text(label).font(.subheadline.bold())
      if let hint { Text(hint).font(bodyFont(14, relativeTo: .footnote)) }
      TextField("", text: $value, axis: .vertical).lineLimit(short ? 1...3 : lines)
        .textFieldStyle(.roundedBorder).focused(typing, equals: label).accessibilityLabel(label)
        .accessibilityHint(hint ?? "").disabled(sending)
        .onChange(of: value) { _, text in
          if text.unicodeScalars.count > limit {
            value = String(text.unicodeScalars.prefix(limit))
          }
        }
    }
  }
}
