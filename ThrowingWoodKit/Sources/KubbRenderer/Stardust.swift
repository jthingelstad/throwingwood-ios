import CoreGraphics
import Foundation
import simd

/// The particles a scene adds to a throw (the web's src/render/stardust.js):
/// driven only by what the engine already hands the renderer (the recording's
/// projectile and timeline, and each shown frame's poses). No engine calls,
/// nothing fed back: a look only.
///
/// What makes dust: a trail behind the thrown piece (by distance travelled, so
/// the frame rate does not change it); a kubb that spins sheds dust off its two
/// ends; a puff where two pieces first meet, sized by the contact's strength; a
/// small one where the baton first lands and where a thrown kubb bounces; and
/// when the king falls, a ring along the ground, a fountain and a flash.
struct DustConfig {
  var cap: Int
  var colors: [Int]
  var dust = [0, 1, 2, 3], king = [4, 5, 6, 7]
  var gravity, drag: Double
  var trailFrom = 1.2, trailEvery: Double, trailMax: Int, trailLife, trailSize: Double
  var spinFrom = 4.0, spinRate: Double, spinMax: Int, spinLife, spinSize: Double
  var hitCount, hitExtra, knockCount, knockExtra, groundCount: Int
  var puffLife, puffSize: Double
  var kingRing, kingFountain: Int
  var kingLife, flashFor, flashSize, flashAlpha: Double
  var flashColor: Int
  var hitFlashColor: Int? = nil
  var hitFlash = 0.0

  /// The night's stardust; `reduced` (Reduce Motion): no trail, a little spin
  /// dust, small short puffs.
  static func night(reduced: Bool) -> DustConfig {
    var c = DustConfig(
      cap: 900,
      colors: [0xfff3cf, 0xffd56a, 0xffe9a8, 0xbfefff, 0xffe17a, 0xfff2c0, 0xffb938, 0xffffff],
      gravity: 0.9, drag: 1.6, trailEvery: 0.028, trailMax: 16, trailLife: 0.8, trailSize: 0.011,
      spinRate: 6.5, spinMax: 16, spinLife: 0.75, spinSize: 0.011, hitCount: 10, hitExtra: 24,
      knockCount: 5, knockExtra: 12, groundCount: 6, puffLife: 0.9, puffSize: 0.012,
      kingRing: 56, kingFountain: 40, kingLife: 1.5, flashFor: 0.7, flashSize: 0.8,
      flashAlpha: 0.55, flashColor: 0xffe17a)
    if reduced {
      c.trailEvery = 0
      c.spinRate = 0.6
      c.spinLife = 0.3
      (c.hitCount, c.hitExtra, c.knockCount, c.knockExtra, c.groundCount) = (6, 6, 2, 3, 2)
      c.puffLife = 0.4
      (c.kingRing, c.kingFountain, c.kingLife, c.flashAlpha) = (16, 0, 0.7, 0.25)
    }
    return c
  }

  /// The neon's sparks: no trail (the ribbon is the trail), no spin dust, a
  /// flash where the baton hits.
  static func neon(reduced: Bool) -> DustConfig {
    var c = DustConfig(
      cap: 600,
      colors: [0xffffff, 0xc8fdff, 0x8ff4ff, 0xffe4f0, 0xff5c9d, 0xff9cc4, 0xffffff, 0xffc94a],
      gravity: 2.4, drag: 2.6, trailEvery: 0, trailMax: 0, trailLife: 0, trailSize: 0,
      spinRate: 0, spinMax: 0, spinLife: 0, spinSize: 0, hitCount: 8, hitExtra: 18,
      knockCount: 3, knockExtra: 8, groundCount: 3, puffLife: 0.5, puffSize: 0.009,
      kingRing: 64, kingFountain: 28, kingLife: 1.3, flashFor: 0.35, flashSize: 0.9,
      flashAlpha: 0.7, flashColor: Neon.kingLit, hitFlashColor: 0xc8fdff, hitFlash: 0.45)
    if reduced {
      (c.hitCount, c.hitExtra, c.knockCount, c.knockExtra, c.groundCount) = (4, 4, 1, 2, 1)
      c.puffLife = 0.3
      (c.kingRing, c.kingFountain, c.kingLife, c.flashAlpha, c.hitFlash) = (16, 0, 0.7, 0.25, 0)
    }
    return c
  }
}

