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
    Button("REPORT A THROW") {
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

struct ReportCard: View {
  let model: GameModel, report: PitchReport
  @State private var happened = ""
  @State private var should = ""
  @State private var selected: Set<String> = []
  @State private var sending = false
  @State private var sent = false
  @State private var status = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Report a throw").font(displayFont(36))
        if sent {
          Text("Sent, thank you.")
          Button("BACK TO THE PITCH", action: close).buttonStyle(WoodButton())
        } else {
          if !report.candidates.isEmpty {
            DisclosureGroup(selected.isEmpty ? "Mark pieces" : "Mark pieces (\(selected.count))") {
              ReportPiecePicker(pieces: report.candidates, selected: $selected)
            }.disabled(sending)
          }
          field("What happened?", $happened)
          field("What should have happened?", $should)
          Text(
            "Your answers and this game’s names, options and throws are kept privately so the throw can be replayed."
          )
          .font(.footnote)
          if !status.isEmpty { Text(status) }
          HStack {
            Button("CANCEL", action: close).disabled(sending)
            Button(sending ? "SENDING…" : "SEND") {
              sending = true
              Task {
                defer { sending = false }
                do {
                  let message = try report.message(
                    happened: happened, should: should, selected: selected)
                  if let online = model.online {
                    try await online.room.sendPitchReport(message)
                  } else {
                    try await RoomsClient.sendReport(
                      message, url: RoomsConfiguration.url, appVersion: GameModel.version)
                  }
                  sent = true
                } catch {
                  status = "The report could not be sent. Your answers are here to try again."
                }
              }
            }.disabled(
              sending || (happened + should).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }.buttonStyle(WoodButton())
        }
      }.modifier(Plate()).padding(16)
    }.scrollDismissesKeyboard(.interactively)
  }

  private func close() {
    model.report = nil
    model.screen = model.reportReturn
  }

  private func field(_ label: String, _ value: Binding<String>) -> some View {
    VStack(alignment: .leading) {
      Text(label).font(.subheadline.bold())
      TextField("", text: value, axis: .vertical).lineLimit(2...5)
        .textFieldStyle(.roundedBorder).accessibilityLabel(label).disabled(sending)
        .onChange(of: value.wrappedValue) { _, text in
          if text.unicodeScalars.count > 1000 {
            value.wrappedValue = String(text.unicodeScalars.prefix(1000))
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
