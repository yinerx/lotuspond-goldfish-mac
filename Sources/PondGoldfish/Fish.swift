import AppKit
import SpriteKit

/// One koi. The body is a single textured sprite bent every frame with an
/// `SKWarpGeometryGrid` that follows a chain of spine segments (head → tail).
/// The head is steered (wander + loose boids + edge avoidance + flee/curious);
/// the remaining spine points follow the leader with a joint-angle limit, and a
/// travelling wave proportional to swimming speed is added on top so the tail
/// beats faster when the fish swims faster.
final class Fish {
    enum State { case wander, pause, dart, flee, regroup, curious, inspect }

    static let columns = 8                   // spine segments
    static let rows = 2

    let body: SKSpriteNode
    let shadow: SKSpriteNode
    let finL: SKSpriteNode
    let finR: SKSpriteNode

    let length: Double          // canvas length in points (≈ fish length)
    let canvas: CGSize
    let segLen: Double
    let cruise: Double          // typical speed, points / s
    let depth: Double           // 0 = just under the surface, 1 = near the floor
    let speedSeed = rnd(0, 100)
    let speedFreq = rnd(0.05, 0.13)

    private(set) var spine: [V2]
    private var drawPts: [V2]
    private var normals: [V2]
    private let srcGrid: [SIMD2<Float>]

    var heading: Double
    var speed: Double
    var wanderHeading: Double
    var state: State = .wander
    var stateTime: Double = 0
    var nextPauseIn = rnd(6, 22)
    var threat = V2(0, 0)
    weak var interest: SKNode?
    var interestOffset = V2(0, 0)
    var wantsCurious = false
    var phase = rnd(0, 2 * Double.pi)
    var finPhase = rnd(0, 2 * Double.pi)
    var turnSignal: Double = 0

    var fade: Double = 0        // 0…1, for spawning / removal
    var removing = false

    /// Midpoint of the body, used for neighbour logic.
    var center: V2 { spine[Fish.columns / 2] }
    var head: V2 { spine[0] }

    init(textures t: FishTextures, length: Double, at p: V2, heading h: Double, cruise: Double, depth: Double) {
        self.length = length
        self.canvas = t.canvas
        self.segLen = Double(t.canvas.width) / Double(Fish.columns)
        self.cruise = cruise
        self.depth = depth
        self.heading = h
        self.wanderHeading = h
        self.speed = cruise * 0.6

        var sp: [V2] = []
        for k in 0...Fish.columns { sp.append(p - V2.dir(h) * (segLen * Double(k))) }
        spine = sp
        drawPts = sp
        normals = Array(repeating: V2(0, 1), count: Fish.columns + 1)

        var src: [SIMD2<Float>] = []
        for r in 0...Fish.rows {
            for c in 0...Fish.columns {
                src.append(SIMD2<Float>(Float(c) / Float(Fish.columns), Float(r) / Float(Fish.rows)))
            }
        }
        srcGrid = src

        body = SKSpriteNode(texture: t.body, size: t.canvas)
        body.subdivisionLevels = 2
        body.alpha = 0

        shadow = SKSpriteNode(texture: t.shadow, size: t.canvas)
        shadow.subdivisionLevels = 1
        shadow.alpha = 0
        shadow.color = .black
        shadow.colorBlendFactor = 1

        finL = SKSpriteNode(texture: t.fin, size: t.finSize)
        finL.anchorPoint = CGPoint(x: 0, y: 0.5)
        finL.zPosition = -0.004
        finR = SKSpriteNode(texture: t.fin, size: t.finSize)
        finR.anchorPoint = CGPoint(x: 0, y: 0.5)
        finR.yScale = -1
        finR.zPosition = -0.004
        body.addChild(finL)
        body.addChild(finR)
    }

    func removeNodes() {
        body.removeFromParent()
        shadow.removeFromParent()
    }

    // MARK: - Events

    func startle(from p: V2, distance d: Double, radius: Double, interest node: SKNode?) {
        threat = p
        state = .flee
        stateTime = rnd(0.8, 1.5) * (1.1 - 0.4 * d / radius)
        interest = node
        wantsCurious = node != nil && chance(0.8)
        interestOffset = V2.dir(rnd(0, 2 * Double.pi)) * (length * rnd(0.55, 1.1))
    }

    func nudgeAway(from p: V2) {
        if state == .wander || state == .pause {
            wanderHeading = (center - p).angle + rnd(-0.6, 0.6)
            state = .wander
        }
    }

    // MARK: - Steering