/// mulberry32, as the web's: the same throw sheds the same dust.
struct Mulberry {
  var a: UInt32
  init(_ seed: UInt32) { a = seed == 0 ? 1 : seed }
  mutating func next() -> Double {
    a = a &+ 0x6d2b_79f5
    var t = a
    t = (t ^ (t >> 15)) &* (t | 1)
    t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
    return Double(t ^ (t >> 14)) / 4_294_967_296
  }
}

/// A fixed pool (`cap` particles): nothing is allocated per frame, and a full
/// pool drops new dust rather than old.
struct Stardust {
  struct Particle {
    var x, y, z, vx, vy, vz, age, life, size: Double
    var col: Int
  }
  let cfg: DustConfig
  private(set) var live: [Particle] = []
  private var rng = Mulberry(7)
  private(set) var pid: String?, pkind: String?
  private var contacts: [Recording.Contact] = []
  private var ci = 0
  private var kingT: Double?, kingDone = false
  private var landT: Double?, landS = 0.0
  private var lastT: Double?
  private var prev = [Double](repeating: 0, count: 9)
  private var prevVz = 0.0, hasPrev = false
  private var spinAcc = 0.0, trailAcc = 0.0, bounced = 0
  private var flash = V3(0, 0, 0), flashAge = -1.0, flashScale = 1.0, flashColor = 0
  private(set) var byId: [String: Piece] = [:]
  private(set) var peak = 0

  init(_ cfg: DustConfig) {
    self.cfg = cfg
    live.reserveCapacity(cfg.cap)
  }

  /// True while anything is still to be drawn.
  var active: Bool { !live.isEmpty || flashAge >= 0 }

  mutating func clear() {
    live.removeAll(keepingCapacity: true)
    flashAge = -1
    pid = nil
    contacts = []
    hasPrev = false
  }

  mutating func watch(_ rec: Recording) {
    pid = rec.projectile.id
    pkind = rec.items.first { $0.id == rec.projectile.id }?.kind
    contacts = (rec.timeline.contacts ?? []).sorted { $0.t < $1.t }
    ci = 0
    kingT = rec.timeline.bursts.first { $0.kind == "king" }?.start
    kingDone = false
    landT = rec.timeline.batonLanding?.t
    landS = rec.timeline.batonLanding?.strength ?? 0
    lastT = nil
    hasPrev = false
    spinAcc = 0
    trailAcc = 0
    bounced = 0
    rng = Mulberry(UInt32(truncatingIfNeeded: Int((rec.duration * 1000).rounded()) + 13))
  }

  private mutating func spawn(
    _ x: Double, _ y: Double, _ z: Double, _ vx: Double, _ vy: Double, _ vz: Double,
    _ life: Double, _ size: Double, _ col: Int
  ) {
    guard live.count < cfg.cap else { return }
    live.append(
      Particle(x: x, y: y, z: z, vx: vx, vy: vy, vz: vz, age: 0, life: life, size: size, col: col))
    peak = max(peak, live.count)
  }

  /// A burst of n particles: speeds round `speed`, lifted by `up`, flattened
  /// toward the ground by `flat` (0 a sphere, 1 a disc).
  private mutating func puff(
    _ x: Double, _ y: Double, _ z: Double, _ n: Int, _ speed: Double, _ up: Double,
    _ flat: Double, _ life: Double, _ size: Double, _ cols: [Int]
  ) {
    guard n > 0 else { return }
    for _ in 0..<n {
      let a = rng.next() * .pi * 2
      let e = (rng.next() * 2 - 1) * (1 - flat)
      let c = (1 - e * e).squareRoot()
      let s = speed * (0.35 + rng.next() * 0.9)
      let vz = e * s + up * (0.4 + rng.next())
      let l = life * (0.6 + rng.next() * 0.7)
      let sz = size * (0.6 + rng.next() * 0.8)
      let col = cols[Int(rng.next() * Double(cols.count))]
      spawn(x, y, z, cos(a) * c * s, sin(a) * c * s, vz, l, sz, col)
    }
  }

