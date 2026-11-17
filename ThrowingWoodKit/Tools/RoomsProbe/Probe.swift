// Local test driver, not shipped in the app. JSON-lines RPC lets the Node harness
// exercise the public Swift client/controller over a real Foundation WebSocket.
import Foundation
import KubbEngine
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
        switch op {
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
          let engine = try Engine(appVersion: "0.0-test")
          var timing = RoomsClient.Timing()
          timing.retry = .milliseconds(10)
          timing.retryMax = .milliseconds(50)
          let room = try RoomsClient(
            url: url, room: cmd["room"]!.string!, engineVersion: engine.engineVersion,
            appVersion: "0.0-test", me: [("name", .string(key)), ("level", .string("pro"))],
            store: FixedID(cmd["member"]?.string), timing: timing)
          events[key] = []
          room.observe { event in
            if case .message(let node) = event { events[key, default: []].append(node.raw) }
          }
          let pitch = try PitchController(room: room, engine: engine)
          pitches[key] = pitch
          pitch.connect()
          try await room.ready()
          response = .string(room.you)
        case "state":
          let p = p!
          response = .object([
            ("state", .string(p.state.rawValue)), ("status", .string(p.room.status.rawValue)),
            ("you", .string(p.room.you)), ("host", p.room.host.map(JS.string) ?? .null),
            ("v", .int(p.room.version)), ("doc", .raw(p.room.document)),
            ("members", p.room.membersJSON), ("seq", .int(p.sequence)),
            ("hash", p.state == .match ? .string(try p.engine.hash()) : .null),
            ("applied", .int(p.applied)), ("corrections", .int(p.corrections)),
            ("adoptions", .int(p.adoptions)),
            ("mayAct", .bool(p.mayAct)), ("need", .raw(p.need)), ("control", .raw(p.control)),
            ("error", p.lastError.map(JS.string) ?? .null),
            ("mismatch", p.mismatch.map(JS.raw) ?? .null),
          ])
        case "team":
          try await p!.joinTeam(cmd["side"]?.string)
          response = .bool(true)
        case "reduce":
          response = .bool(
            try await p!.reduce(
              cmd["name"]!.string!,
              fields: cmd["fields"]?.members.map { ($0.key, .raw($0.value.raw)) } ?? []))
        case "start":
          response = .bool(try await p!.start(seed: cmd["seed"]!.int!, at: cmd["at"]!.raw))
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
            let planner = try Engine(appVersion: "0.0-test")
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
          let ok = try await p!.take(action)
          response = .object([("ok", .bool(ok)), ("action", .raw(action))])
        case "tick":
          p!.tick(now: cmd["now"]!.int!)
          response = .bool(true)
        case "aim":
          try p!.castAim()
          response = .bool(true)
        case "shout":
          p!.shout("NICE!")
          response = .bool(true)
        case "leave":
          await p!.room.leave()
          p!.close()
          response = .bool(true)
        case "close":
          p!.close()
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