    func think(dt: Double, time: Double, school: [Fish], bounds: V2, margin: Double) {
        stateTime -= dt
        var desired = V2.dir(wanderHeading)
        var targetSpeed = cruise * (0.78 + 0.32 * sin(time * speedFreq * 2 * Double.pi + speedSeed))
        var turnRate = 1.5
        var accel = 1.6
        var social = 1.0

        switch state {
        case .wander:
            wanderHeading += rndNormal() * 1.1 * sqrt(dt)
            nextPauseIn -= dt
            if nextPauseIn <= 0 {
                if chance(0.55) {
                    state = .pause; stateTime = rnd(1.0, 3.2)
                } else {
                    beginDart()
                }
            }
        case .pause:
            targetSpeed = cruise * 0.06
            turnRate = 0.35
            accel = 1.2
            if stateTime <= 0 { beginDart() }
        case .dart:
            targetSpeed = cruise * 3.0
            turnRate = 3.2
            accel = 5
            if stateTime <= 0 {
                state = .wander
                nextPauseIn = rnd(8, 26)
            }
        case .flee:
            desired = (center - threat).normalized
            if desired.len < 0.5 { desired = V2.dir(heading) }
            targetSpeed = cruise * 4.6
            turnRate = 6.5
            accel = 7
            social = 0.2
            if stateTime <= 0 {
                state = .regroup
                stateTime = rnd(1.2, 2.6)
                wanderHeading = heading
            }
        case .regroup:
            targetSpeed = cruise * 0.55
            accel = 1.2
            if stateTime <= 0 {
                if wantsCurious, let n = interest, n.parent != nil {
                    state = .curious
                    stateTime = 30
                } else {
                    state = .wander
                    interest = nil
                }
            }
        case .curious:
            guard let n = interest, n.parent != nil, stateTime > 0 else {
                state = .wander; interest = nil; break
            }
            let target = n.position.v2 + interestOffset
            let to = target - head
            let d = to.len
            desired = to.normalized
            targetSpeed = cruise * clampD(d / (length * 2.5), 0.22, 1.5)
            turnRate = 2.2
            if d < length * 0.35 {
                state = .inspect
                stateTime = rnd(3, 6.5)
            }
        case .inspect:
            guard let n = interest, n.parent != nil, stateTime > 0 else {
                state = .wander
                interest = nil
                wanderHeading = heading + (chance(0.5) ? 1 : -1) * rnd(1.2, 2.6)
                nextPauseIn = rnd(8, 20)
                break
            }
            // Nose around the object: hover, turning slowly towards it.
            let to = n.position.v2 - head
            desired = to.normalized
            targetSpeed = cruise * (0.06 + 0.08 * max(0, sin(time * 2.3 + speedSeed)))
            turnRate = 1.1
            accel = 2
            social = 0.6
        }

        // Loose boids: separation (strong), alignment & cohesion (weak).
        if social > 0 {
            var sep = V2(0, 0), ali = V2(0, 0), coh = V2(0, 0)
            var n = 0.0
            let sepR = length * 1.1
            let viewR = length * 4.0
            let c = center
            for o in school where o !== self && !o.removing {
                let d = c - o.center
                let dist = d.len
                if dist < 1e-3 { continue }
                if dist < sepR { sep += d / dist * (1 - dist / sepR) }
                if dist < viewR {
                    ali += V2.dir(o.heading)
                    coh += o.center
                    n += 1
                }
            }
            desired += sep * 1.8 * social
            if n > 0, state == .wander || state == .regroup {
                desired += ali.normalized * 0.22 * social
                desired += (coh / n - c).normalized * 0.12 * social
            }
        }

        // Edge avoidance (soft wall), stronger the closer we are.
        let p = head
        var e = V2(0, 0)
        if p.x < margin { e.x += (margin - p.x) / margin }
        if p.x > bounds.x - margin { e.x -= (p.x - (bounds.x - margin)) / margin }
        if p.y < margin { e.y += (margin - p.y) / margin }
        if p.y > bounds.y - margin { e.y -= (p.y - (bounds.y - margin)) / margin }
        if e.len > 0 {
            desired += e * 3.0
            if state == .wander || state == .regroup || state == .pause {
                let k = min(1, dt * 2.5 * e.len)
                wanderHeading += wrapAngle(desired.angle - wanderHeading) * k
            }
        }

        // Turn towards the desired heading with a speed-dependent turn rate.
        let diff = wrapAngle(desired.angle - heading)
        let maxTurn = turnRate * dt * (0.45 + 0.55 * min(speed / cruise, 2.0))
        let turn = clampD(diff, -maxTurn, maxTurn)
        heading = wrapAngle(heading + turn)
        turnSignal = lerp(turnSignal, turn / max(dt, 1e-4), min(1, dt * 6))
        speed += (targetSpeed - speed) * min(1, dt * accel)

        // Integrate the head and drag the spine behind it.
        spine[0] = head + V2.dir(heading) * (speed * dt)
        // Hard keep-in (allow the tail to leave the screen a bit).
        spine[0].x = clampD(spine[0].x, -length * 0.4, bounds.x + length * 0.4)
        spine[0].y = clampD(spine[0].y, -length * 0.4, bounds.y + length * 0.4)
        followSpine()

        // Tail beat frequency follows speed; pectoral fins paddle when slow.
        let sn = speed / cruise
        phase += dt * (2.2 + 5.5 * min(sn, 3.5))
        finPhase += dt * (2.5 + 3.0 * max(0, 1 - sn))
    }