  /// A playback frame at shown time t: emit, then step by the shown time since the last.
  mutating func observe(_ items: [Piece], _ t: Double) {
    let dt = lastT.map { t - $0 } ?? 0
    lastT = t
    byId.removeAll(keepingCapacity: true)
    for it in items { byId[it.id] = it }
    let D = cfg.dust
    let p = pid.flatMap { byId[$0] }
    if let p {
      let hz = pkind == "baton" ? 0.15 : 0.075
      let ax = 2 * (p.qx * p.qz + p.qw * p.qy)
      let ay = 2 * (p.qy * p.qz - p.qw * p.qx)
      let az = 1 - 2 * (p.qx * p.qx + p.qy * p.qy)
      let e1 = V3(p.x + ax * hz, p.y + ay * hz, p.z + az * hz)
      let e2 = V3(p.x - ax * hz, p.y - ay * hz, p.z - az * hz)
      let P = prev
      if hasPrev && dt > 1e-4 && dt < 0.25 {
        let vx = (p.x - P[0]) / dt
        let vy = (p.y - P[1]) / dt
        let vz = (p.z - P[2]) / dt
        let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
        if speed > cfg.trailFrom && cfg.trailEvery > 0 {
          trailAcc += speed * dt / cfg.trailEvery
          let m = min(cfg.trailMax, Int(trailAcc))
          trailAcc -= trailAcc.rounded(.towardZero)
          for k in 0..<max(0, m) {
            let u = (Double(k) + rng.next()) / Double(max(1, m))
            let x = P[0] + (p.x - P[0]) * u + (rng.next() - 0.5) * 0.03
            let y = P[1] + (p.y - P[1]) * u + (rng.next() - 0.5) * 0.03
            let z = P[2] + (p.z - P[2]) * u + (rng.next() - 0.5) * 0.03
            let wx = vx * 0.04 + (rng.next() - 0.5) * 0.25
            let wy = vy * 0.04 + (rng.next() - 0.5) * 0.25
            let wz = vz * 0.04 + (rng.next() - 0.5) * 0.2
            let life = cfg.trailLife * (0.6 + rng.next() * 0.6)
            let size = cfg.trailSize * (0.6 + rng.next() * 0.8)
            spawn(x, y, z, wx, wy, wz, life, size, D[Int(rng.next() * 4)])
          }
        }
        if pkind == "kubb" && cfg.spinRate > 0 {
          let t1 = (e1 - V3(P[3], P[4], P[5])) / dt - V3(vx, vy, vz)
          let t2 = (e2 - V3(P[6], P[7], P[8])) / dt - V3(vx, vy, vz)
          let tang = (simd_length(t1) + simd_length(t2)) / 2
          let omega = tang / hz
          if omega > cfg.spinFrom && p.z > 0.04 {
            spinAcc += omega * cfg.spinRate * dt
            let m = min(cfg.spinMax, Int(spinAcc))
            spinAcc -= spinAcc.rounded(.towardZero)
            for k in 0..<max(0, m) {
              let end = k & 1 == 1
              let e = end ? e2 : e1
              let tv = end ? t2 : t1
              let fling = 0.55 + rng.next() * 0.5
              let wx = vx * 0.3 + tv.x * fling + (rng.next() - 0.5) * 0.3
              let wy = vy * 0.3 + tv.y * fling + (rng.next() - 0.5) * 0.3
              let wz = vz * 0.3 + tv.z * fling + (rng.next() - 0.5) * 0.3
              let life = cfg.spinLife * (0.6 + rng.next() * 0.7)
              let size = cfg.spinSize * (0.6 + rng.next() * 0.8)
              spawn(e.x, e.y, e.z, wx, wy, wz, life, size, D[Int(rng.next() * 4)])
            }
          }
          // a thrown kubb that strikes the ground: falling fast, now not
          if bounced < 3 && prevVz < -1.2 && vz > prevVz + 1.2 && p.z < 0.14 {
            bounced += 1
            puff(
              p.x, p.y, 0.02, cfg.groundCount + Int((-prevVz * 2).rounded()), 0.6, 0.25, 0.75,
              cfg.puffLife * 0.8, cfg.puffSize * 0.8, D)
          }
        }
        prevVz = vz
      }
      prev = [p.x, p.y, p.z, e1.x, e1.y, e1.z, e2.x, e2.y, e2.z]
      hasPrev = true
    }
    // the contacts, once each as the picture reaches them
    while ci < contacts.count && contacts[ci].t <= t {
      let c = contacts[ci]
      ci += 1
      guard let a = byId[c.idA], let b = byId[c.idB] else { continue }
      if c.a == "stake" || c.b == "stake" { continue }
      let s = max(0, min(1, c.strength))
      let baton = c.a == "baton" || c.b == "baton"
      let king = c.a == "king" || c.b == "king"
      let n =
        baton
        ? cfg.hitCount + Int((Double(cfg.hitExtra) * s).rounded())
        : cfg.knockCount + Int((Double(cfg.knockExtra) * s).rounded())
      guard n > 0 else { continue }
      puff(
        (a.x + b.x) / 2, (a.y + b.y) / 2, max(0.03, (a.z + b.z) / 2), n,
        (baton ? 1.1 : 0.7) * (0.6 + s), 0.25, 0.15, cfg.puffLife,
        cfg.puffSize * (baton ? 1 : 0.8), king ? cfg.king : D)
      if baton && cfg.hitFlash > 0 && flashAge < 0 {
        flash = V3((a.x + b.x) / 2, (a.y + b.y) / 2, max(0.05, (a.z + b.z) / 2))
        flashAge = 0
        flashScale = cfg.hitFlash * (0.6 + 0.4 * s)
        flashColor = cfg.hitFlashColor ?? cfg.flashColor
      }
    }
    if let land = landT, land <= t {
      landT = nil
      if let p, cfg.groundCount > 0 {
        puff(
          p.x, p.y, 0.02, cfg.groundCount + Int((8 * landS).rounded()), 0.5, 0.2, 0.8,
          cfg.puffLife * 0.7, cfg.puffSize * 0.7, D)
      }
    }
    if let kt = kingT, !kingDone, t >= kt {
      kingDone = true
      if let k = items.last(where: { $0.kind == "king" }) {
        for i in 0..<cfg.kingRing {
          let a = Double(i) / Double(cfg.kingRing) * .pi * 2 + rng.next() * 0.2
          let s = 1.5 + rng.next() * 0.9
          let vz = 0.15 + rng.next() * 0.3
          let life = cfg.kingLife * (0.7 + rng.next() * 0.5)
          spawn(
            k.x, k.y, 0.03, cos(a) * s, sin(a) * s, vz, life, cfg.puffSize * 1.1,
            cfg.king[Int(rng.next() * 4)])
        }
        puff(
          k.x, k.y, max(0.05, k.z), cfg.kingFountain, 0.55, 2.6, 0, cfg.kingLife,
          cfg.puffSize * 1.2, cfg.king)
        flash = V3(k.x, k.y, max(0.1, k.z))
        flashAge = 0
        flashScale = 1
        flashColor = cfg.flashColor
      }
    }
    tick(max(0, min(0.1, dt)))
  }

