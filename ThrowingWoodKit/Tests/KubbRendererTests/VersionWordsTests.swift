import Testing

@testable import KubbRenderer

/// The words for a pitch or a match on an engine this build does not carry
/// (VersionWords.swift): the web's, plain, never naming a version.
struct VersionWordsTests {
  let names = ["me": "Ada", "bo": "Bo", "cy": "Cy", "di": "Di"]
  func line(missing: [String], players: [String], newer: Set<String> = []) -> String {
    VersionWords.lobby(
      missing: missing, you: "me", players: players, isNewer: { newer.contains($0) },
      name: { names[$0] ?? "Someone" })
  }

  /// The two sides of one pitch: the newer side names the older player, who must update;
  /// the older side (this app, were it the old one) is told to update.
  @Test func eachSideIsToldPlainlyWhoUpdates() {
    #expect(
      line(missing: ["bo"], players: ["bo"])
        == "Bo has an older version of the game. This pitch needs the newest version of the game. Bo: update to play.")
    #expect(
      line(missing: ["bo", "cy"], players: ["bo", "cy", "di"])
        == "Bo and Cy have an older version of the game. This pitch needs the newest version of the game. Bo and Cy: update to play.")
    // this device is the odd one out among newer players: it updates
    #expect(line(missing: ["me"], players: ["bo"], newer: ["bo"]) == VersionWords.needsNewest)
    #expect(VersionWords.needsNewest == "This pitch needs the newest version of the game. Update to play.")
    // the host on an older engine leaves this device out: the host is told to update
    #expect(
      line(missing: ["me"], players: ["bo"])
        == "Bo has an older version of the game. This pitch needs the newest version of the game. Bo: update to play.")
    // a newer player while this device has the room's engine: update, or they watch
    #expect(
      line(missing: ["bo"], players: ["bo"], newer: ["bo"])
        == "Bo has a newer version of the game than this app. Update the app to play, or Bo can watch.")
    #expect(VersionWords.names(["Ada", "Bo", "Cy"]) == "Ada, Bo and Cy")
  }

  @Test func noLineNamesAVersion() {
    let all = [
      VersionWords.oldMatch, VersionWords.needsNewest, VersionWords.older(["Bo"]),
      VersionWords.newer(["Bo"]), VersionWords.another(["Bo"]),
      VersionWords.cardText(newer: true), VersionWords.cardText(newer: false),
    ]
    for text in all {
      #expect(text.firstMatch(of: /\d+\.\d+/) == nil, "\(text)")
      #expect(!text.contains("reload"), "\(text)")
    }
    #expect(
      VersionWords.oldMatch
        == "This match was made on an older version of the game and can no longer be replayed.")
  }
}