    private func beginDart() {
        state = .dart
        stateTime = rnd(0.35, 0.8)
        wanderHeading = heading + rnd(-1.3, 1.3)
    }

    private func followSpine() {
        let maxBend = 0.42
        for k in 1...Fish.columns {
            var d = spine[k - 1] - spine[k]
            var l = d.len
            if l < 1e-6 { d = V2.dir(heading); l = 1 }
            var dir = d / l
            if k >= 2 {
                let prev = (spine[k - 2] - spine[k - 1]).normalized
                let a = wrapAngle(dir.angle - prev.angle)
                if abs(a) > maxBend {
                    dir = V2.dir(prev.angle + (a > 0 ? maxBend : -maxBend))
                }
            } else {
                // first joint is limited relative to the heading
                let a = wrapAngle(dir.angle - heading)
                if abs(a) > maxBend { dir = V2.dir(heading + (a > 0 ? maxBend : -maxBend)) }
            }
            spine[k] = spine[k - 1] - dir * segLen
        }
    }

    // MARK: - Rendering

    /// - Parameters:
    ///   - shadowOffset: displacement of the drop shadow on the pond floor for this fish.
    func render(dt: Double, shadowOffset: V2, shadowAlpha: Double, tint: NSColor, tintAmount: Double) {
        if removing { fade = max(0, fade - dt / 1.6) } else { fade = min(1, fade + dt / 2.0) }

        let C = Fish.columns
        let sn = min(speed / cruise, 3.5)
        let amp = length * (0.028 + 0.030 * min(sn, 2.0)) + abs(turnSignal) * length * 0.01
        for k in 0...C {
            let tangent: V2
            if k == 0 { tangent = (spine[0] - spine[1]).normalized }
            else if k == C { tangent = (spine[C - 1] - spine[C]).normalized }
            else { tangent = (spine[k - 1] - spine[k + 1]).normalized }
            let n = tangent.perp
            let s = Double(k) / Double(C)                  // 0 head … 1 tail
            let off = amp * pow(s, 1.7) * sin(phase - s * 4.6)
            drawPts[k] = spine[k] + n * off
            normals[k] = n
        }

        let mid = (drawPts[0] + drawPts[C]) * 0.5
        var axis = drawPts[0] - drawPts[C]
        if axis.len < 1e-3 { axis = V2.dir(heading) }
        let ang = axis.angle
        let cw = Double(canvas.width), ch = Double(canvas.height)

        var dst: [SIMD2<Float>] = []
        dst.reserveCapacity((C + 1) * (Fish.rows + 1))
        for r in 0...Fish.rows {
            let v = Double(r) / Double(Fish.rows) - 0.5
            for c in 0...C {
                let k = C - c                               // texture u = 0 is the tail
                let w = drawPts[k] + normals[k] * (v * ch)
                let l = (w - mid).rotated(-ang)
                dst.append(SIMD2<Float>(Float(l.x / cw + 0.5), Float(l.y / ch + 0.5)))
            }
        }
        let grid = SKWarpGeometryGrid(columns: C, rows: Fish.rows, sourcePositions: srcGrid, destinationPositions: dst)

        body.position = mid.cg
        body.zRotation = CGFloat(ang)
        body.warpGeometry = grid
        body.alpha = CGFloat(fade)
        body.color = tint
        body.colorBlendFactor = CGFloat(tintAmount)

        shadow.position = (mid + shadowOffset).cg
        shadow.zRotation = CGFloat(ang)
        shadow.warpGeometry = grid
        shadow.alpha = CGFloat(shadowAlpha * fade)

        // Pectoral fins at ~25% from the front of the canvas.
        let kf = 2
        let rootW = drawPts[kf]
        let tangent = (drawPts[kf - 1] - drawPts[kf + 1]).normalized
        let localAng = tangent.angle - ang
        let half = length * 0.085
        let flapSlow = 0.62 + 0.32 * sin(finPhase)
        let tucked = 1.25
        let back = lerp(flapSlow, tucked, clampD(sn - 0.9, 0, 1))
        let turnBias = clampD(turnSignal * 0.25, -0.35, 0.35)
        let lp = (rootW + normals[kf] * half - mid).rotated(-ang)
        let rp = (rootW - normals[kf] * half - mid).rotated(-ang)
        finL.position = lp.cg
        finR.position = rp.cg
        finL.zRotation = CGFloat(localAng + Double.pi / 2 + back - turnBias)
        finR.zRotation = CGFloat(localAng - Double.pi / 2 - back - turnBias)
    }
}
