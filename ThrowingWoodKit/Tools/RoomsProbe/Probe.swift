// Local test driver, not shipped in the app. JSON-lines RPC lets the Node harness
// exercise the public Swift client/controller over a real Foundation WebSocket.
import Foundation
import KubbEngine
import KubbRenderer
import KubbRooms

@MainActor final class FixedID: MemberIDStore {
  var id: String?
  init(_ id: String?) { self.id = id }
  func load() -> String? { id }
  func save(_ id: String) { self.id = id }
}

@main struct Probe {
  @MainActor static func main() async throws {
    var pitches: [String: PitchController] = [:]
    var screens: [String: OnlinePitch] = [:]
    var events: [String: [JSONText]] = [:]
    var wires: [String: WebSocketTransport] = [:]
    var wireParts: [String: Frames.Reassembler] = [:]
    // FileHandle's async bytes keep the main actor free for socket callbacks.
    for try await line in FileHandle.standardInput.bytes.lines {
      var response: JS
      do {
        let cmd = try JSONNode.parse(line)
        let key = cmd["key"]?.string ?? "a"
        let op = cmd["op"]!.string!
        let p = pitches[key]
        let screen = screens[key]
        switch op {
        case "practiceReport":
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          let practice = try PitchSession(appVersion: "0.0-test")
          let report = try practice.captureReport(size: CGSize(width: 390, height: 844), scale: 3)
          let message = try report.message(
            happened: "Synthetic contact", should: "Both pieces move", selected: ["king", "b1"])
          try await RoomsClient.sendReport(message, url: url, appVersion: "0.0-test")
          response = .bool(true)
        case "shareMake":
          // the iPhone's `share` message for a finished match against the computer, made
          // on the match's own engine when this build carries it (as the app's session is)
          let mm = Engine.majorMinor(cmd["engine"]?.string)
          let engine = try Engine(
            minor: mm.flatMap { Engine.carried.contains($0) ? $0 : nil }, appVersion: "0.0-test")
          let source = ShareSource(
            engine: cmd["engine"]!.string!, start: cmd["start"]!.string!,
            actions: cmd["actions"]!.items.map(\.raw), winner: cmd["winner"]!.string!)
          switch try ShareMessage.make(engine: engine, source: source, name: cmd["name"]!.string!) {
          case .message(let text, let bytes):
            response = .object([("message", .string(text.text)), ("bytes", .int(bytes))])
          case .refused(let why): response = .object([("refused", .string(why.rawValue))])
          }
        case "share":
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          let reply = try await RoomsClient.share(
            JSONText(cmd["message"]!.string!), url: url, appVersion: "0.0-test")
          response = .object([
            ("code", reply.code.map(JS.string) ?? .null), ("v", reply.v.map(JS.int) ?? .null),
            ("why", reply.why.map(JS.string) ?? .null),
          ])
        case "reel":
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          let answer = try await RoomsClient.reel(room: cmd["room"]!.string!, url: url, appVersion: "0.0-test")
          response = .string(String(describing: answer))
        case "sealedCard":
          // what the app's sealed card shows: the kept replay's last snapshot, restored
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          guard let kept = try await RoomsClient.kept(room: cmd["room"]!.string!, url: url, appVersion: "0.0-test"),
            let snap = kept.snap
          else { throw RoomError("no-kept-replay") }
          let board = try PitchSession(appVersion: "0.0-test")
          try board.restore(snap, save: nil)
          response = .object([
            ("need", .string(board.need?.kind ?? "")), ("v", .int(kept.v)),
            ("n", kept.n.map(JS.int) ?? .null), ("hash", kept.hash.map(JS.string) ?? .null),
          ])
        case "wireConnect":
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          var request = URLRequest(url: url)
          request.setValue("https://app.throwingwood.com", forHTTPHeaderField: "Origin")
          request.setValue("ThrowingWood/0.0-test (ios)", forHTTPHeaderField: "User-Agent")
          wires[key] = WebSocketTransport(request: request)
          wireParts[key] = Frames.Reassembler()
          response = .bool(true)
        case "wire":
          let socket = wires[key]!
          for f in cmd["frames"]!.items {
            for frame in Frames.split(f.string!) { try await socket.send(frame) }
          }
          var answer: JSONNode?
          for _ in 0..<200 {
            let frame = try await socket.receive()
            if let text = wireParts[key]!.accept(frame) {
              let node = try JSONNode.parse(text)
              if node["t"]?.string == cmd["until"]?.string {
                answer = node
                break
              }
            }
          }
          guard let answer else { throw RoomError("no-wire-answer") }
          response = .raw(answer.raw)
        case "wireClose":
          wires[key]?.close()
          wires[key] = nil
          response = .bool(true)
        case "connect":
          let url = URL(string: cmd["url"]!.string!)!
          guard url.host == "127.0.0.1", url.scheme == "ws" else { throw RoomError("local-only") }
          let engines = try EngineShelf(appVersion: "0.0-test")
          let engine = engines.newest
          var timing = RoomsClient.Timing()
          timing.retry = .milliseconds(10)
          timing.retryMax = .milliseconds(50)
          let pitch: PitchController
          let room: RoomsClient
          if cmd["screen"]?.bool == true {
            let screen = try OnlinePitch(
              url: url, link: PitchLink(cmd["room"]!.string!)!, create: cmd["create"]?.bool ?? true,
              name: key, level: "pro", appVersion: "0.0-test",
              store: FixedID(cmd["member"]?.string), timing: timing)
            screens[key] = screen
            pitch = screen.controller
            room = screen.room
          } else {
            room = try RoomsClient(
              url: url, room: cmd["room"]!.string!, engineVersion: engine.engineVersion,
              appVersion: "0.0-test", me: [("name", .string(key)), ("level", .string("pro"))],
              store: FixedID(cmd["member"]?.string), timing: timing)
            pitch = try PitchController(room: room, engines: engines)
          }
          events[key] = []
          room.observe { event in
            if case .message(let node) = event { events[key, default: []].append(node.raw) }
          }
          pitches[key] = pitch
          if let screen = screens[key] { screen.connect() } else { pitch.connect() }
          try await room.ready()
          response = .string(room.you)
        case "state":
          let p = p!
          let display: [(String, JS)] = [
            ("display", screen.map { .string(String(describing: $0.stage)) } ?? .null),
            ("card", screen?.versionCard.map { .string($0.rawValue) } ?? .null),
            ("displayHash", screen.map { .string($0.displayedHash) } ?? .null),
            ("displayCorrections", .int(screen?.displayCorrections ?? 0)),
            ("shownAims", .int(screen?.shownAims ?? 0)),
            ("shouts", .array((screen?.shouts ?? []).map(JS.string))),
            ("note", .string(screen?.note ?? "")),
          ]
          let authority: [(String, JS)] = [
            ("state", .string(p.state.rawValue)), ("status", .string(p.room.status.rawValue)),
            ("you", .string(p.room.you)), ("host", p.room.host.map(JS.string) ?? .null),
            ("v", .int(p.room.version)), ("doc", .raw(p.room.document)),
            ("members", p.room.membersJSON), ("seq", .int(p.sequence)),
          ]
          let checks: [(String, JS)] = [
            ("hash", p.state == .match ? .string(try p.engine.hash()) : .null),
            ("applied", .int(p.applied)), ("corrections", .int(p.corrections)),
            ("adoptions", .int(p.adoptions)),
            ("mayAct", .bool(p.mayAct)), ("need", .raw(p.need)), ("control", .raw(p.control)),
            ("error", p.lastError.map(JS.string) ?? .null),
            ("mismatch", p.mismatch.map(JS.raw) ?? .null),
            ("engine", .string(p.engine.engineVersion)),
            ("carried", .array(p.engines.carried.map(JS.string))),
            ("loaded", .array(p.engines.loaded.map(JS.string))),
            ("announced", p.announced.map(JS.raw) ?? .null),
            ("engineLine", screen?.engineLine.map(JS.string) ?? .null),
            ("canStart", screen.map { .bool($0.canStart) } ?? .null),
            ("boardEngine", screen.map { .string($0.board.engine.engineVersion) } ?? .null),
          ]
          response = .object(display + authority + checks)
        case "team":
          if let screen {
            try await screen.team(cmd["side"]?.string)
          } else {
            try await p!.joinTeam(cmd["side"]?.string)
          }
          response = .bool(true)
        case "reduce":
          response = .bool(
            try await p!.reduce(
              cmd["name"]!.string!,
              fields: cmd["fields"]?.members.map { ($0.key, .raw($0.value.raw)) } ?? []))
        case "start":
          if let screen {
            response = .bool(try await screen.start(seed: cmd["seed"]!.int!, at: cmd["at"]!.raw))
          } else {
            response = .bool(try await p!.start(seed: cmd["seed"]!.int!, at: cmd["at"]!.raw))
          }
        case "setMe":
          p!.room.setMe(cmd["fields"]!.members.map { ($0.key, .raw($0.value.raw)) })
          response = .bool(true)
        case "set":
          let doc = cmd["doc"]!.raw
          let result = try await p!.room.update(rider: cmd["with"]?.raw) { _ in doc }
          response = result.map(JS.raw) ?? .null
        case "send":
          response = .bool(
            p!.room.send(
              cmd["type"]!.string!,
              fields: cmd["fields"]?.members.map { ($0.key, .raw($0.value.raw)) } ?? []))
        case "request":
          response = .raw(
            try await p!.room.request(
              cmd["type"]!.string!,
              fields: cmd["fields"]?.members.map { ($0.key, .raw($0.value.raw)) } ?? []
            ).raw)
        case "events":
          response = .array((events[key] ?? []).map(JS.raw))
          events[key] = []
        case "take": response = .bool(try await p!.take(cmd["action"]!.raw))
        case "act":
          // `action` through the screen's own release path when there is a screen
          if let screen {
            try screen.act(cmd["action"]!.raw)
            try await eventually { !p!.pending && p!.sequence == screen.displayedSeqForProbe }
            response = .bool(true)
          } else {
            response = .bool(try await p!.take(cmd["action"]!.raw))
          }
        case "frame": response = try await p!.frame(cmd["input"]!.raw).map(JS.raw) ?? .null
        case "computer":
          // Plan on a throwaway native engine: only its action enters the real pitch.
          // Changing cpu on the planner never changes the playing engine's snapshot.
          let need = try JSONNode.parse(p!.need)
          var action: JSONText
          if need["kind"]?.string == "raise" {
            action = JS.object([("type", .string("raise"))]).json
          } else if need["kind"]?.string == "punish" {
            action =
              JS.object([
                ("type", .string("punish")), ("x", .number(need["cursor"]!["x"]!.double!)),
                ("y", .number(need["cursor"]!["y"]!.double!)),
              ]).json
          } else {
            let snap = try JSONNode.parse(p!.engine.call("snapshot"))
            let opts = snap["opts"]!
            let cpuOpts = JS.object(
              opts.members.filter { $0.key != "cpu" }.map { ($0.key, JS.raw($0.value.raw)) } + [
                ("cpu", .array([.string("A"), .string("B")]))
              ])
            let plannerSnap = JS.object(
              snap.members.map { ($0.key, $0.key == "opts" ? cpuOpts : JS.raw($0.value.raw)) })
            let planner = try Engine(minor: p!.engine.minor, appVersion: "0.0-test")
            _ = try planner.call("restore", json: plannerSnap.ascii)
            var planned: JSONText?
            for _ in 0..<2000 {
              let f = try JSONNode.parse(planner.call("frame", json: #"{"dt":0.1}"#))
              if let a = f["action"] {
                planned = a.raw
                break
              }
            }
            guard let planned else { throw RoomError("no-computer-action") }
            action = planned
          }
          let ok: Bool
          if let screen {
            try screen.act(action)
            ok = true
          } else {
            ok = try await p!.take(action)
          }
          response = .object([("ok", .bool(ok)), ("action", .raw(action))])
        case "plan":
          // A person's throw from a snapshot as the computer would plan it, on the
          // engine of `minor`, taken nowhere: the harness may move its stance.
          response = .raw(try planThrow(snap: cmd["snap"]!.string!, minor: cmd["minor"]!.string!))
        case "applyOn":
          // `action` applied to `snap` on a fresh engine of each of `minors`: the hash after.
          var out: [(String, JS)] = []
          for mm in cmd["minors"]!.items.compactMap(\.string) {
            let e = try Engine(minor: mm, appVersion: "0.0-test")
            _ = try e.call("restore", json: cmd["snap"]!.string!)
            _ = try e.call("apply", json: cmd["action"]!.raw.text)
            out.append((mm, .string(try e.hash())))
          }
          response = .object(out)
        case "report":
          let report = try screen!.captureReport(size: CGSize(width: 390, height: 844), scale: 3)
          try await p!.room.sendPitchReport(
            report.message(happened: "Synthetic throw", should: "Synthetic result"))
          response = .bool(true)
        case "rematch":
          try await screen!.rematch()
          response = .bool(true)
        case "dialThrow":
          guard let screen else { throw RoomError("no-screen") }
          let board = screen.board
          board.dismissHandoff()
          let dt = 1.0 / 60
          let back = ((board.dial.powerHi ?? 100) + (board.dial.powerLo ?? 80)) / 2
          let stop = ((board.dial.releaseHi ?? 48) + (board.dial.releaseLo ?? 32)) / 2
          func feed(_ deg: Double) throws {
            board.sample(CGPoint(x: sin(deg * .pi / 180), y: cos(deg * .pi / 180)))
            try screen.tick(dt)
          }
          try feed(0)
          var a = -5.0
          try feed(a)
          while a > -back {
            a = max(-back, a - 400 * dt)
            try feed(a)
          }
          while a < stop {
            a = min(stop, a + 2400 * dt)
            try feed(a)
          }
          board.sample(nil)
          try screen.tick(dt)
          response = .bool(board.playing)
        case "displayFrame":
          response = .bool(try screen!.tick(0.05))
        case "skip":
          try screen!.skip()
          response = .bool(true)
        case "background":
          screen!.background()
          response = .bool(true)
        case "foreground":
          screen!.connect()
          if p!.room.status == .connecting || p!.room.status == .reconnecting {
            try await p!.room.ready()
          }
          response = .bool(true)
        case "dismiss":
          screen!.board.dismissHandoff()
          response = .bool(true)
        case "option":
          try await screen!.option(cmd["name"]!.string!, cmd["value"]!.string!)
          response = .bool(true)
        case "tick":
          p!.tick(now: cmd["now"]!.int!)
          response = .bool(true)
        case "aim":
          try p!.castAim()
          response = .bool(true)
        case "shout":
          if let screen { screen.shout("NICE!") } else { p!.shout("NICE!") }
          response = .bool(true)
        case "leave":
          await p!.room.leave()
          p!.close()
          response = .bool(true)
        case "close":
          if let screen { screen.close() } else { p!.close() }
          response = .bool(true)
        default: throw RoomError("bad-op")
        }
        response = .object([("ok", .bool(true)), ("value", response)])
      } catch {
        response = .object([
          ("ok", .bool(false)), ("code", .string((error as? RoomError)?.code ?? "error")),
          ("error", .string(String(describing: error))),
        ])
      }
      FileHandle.standardOutput.write(Data((response.ascii + "\n").utf8))
    }
    for p in pitches.values { p.close() }
    for wire in wires.values { wire.close() }
  }
}

/// Plans the throw due in `snap` with a throwaway engine of `minor` that plays both sides.
@MainActor func planThrow(snap text: String, minor: String) throws -> JSONText {
  let snap = try JSONNode.parse(text)
  let opts = snap["opts"]!
  let cpuOpts = JS.object(
    opts.members.filter { $0.key != "cpu" }.map { ($0.key, JS.raw($0.value.raw)) } + [
      ("cpu", .array([.string("A"), .string("B")]))
    ])
  let plannerSnap = JS.object(
    snap.members.map { ($0.key, $0.key == "opts" ? cpuOpts : JS.raw($0.value.raw)) })
  let planner = try Engine(minor: minor, appVersion: "0.0-test")
  _ = try planner.call("restore", json: plannerSnap.ascii)
  for _ in 0..<2000 {
    let f = try JSONNode.parse(planner.call("frame", json: #"{"dt":0.1}"#))
    if let a = f["action"] { return a.raw }
  }
  throw RoomError("no-computer-action")
}

@MainActor func eventually(_ test: () -> Bool) async throws {
  for _ in 0..<2000 {
    if test() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw RoomError("probe-timeout")
}