  mutating func tick(_ dt: Double) {
    guard dt > 0 else { return }
    let g = cfg.gravity
    let drag = exp(-cfg.drag * dt)
    if flashAge >= 0 {
      flashAge += dt
      if flashAge > cfg.flashFor { flashAge = -1 }
    }
    var i = 0
    while i < live.count {
      live[i].age += dt
      if live[i].age >= live[i].life {
        live.swapAt(i, live.count - 1)
        live.removeLast()
        continue
      }
      live[i].vx *= drag
      live[i].vy *= drag
      live[i].vz = live[i].vz * drag - g * dt
      live[i].x += live[i].vx * dt
      live[i].y += live[i].vy * dt
      var z = live[i].z + live[i].vz * dt
      if z < 0.005 {
        z = 0.005
        live[i].vz *= -0.25
      }
      live[i].z = z
      i += 1
    }
  }

  /// After the pieces, added, so it brightens what is under it and never hides it.
  func draw(_ ctx: CGContext, _ projection: PitchProjection) {
    guard active else { return }
    let unit = projection.k * projection.c.f
    ctx.saveGState()
    ctx.setBlendMode(.plusLighter)
    if flashAge >= 0 {
      let v = projection.view(flash)
      if v.z > 0.05 {
        let s = unit / v.z
        let u = flashAge / cfg.flashFor
        let r = cfg.flashSize * flashScale * (0.5 + u) * s
        let q = projection.screen(v)
        Glow.draw(ctx, q.x, q.y, r, r, flashColor, cfg.flashAlpha * (1 - u) * (1 - u))
      }
    }
    for (i, d) in live.enumerated() {
      let v = projection.view(V3(d.x, d.y, d.z))
      guard v.z >= 0.05 else { continue }
      let s = unit / v.z
      let q = projection.screen(v)
      let u = d.age / d.life
      // in fast, out slow; a twinkle on the way out
      let a = (u < 0.08 ? u / 0.08 : (1 - u) * (1 - u)) * (0.75 + 0.25 * sin(Double(i) * 1.7 + d.age * 25))
      let r = max(0.7, d.size * s)
      Glow.draw(ctx, q.x, q.y, r, r, cfg.colors[d.col], a, core: true)
    }
    ctx.restoreGState()
  }
}
