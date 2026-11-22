import KubbRenderer
import Observation
import SwiftUI
import UIKit

/// The home screen's icon, this device's choice: the Park king (the primary) or a
/// scene's own king (`AppIconArt.icons`). iOS keeps it; the app asks for it through
/// `setAlternateIconName` and reads it back from `alternateIconName`.
@MainActor @Observable final class AppIconChoice {
  private(set) var icon: AppIconArt.Icon
  /// Set when iOS refused a change; the row says so under the tiles.
  private(set) var refused = false
  init() {
    icon = AppIconArt.icon(alternateName: UIApplication.shared.alternateIconName)
  }
  var available: Bool { UIApplication.shared.supportsAlternateIcons }

  #if targetEnvironment(simulator)
    /// The review pictures: the icon a review launch asks for (`REVIEW_APP_ICON`, a
    /// scene id), chosen as a player would once the card is on screen.
    func reviewChoice() async {
      guard let scene = ProcessInfo.processInfo.environment["REVIEW_APP_ICON"],
        let wanted = AppIconArt.icons.first(where: { $0.scene == scene })
      else { return }
      try? await Task.sleep(for: .seconds(1))
      choose(wanted)
    }
  #endif

  func choose(_ chosen: AppIconArt.Icon) {
    guard chosen != icon, available else { return }
    icon = chosen
    refused = false
    Task { await apply(chosen) }
  }

  /// Asks iOS for `chosen`. While its notice of an earlier change is still up iOS
  /// answers "try again" (EAGAIN), and sometimes makes the change all the same, so the
  /// icon iOS reports is what counts: asked again a few times, a second apart, and only
  /// if iOS still has another does the tile go back to it and the row say so.
  private func apply(_ chosen: AppIconArt.Icon) async {
    let wanted = AppIconArt.alternateName(chosen)
    for attempt in 0..<4 {
      if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
      guard icon == chosen else { return }  // another tile was picked meanwhile
      if attempt > 0 && UIApplication.shared.alternateIconName == wanted { return }
      do {
        try await UIApplication.shared.setAlternateIconName(wanted)
        return
      } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EAGAIN) {
        continue
      } catch {
        break
      }
    }
    try? await Task.sleep(for: .seconds(1))
    let kept = AppIconArt.icon(alternateName: UIApplication.shared.alternateIconName)
    guard icon == chosen, kept != chosen else { return }
    icon = kept
    refused = true
  }

  /// Each icon's picture for its tile, drawn once by the same code that made the icon.
  static let pictures: [String: UIImage] = {
    var all: [String: UIImage] = [:]
    for icon in AppIconArt.icons {
      if let image = AppIconArt.image(icon, pixels: 180) { all[icon.asset] = UIImage(cgImage: image) }
    }
    return all
  }()
}

/// App icon on the Settings card: the icons as small picture tiles, each the icon
/// itself masked as the home screen masks it, its scene's name under it (Park, Camping,
/// Techno); the chosen tile's name inverted, ink with paper type, and its plate raised
/// by the hard shadow, as the solo card's Scene tiles are. VoiceOver reads the group as
/// App icon and each tile as "Park icon, selected, 1 of 3". From the largest three text
/// sizes the tiles stand in one column.
struct AppIconSettings: View {
  @Bindable var choice: AppIconChoice
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    if choice.available {
      VStack(alignment: .leading, spacing: 6) {
        Text("App icon").labelStyle().foregroundStyle(Color.woodInk).accessibilityHidden(true)
        tiles
        if choice.refused { Text("This device kept the icon it had.").helperText() }
      }
      #if targetEnvironment(simulator)
        .task { await choice.reviewChoice() }
      #endif
    }
  }

  private var tiles: some View {
    let icons = AppIconArt.icons
    let layout = type >= .accessibility3 ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    return layout {
      ForEach(Array(icons.enumerated()), id: \.offset) { i, icon in
        tile(icon, index: i, count: icons.count)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("App icon")
  }

  private func tile(_ icon: AppIconArt.Icon, index: Int, count: Int) -> some View {
    let on = choice.icon == icon
    return Button {
      choice.choose(icon)
    } label: {
      VStack(spacing: 0) {
        Group {
          if let picture = AppIconChoice.pictures[icon.asset] {
            Image(uiImage: picture).resizable().interpolation(.high)
          } else {
            Color.woodField
          }
        }
        .frame(width: 44, height: 44)
        // the home screen's mask: about 22% of the side, continuous corners
        .clipShape(RoundedRectangle(cornerRadius: 44 * 0.225, style: .continuous))
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.woodBaton)
        Rectangle().fill(Color.woodInk).frame(height: TW.line)
        Text(AppIconArt.name(icon)).font(bodyFont(14, .bold, relativeTo: .subheadline)).tracking(14 * 0.04)
          .textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.7)
          .foregroundStyle(on ? Color.woodPaper : Color.woodInk)
          .frame(maxWidth: .infinity, minHeight: 28)
          .background(on ? Color.woodInk : Color.woodBaton)
      }
      .clipShape(RoundedRectangle(cornerRadius: TW.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: TW.controlRadius).strokeBorder(Color.woodInk, lineWidth: TW.line))
      .background(
        RoundedRectangle(cornerRadius: TW.controlRadius).fill(on ? Color.woodDrop : .clear)
          .offset(x: TW.controlShadow, y: TW.controlShadow))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(AppIconArt.spokenName(icon))
    .accessibilityValue(SegmentWords.value(index: index, count: count, selected: on))
    .accessibilityIdentifier("app-icon-\(icon.scene)")
  }
}
