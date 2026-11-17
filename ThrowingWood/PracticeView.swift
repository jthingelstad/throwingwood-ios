import KubbRenderer
import SwiftUI

extension Color {
  static let woodInk = Color(red: 23 / 255, green: 20 / 255, blue: 15 / 255)
  static let woodPaper = Color(red: 251 / 255, green: 246 / 255, blue: 234 / 255)
}

private struct Plate: ViewModifier {
  func body(content: Content) -> some View {
    content.foregroundStyle(Color.woodInk)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(Color.woodPaper, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.woodInk, lineWidth: 2))
      .background(RoundedRectangle(cornerRadius: 5).fill(Color.woodInk).offset(x: 3, y: 3))
  }
}

@MainActor @Observable final class PracticeModel {
  let pitch: PracticePitch?
  var error: String?
  var surface = Surface.grass
  var result: ThrowResult?
  var playing = false
  init() {
    do {
      pitch = try PracticePitch(
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "0")
    } catch {
      pitch = nil
      self.error = error.localizedDescription
    }
  }
  func refresh() {
    guard let pitch else { return }
    if playing != pitch.playing { playing = pitch.playing }
    if result != pitch.result { result = pitch.result }
    if surface != pitch.scene.surface { surface = pitch.scene.surface }
  }
  func select(_ s: Surface) {
    do {
      try pitch?.surface(s)
      refresh()
    } catch { self.error = error.localizedDescription }
  }
}

struct PracticeView: View {
  @State private var model = PracticeModel()
  @Environment(\.scenePhase) private var phase
  var body: some View {
    ZStack {
      if let pitch = model.pitch {
        PracticeBoard(pitch: pitch, model: model, active: phase == .active, surface: model.surface)
          .ignoresSafeArea()
        VStack(spacing: 14) {
          HStack {
            Text("Practice pitch").font(.custom("LondrinaSolid-Black", size: 31))
            Spacer()
            Menu {
              Picker("Surface", selection: Binding(get: { model.surface }, set: model.select)) {
                ForEach(Surface.allCases, id: \.self) { s in Text(s.rawValue.capitalized).tag(s) }
              }
            } label: {
              HStack(spacing: 6) {
                Text(model.surface.rawValue.capitalized).bold()
                Image(systemName: "chevron.up.chevron.down").font(.caption.bold())
              }.frame(minHeight: 36)
            }.accessibilityLabel("Surface, \(model.surface.rawValue)")
              .disabled(model.playing)
          }.modifier(Plate())
          if let result = model.result {
            VStack(spacing: 4) {
              if let flag = result.flag {
                Text(flag).font(.custom("LondrinaSolid-Black", size: 32))
              }
              HStack(spacing: 4) {
                ForEach(Array(result.words.enumerated()), id: \.offset) { _, word in
                  Text(word.text).font(.caption.bold()).padding(.horizontal, 3).padding(
                    .vertical, 2
                  )
                  .foregroundStyle(word.offTarget ? Color.woodPaper : Color.woodInk)
                  .background(
                    word.offTarget ? Color.woodInk : Color.clear,
                    in: RoundedRectangle(cornerRadius: 2))
                }
              }.minimumScaleFactor(0.7).lineLimit(1)
              if let rest = result.restText, !rest.isEmpty { Text(rest).font(.caption) }
            }.modifier(Plate()).allowsHitTesting(false)
          }
          Spacer()
        }.padding(.horizontal, 16).padding(.top, 5)
      }
      if let error = model.error {
        Text(error).modifier(Plate()).accessibilityLabel("Practice error, \(error)")
      }
    }
    .preferredColorScheme(.light)
  }
}

private struct PracticeBoard: UIViewRepresentable {
  let pitch: PracticePitch, model: PracticeModel, active: Bool, surface: Surface
  func makeUIView(context: Context) -> BoardView { BoardView(pitch: pitch, model: model) }
  func updateUIView(_ view: BoardView, context: Context) {
    view.setActive(active)
    view.setNeedsDisplay()
  }
  static func dismantleUIView(_ view: BoardView, coordinator: ()) { view.stop() }
}
