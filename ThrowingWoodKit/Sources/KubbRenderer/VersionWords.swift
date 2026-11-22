import Foundation

/// What the app says when a match or a pitch is on an engine it does not carry. The app
/// supports only the newest engine (docs/ENGINES.md), so a match made on an older one
/// cannot be replayed here, and a pitch plays only when everyone on it has the newest
/// version. The words are the web's (its src/net/pitch.js and src/replay/player.js),
/// with "update" where the web says "reload the page", and they never name a version.
public enum VersionWords {
  /// A kept match, a finished match or a shared replay made on an engine this build does
  /// not carry: the one sentence, wherever it is opened (the web's OLD_REPLAY).
  public static let oldMatch =
    "This match was made on an older version of the game and can no longer be replayed."

  /// This device is the one without the pitch's engine.
  public static let needsNewest =
    "This pitch needs the newest version of the game. Update to play."

  /// "Ada", "Ada and Bo", "Ada, Bo and Cy" (the web's namesLine).
  public static func names(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names.last!
  }

  /// Players on an older version than this app's: they must update.
  public static func older(_ who: [String]) -> String {
    let n = names(who)
    return
      "\(n) \(who.count > 1 ? "have" : "has") an older version of the game. This pitch needs the newest version of the game. \(n): update to play."
  }

  /// Players on a newer version than this app's, while this device has the pitch's
  /// engine: this app updates, or they watch.
  public static func newer(_ who: [String]) -> String {
    let n = names(who)
    return
      "\(n) \(who.count > 1 ? "have" : "has") a newer version of the game than this app. Update the app to play, or \(n) can watch."
  }

  /// START refused by the engine's own check (players naming another engine).
  public static func another(_ who: [String]) -> String {
    "\(names(who)) \(who.count > 1 ? "are" : "is") on another version of the game. This pitch needs the newest version of the game: update to play."
  }

  /// The lobby's line for a room with no engine its host and players all carry: who
  /// stands in the way and what to do. `missing` (the engine's `engineFor`: those without
  /// the engine most share, and those naming none) may hold `you`; `players` are the
  /// others who count (seated, or the host); `isNewer` says a member's newest engine is
  /// newer than this build's (anyone naming none is older).
  public static func lobby(
    missing: [String], you: String, players: [String], isNewer: (String) -> Bool,
    name: (String) -> String
  ) -> String {
    var ids: [String] = []
    for id in missing where !ids.contains(id) { ids.append(id) }
    if ids.contains(you) {
      // this device is the odd one out: it updates, or (the others being older) they do
      if players.isEmpty || players.contains(where: isNewer) { return needsNewest }
      return older(players.map(name))
    }
    let newerIDs = ids.filter(isNewer)
    let olderIDs = ids.filter { !isNewer($0) }
    var lines: [String] = []
    if !olderIDs.isEmpty { lines.append(older(olderIDs.map(name))) }
    if !newerIDs.isEmpty { lines.append(newer(newerIDs.map(name))) }
    return lines.isEmpty ? needsNewest : lines.joined(separator: " ")
  }

  /// The card over a pitch whose match (or host) this app cannot play: a title and one
  /// line, with WATCH. `newer`: the pitch is on a newer version than this app.
  public static func cardTitle(newer: Bool) -> String { newer ? "A newer version" : "An older version" }
  public static func cardText(newer: Bool) -> String {
    newer
      ? "This pitch is playing on a newer version of the game. Update to play."
      : "This pitch is playing on an older version of the game, which this app no longer plays. This pitch needs the newest version of the game: the host must update to play."
  }
}

/// A kept match, a finished match or a shared replay made on an engine this build does
/// not carry (`engine`, its major.minor): `PitchSession.restore` refuses it, changing
/// nothing, and the screen says `VersionWords.oldMatch`.
public struct OldMatch: Error, Equatable {
  public let engine: String
}

/// A kept match or a shared replay holding a name the game did not make (a typed name
/// from before generated names, or a forged one): it is not shown, since its snapshot is
/// hashed and the name cannot be put right; the screen says `NameWords.badMatch`.
public struct BadNamesMatch: Error, Equatable {
  public init() {}
}

/// The words about names (the web's, kubb-engine docs/NAMES.md).
public enum NameWords {
  /// The title of a match whose names the game did not make (the web's notice).
  public static let badMatchTitle = "Cannot show this match"
  /// The web's NAMES_REPLAY.
  public static let badMatch = "This match has a name the game did not make, so it cannot be shown."
  /// The share card's refusal of a name (the server's `why: "name"`, and a name that
  /// does not pass on the card).
  public static let pick = "Pick a name for your side."
  /// What a lobby or pitch write refused as `bad-name` says (the web's plain error).
  public static let refused = "The pitch did not take that. Try again."
  /// A side of several players' team name heading in the lobby.
  public static let playsAs = "PLAYS AS"
}
