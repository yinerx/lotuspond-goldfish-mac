import AppKit
import SpriteKit

/// Something resting on the water surface (falling leaf / petal) with its floor shadow.
final class Floater {
    enum Kind { case leaf, petal }
    let kind: Kind
    let node: SKSpriteNode
    let shadow: SKSpriteNode
    var start: V2
    var land: V2
    var fallT: Double = 0
    let fallDuration: Double
    var landed = false
    var vel: V2
    var spin: Double
    var age: Double = 0
    let life: Double
    var swayPhase = rnd(0, 6.28)
    let baseScale: Double
    /// Where it is: still falling, floating on the water, resting on a lily pad, or
    /// sliding off a pad's edge into the water.
    enum Place { case falling, water, pad, sliding }
    var place: Place = .falling
    var size: Double = 30
    var slideFrom = V2(0, 0)
    var slideTo = V2(0, 0)
    var slideT = 0.0

    init(kind: Kind, node: SKSpriteNode, shadow: SKSpriteNode, start: V2, land: V2, vel: V2, spin: Double, life: Double, fall: Double, baseScale: Double) {
        self.kind = kind; self.node = node; self.shadow = shadow
        self.start = start; self.land = land; self.vel = vel; self.spin = spin
        self.life = life; self.fallDuration = fall; self.baseScale = baseScale
    }
}

/// A static or slowly drifting surface item that casts a shadow on the floor.
private struct SurfaceItem {
    let node: SKNode
    let shadow: SKSpriteNode
    var vel: V2
    let wraps: Bool
    let radius: Double
}

final class PondScene: SKScene {

    /// Window mode: clicks make ripples. Wallpaper mode: never receives events.
    var interactive = false

    private let settings = PondSettings.shared
    private let bank = TextureBank.shared
    private var built = false
    private var lastTime: TimeInterval = 0
    private var elapsed: Double = 0
    private var ws: Double = 1                   // world scale (sizes relative to a 900pt tall screen)

    // Layers (ignoresSiblingOrder = true, so zPosition decides draw order)
    private let floorLayer = SKNode()
    private let shadowLayer = SKNode()
    private let hazeLayer = SKNode()
    private let fishLayer = SKNode()
    private let glintLayer = SKNode()
    private let padShadowLayer = SKNode()     // long soft shadow of all pads (water/floor/fish)
    private let surfaceLayer = SKNode()       // on the water: duckweed, ripples, floating leaves
    private let padLayer = SKNode()           // all lily pads, flattened into one sprite
    private let onPadLayer = SKNode()         // leaves / petals resting on pads
    private let flowerShadowLayer = SKNode()
    private let flowerLayer = SKNode()
    private let fallingLayer = SKNode()       // leaves / petals still in the air
    private let rainLayer = SKNode()
    private let ambientLayer = SKNode()

    private var floorSprite: SKSpriteNode?
    private var hazeSprite: SKSpriteNode?
    private var glintSprite: SKSpriteNode?
    private var ambientSprite: SKSpriteNode?
    private let floorShader = Shaders.makeFloor()
    private let hazeShader = Shaders.makeHaze()
    private let glintShader = Shaders.makeGlint()

    private var fish: [Fish] = []
    private var floaters: [Floater] = []
    private var surfaceItems: [SurfaceItem] = []
    private var rainEmitter: SKEmitterNode?
    private var rainAccumulator = 0.0
    private var nextLeaf = 0.0
    private var nextPetal = 0.0
    private var light = LightState()
    private var targetLight = LightState()
    private var lightClock = 0.0
    private var spawnClock = 0.0
    private var rebuildPending = false

    // Lily pads & lotus (see LilyArt.swift)
    private var padSprite: SKSpriteNode?
    private var padShadowSprite: SKSpriteNode?
    private var padShadowMargin = 0.0
    private var padFade = 0.0
    private var flowerItems: [(node: SKSpriteNode, shadow: SKSpriteNode)] = []
    private var padHits: [(c: V2, r: Double)] = []      // largest first = lowest
    private var openCenter = V2(0, 0)
    private var padGeneration = 0
    private var builtDensity = -1.0

    override init(size: CGSize) {
        super.init(size: size)
        anchorPoint = .zero
        backgroundColor = NSColor(srgbRed: 0.1, green: 0.35, blue: 0.32, alpha: 1)
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        if !built && size.width > 2 && size.height > 2 { build() }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width > 2, size.height > 2 else { return }
        if !built {
            if view != nil { build() }
            return
        }
        // Stretch immediately, repaint the floor once resizing settles.
        floorSprite?.size = size
        hazeSprite?.size = size
        glintSprite?.size = size
        ambientSprite?.size = size
        removeAction(forKey: "rebuild")
        run(.sequence([.wait(forDuration: 0.6), .run { [weak self] in self?.relayout() }]), withKey: "rebuild")
    }

    /// Rebuilds size-dependent art while keeping the fish swimming.
    private func relayout() {
        guard built else { return }
        let oldFish = fish
        buildStaticArt()
        let b = V2(Double(size.width), Double(size.height))
        for f in oldFish where f.head.x > b.x || f.head.y > b.y {
            f.removing = true
        }
    }

    private func build() {
        built = true
        removeAllChildren()
        // floor → fish shadows → water tint → fish → glint → pad shadow → water surface
        // (ripples, duckweed, floating leaves) → pads → things on pads → flower shadows
        // → flowers → falling leaves → rain → day/night grading (multiply, everything).
        let layers: [(SKNode, CGFloat)] = [
            (floorLayer, 0), (shadowLayer, 5), (hazeLayer, 8), (fishLayer, 10), (glintLayer, 25),
            (padShadowLayer, 27), (surfaceLayer, 28), (padLayer, 30), (onPadLayer, 30.5),
            (flowerShadowLayer, 31), (flowerLayer, 32), (fallingLayer, 40), (rainLayer, 60), (ambientLayer, 100)
        ]
        for (n, z) in layers {
            n.zPosition = z
            addChild(n)
        }
        buildStaticArt()
        light = currentTargetLight()
        targetLight = light
        nextLeaf = rnd(4, 10)
        nextPetal = rnd(8, 16)
        for _ in 0..<settings.fishTarget { spawnFish(initial: true) }
    }

    /// Floor, haze, surface decor, rain emitter — everything depending on the scene size.
    private func buildStaticArt() {
        let W = Double(size.width), H = Double(size.height)
        ws = clampD(min(W, H) / 900.0, 0.55, 2.4)

        floorLayer.removeAllChildren()
        hazeLayer.removeAllChildren()
        glintLayer.removeAllChildren()
        ambientLayer.removeAllChildren()
        rainLayer.removeAllChildren()
        for item in surfaceItems { item.node.removeFromParent(); item.shadow.removeFromParent() }
        surfaceItems.removeAll()

        let layout = PondLayout(width: W, height: H, ws: ws)

        let floor = SKSpriteNode(texture: PondArt.floor(layout: layout, ws: ws), size: size)
        floor.anchorPoint = .zero
        floor.shader = floorShader
        floorLayer.addChild(floor)
        floorSprite = floor
        let causticCell = 420.0 * ws
        floorShader.setVec2("u_scale", SIMD2<Float>(Float(W / causticCell), Float(H / causticCell)))
        floorShader.setFloat("u_wobble", 0.0011)

        let haze = SKSpriteNode(texture: PondArt.depthMap(layout: layout), size: size)
        haze.anchorPoint = .zero
        haze.shader = hazeShader
        hazeLayer.addChild(haze)
        hazeSprite = haze

        let glint = SKSpriteNode(texture: bank.white, size: size)
        glint.anchorPoint = .zero
        glint.blendMode = .add
        glint.shader = glintShader
        glintLayer.addChild(glint)
        glintSprite = glint
        let gc = 260.0 * ws
        glintShader.setVec2("u_scale", SIMD2<Float>(Float(W / gc), Float(H / gc)))

        let amb = SKSpriteNode(color: .white, size: size)
        amb.anchorPoint = .zero
        amb.blendMode = .multiply
        ambientLayer.addChild(amb)
        ambientSprite = amb

        buildPads(W: W, H: H)
        buildDuckweed(W: W, H: H)
        buildRain(W: W, H: H)
    }

    private func addSurfaceItem(_ node: SKNode, shadowSize: CGSize, shadowTexture: SKTexture, z: CGFloat, vel: V2 = V2(0, 0), wraps: Bool = false, radius: Double) {
        node.zPosition = z
        surfaceLayer.addChild(node)
        let sh = SKSpriteNode(texture: shadowTexture, size: shadowSize)
        sh.color = .black
        sh.colorBlendFactor = 1
        sh.alpha = 0.3
        sh.zRotation = node.zRotation
        shadowLayer.addChild(sh)
        surfaceItems.append(SurfaceItem(node: node, shadow: sh, vel: vel, wraps: wraps, radius: radius))
    }

    // MARK: - Lily pads & lotus

    private var backingScale: Double {
        Double(view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// Lays out and flattens the pads off the main thread, then swaps them in.
    /// Pads are static, so this only runs at start, on resize and when 荷叶密度 changes.
    private func buildPads(W: Double, H: Double) {
        padGeneration += 1
        let gen = padGeneration
        let density = clampD(settings.padDensity, 0.3, 1.5)
        builtDensity = density
        let ws = self.ws
        // ≤ 4096 px on the long side (≈0.8× native at 5K): one screen's pads ≈ 37 MB.
        let pxPerPt = min(backingScale, 4096 / max(W, H, 1))
        openCenter = V2(0.494 * W, 0.5 * H)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layout = LilyLayout.make(width: W, height: H, ws: ws, density: density)
            let flat = layout.flatten(width: W, height: H, ws: ws, pxPerPt: pxPerPt)
            guard let scene = self else { return }
            Task { @MainActor in
                scene.applyPads(layout, flat, gen: gen, W: W, H: H)
            }
        }
    }

    private func applyPads(_ layout: LilyLayout, _ flat: LilyLayout.Flattened, gen: Int, W: Double, H: Double) {
        guard gen == padGeneration else { return }
        var old: [SKNode] = [padSprite, padShadowSprite].compactMap { $0 }
        for f in flowerItems { old.append(f.node); old.append(f.shadow) }
        for n in old { n.run(.sequence([.fadeOut(withDuration: 0.5), .removeFromParent()])) }
        flowerItems.removeAll()

        let pads = SKSpriteNode(texture: Painter.texture(flat.pads), size: CGSize(width: W, height: H))
        pads.anchorPoint = .zero
        pads.alpha = 0
        pads.run(.fadeIn(withDuration: 0.6))
        padLayer.addChild(pads)
        padSprite = pads

        let m = flat.shadowMargin
        let sh = SKSpriteNode(texture: Painter.texture(flat.shadow), size: CGSize(width: W + 2 * m, height: H + 2 * m))
        sh.anchorPoint = .zero
        sh.position = CGPoint(x: -m, y: -m)
        sh.color = .black
        sh.colorBlendFactor = 1
        sh.alpha = 0
        padShadowLayer.addChild(sh)
        padShadowSprite = sh
        padShadowMargin = m
        padFade = 0

        padHits = layout.pads.map { (c: $0.p, r: $0.r) }
        openCenter = layout.openCenter

        let bank = LilyBank.shared
        for (i, f) in layout.flowers.enumerated() {
            let t: FlowerTexture
            switch f.kind {
            case .open: t = bank.openLotus[f.variant % bank.openLotus.count]
            case .half: t = bank.halfLotus[f.variant % bank.halfLotus.count]
            case .bud: t = bank.buds[f.variant % bank.buds.count]
            }
            let node = SKSpriteNode(texture: Painter.texture(t.image), size: CGSize(width: f.size, height: f.size))
            node.position = f.p.cg
            node.zRotation = CGFloat(f.rot)
            node.zPosition = CGFloat(i) * 0.01
            node.alpha = 0
            node.run(.fadeIn(withDuration: 0.6))
            if f.kind != .bud {
                let breathe = SKAction.scale(to: 1.025, duration: rnd(3, 5))
                breathe.timingMode = .easeInEaseOut
                let back = SKAction.scale(to: 1.0, duration: rnd(3, 5))
                back.timingMode = .easeInEaseOut
                node.run(.repeatForever(.sequence([breathe, back])))
            }
            flowerLayer.addChild(node)
            let ss = f.size * (1 + 2 * t.shadowMargin)
            let fs = SKSpriteNode(texture: Painter.texture(t.shadow), size: CGSize(width: ss, height: ss))
            fs.color = .black
            fs.colorBlendFactor = 1
            fs.alpha = 0
            fs.zRotation = node.zRotation
            flowerShadowLayer.addChild(fs)
            flowerItems.append((node, fs))
        }
    }

    /// Topmost pad under `p` (smaller pads are drawn later = on top).
    private func padAt(_ p: V2, inset: Double = 0.92) -> (i: Int, d: Double)? {
        for i in padHits.indices.reversed() {
            let h = padHits[i]
            let dx = p.x - h.c.x, dy = p.y - h.c.y
            if abs(dx) > h.r || abs(dy) > h.r { continue }
            let d = hypot(dx, dy)
            if d < h.r * inset { return (i, d) }
        }
        return nil
    }

    /// 0 (open water) … 1 (well under a pad) — for the fish.
    private func cover(at p: V2) -> Double {
        var c = 0.0
        for h in padHits {
            let dx = p.x - h.c.x, dy = p.y - h.c.y
            if abs(dx) > h.r || abs(dy) > h.r { continue }
            let q = hypot(dx, dy) / h.r
            if q < 1 { c = max(c, smoothstep(1.0, 0.7, q)); if c >= 1 { break } }
        }
        return c
    }

    private func buildDuckweed(W: Double, H: Double) {
        let n = Int(clampD(W * H / (70_000 * ws * ws), 10, 48))
        for _ in 0..<n {
            let s = rnd(22, 46) * ws
            let node = SKSpriteNode(texture: bank.duckweed.randomElement()!, size: CGSize(width: s, height: s))
            node.position = CGPoint(x: rnd(0, W), y: rnd(0, H))
            node.zRotation = CGFloat(rnd(0, 6.28))
            let v = V2(rnd(1.0, 3.0), rnd(-0.8, 1.2)) * ws
            addSurfaceItem(node, shadowSize: CGSize(width: s * 0.9, height: s * 0.9), shadowTexture: bank.softDisc, z: 0.2, vel: v, wraps: true, radius: s / 2)
        }
    }

    private func buildRain(W: Double, H: Double) {
        let e = SKEmitterNode()
        e.particleTexture = bank.streak
        let speed = 1500.0 * ws
        let angle = atan2(-1.0, -0.36)                 // falling towards bottom-left
        e.emissionAngle = CGFloat(angle)
        e.emissionAngleRange = 0.03
        e.particleSpeed = CGFloat(speed)
        e.particleSpeedRange = CGFloat(speed * 0.25)
        e.particleLifetime = CGFloat((H * 1.15) / (speed * 0.95))
        e.particleLifetimeRange = 0.15
        e.particlePositionRange = CGVector(dx: W * 1.5, dy: H * 0.1)
        e.position = CGPoint(x: W * 0.7, y: H + 60)
        e.particleRotation = CGFloat(angle + Double.pi / 2)
        e.particleAlpha = 0.20
        e.particleAlphaRange = 0.10
        e.particleScale = CGFloat(0.55 * ws)
        e.particleScaleRange = CGFloat(0.2 * ws)
        e.particleColor = .white
        e.particleColorBlendFactor = 0
        e.particleBlendMode = .add
        e.particleBirthRate = 0
        rainLayer.addChild(e)
        rainEmitter = e
    }

    // MARK: - Fish management

    private func spawnFish(initial: Bool) {
        let W = Double(size.width), H = Double(size.height)
        let len = rnd(38, 82) * ws * (chance(0.15) ? 1.25 : 1)
        let tex = FishArt.make(length: len, pattern: KoiPattern.random())
        let margin = 0.12 * min(W, H)
        let p = V2(rnd(margin, max(margin + 1, W - margin)), rnd(margin, max(margin + 1, H - margin)))
        let f = Fish(textures: tex, length: len, at: p, heading: rnd(-Double.pi, Double.pi),
                     cruise: rnd(18, 34) * ws * (0.8 + 0.4 * len / (60 * ws)), depth: rnd(0, 1))
        f.body.zPosition = CGFloat(fish.count % 100) * 0.01
        f.fade = initial ? rnd(0.3, 0.9) : 0
        fishLayer.addChild(f.body)
        shadowLayer.addChild(f.shadow)
        fish.append(f)
    }

    private func syncFishCount(_ dt: Double) {
        spawnClock -= dt
        let want = settings.fishTarget
        let alive = fish.filter { !$0.removing }
        if alive.count < want, spawnClock <= 0 {
            spawnFish(initial: false)
            spawnClock = 0.12
        } else if alive.count > want, let victim = alive.last {
            victim.removing = true
        }
        // Drop fully faded fish.
        fish.removeAll { f in
            if f.removing && f.fade <= 0 { f.removeNodes(); return true }
            return false
        }
    }

    // MARK: - Lighting

    private func currentTargetLight() -> LightState {
        let pos: (altitude: Double, azimuth: Double)
        if settings.followRealTime {
            pos = SunModel.currentPosition(latitude: settings.latitude)
        } else {
            // Manual altitude; keep the azimuth from the real clock so shadows still point sensibly.
            let real = SunModel.currentPosition(latitude: settings.latitude)
            pos = (settings.sunAltitude, real.altitude > -5 ? real.azimuth : 200)
        }
        return SunModel.lighting(altitude: pos.altitude, azimuth: pos.azimuth,
                                 intensity: settings.sunIntensity, rain: settings.rainEnabled)
    }

    // MARK: - Frame update

    override func update(_ currentTime: TimeInterval) {
        guard built else { return }
        var dt = lastTime == 0 ? 1.0 / 60.0 : currentTime - lastTime
        lastTime = currentTime
        dt = clampD(dt, 0, 1.0 / 15.0)
        elapsed += dt

        lightClock -= dt
        if lightClock <= 0 {
            targetLight = currentTargetLight()
            lightClock = 0.25
        }
        light.approach(targetLight, min(1, dt * 1.5))

        let W = Double(size.width), H = Double(size.height)
        let water = settings.waterColor
        let deep = settings.deepColor
        let defaultWater = RGB(hex: PondSettings.defaultWaterHex)
        let clarity = clampD(settings.waterClarity, 0, 1)
        let height = clampD(settings.waterHeight, 0, 1)

        // ---- shader uniforms
        let t = fmod(elapsed, 4000)
        let brightness = 1.06 - 0.14 * height
        let tint = RGB(clampD(water.r / max(defaultWater.r, 0.05), 0.25, 2.2),
                       clampD(water.g / max(defaultWater.g, 0.05), 0.25, 2.2),
                       clampD(water.b / max(defaultWater.b, 0.05), 0.25, 2.2)).scaled(brightness)
        floorShader.setFloat("u_t", t * 0.33)
        floorShader.setVec3("u_tint", tint.simd3)
        floorShader.setFloat("u_caustic", light.caustic * (0.45 + 0.55 * clarity))
        hazeShader.setFloat("u_t", t)
        hazeShader.setVec3("u_deep", deep.simd3)
        hazeShader.setFloat("u_haze", (1 - clarity) * 0.7 * (0.55 + 0.9 * height) + 0.04)
        glintShader.setFloat("u_t", t)
        glintShader.setFloat("u_glint", light.glint)
        ambientSprite?.color = light.ambient.nsColor

        // ---- shadows
        let waterDepth = (14 + 52 * height) * ws        // points from floor to surface
        let surfaceOffset = light.shadowDir * waterDepth
        let shadowA = light.shadowAlpha
        for i in surfaceItems.indices {
            let item = surfaceItems[i]
            if item.wraps {
                var p = item.node.position.v2 + item.vel * dt + V2(sin(elapsed * 0.3 + Double(i)), cos(elapsed * 0.27 + Double(i))) * (0.6 * dt * ws)
                let r = item.radius
                if p.x > W + r { p.x = -r } else if p.x < -r { p.x = W + r }
                if p.y > H + r { p.y = -r } else if p.y < -r { p.y = H + r }
                item.node.position = p.cg
                item.node.zRotation += CGFloat(0.02 * dt)
            }
            item.shadow.position = (item.node.position.v2 + surfaceOffset).cg
            item.shadow.zRotation = item.node.zRotation
            item.shadow.alpha = CGFloat(shadowA * 0.85)
        }

        // ---- lily pads / lotus shadows follow the sun
        padFade = min(1, padFade + dt / 0.6)
        if let sh = padShadowSprite {
            let o = surfaceOffset * 0.7
            sh.position = CGPoint(x: -padShadowMargin + o.x, y: -padShadowMargin + o.y)
            sh.alpha = CGFloat(shadowA * 1.4 * padFade)
        }
        for f in flowerItems {
            f.shadow.position = (f.node.position.v2 + surfaceOffset * 0.55).cg
            f.shadow.setScale(f.node.xScale)
            f.shadow.alpha = CGFloat(shadowA * 1.15 * padFade)
        }
        if abs(clampD(settings.padDensity, 0.3, 1.5) - builtDensity) > 0.001, action(forKey: "pads") == nil {
            run(.sequence([.wait(forDuration: 0.4), .run { [weak self] in
                guard let self else { return }
                self.buildPads(W: Double(self.size.width), H: Double(self.size.height))
            }]), withKey: "pads")
        }

        // ---- fish
        syncFishCount(dt)
        let bounds = V2(W, H)
        let margin = clampD(0.09 * min(W, H), 40, 160)
        let fishTint = RGB.mix(water, deep, 0.35).nsColor
        for f in fish {
            f.think(dt: dt, time: elapsed, school: fish, bounds: bounds, margin: margin,
                    cover: cover(at: f.head), openCenter: openCenter)
            let offset = surfaceOffset * (0.25 + 0.55 * (1 - f.depth))  // deeper fish → shorter offset
            let tintAmount = 0.06 + 0.22 * f.depth * (0.6 + 0.6 * height) + 0.12 * (1 - clarity)
            f.render(dt: dt, shadowOffset: offset, shadowAlpha: shadowA * (1.05 - 0.25 * f.depth),
                     tint: fishTint, tintAmount: tintAmount)
        }

        updateFloaters(dt, surfaceOffset: surfaceOffset, shadowAlpha: shadowA)
        updateEvents(dt)
        updateRain(dt)
    }

    // MARK: - Events (falling leaves / petals)

    private func updateEvents(_ dt: Double) {
        if settings.leavesEnabled {
            nextLeaf -= dt
            if nextLeaf <= 0 { dropObject(.leaf); nextLeaf = rnd(12, 30) }
        }
        if settings.petalsEnabled {
            nextPetal -= dt
            if nextPetal <= 0 { dropObject(.petal); nextPetal = rnd(10, 26) }
        }
    }

    func dropLeaf() { if built { dropObject(.leaf) } }
    func dropPetal() { if built { dropObject(.petal) } }

    private func dropObject(_ kind: Floater.Kind) {
        let W = Double(size.width), H = Double(size.height)
        let land = V2(rnd(0.12, 0.88) * W, rnd(0.15, 0.85) * H)
        let start = land + V2(rnd(40, 120), rnd(60, 160)) * ws
        let s = (kind == .leaf ? rnd(30, 46) : rnd(20, 28)) * ws
        let tex = kind == .leaf ? bank.leaves.randomElement()! : bank.petals.randomElement()!
        let node = SKSpriteNode(texture: tex, size: CGSize(width: s, height: s))
        node.position = start.cg
        node.alpha = 0
        node.zPosition = 0
        node.zRotation = CGFloat(rnd(0, 6.28))
        fallingLayer.addChild(node)
        let sh = SKSpriteNode(texture: bank.softLens, size: CGSize(width: s * 1.1, height: s * 1.1))
        sh.color = .black
        sh.colorBlendFactor = 1
        sh.alpha = 0
        shadowLayer.addChild(sh)
        let drift = V2(rnd(1.5, 4.5), rnd(-1.5, 2.0)) * ws
        let f = Floater(kind: kind, node: node, shadow: sh, start: start, land: land, vel: drift,
                        spin: rnd(-0.12, 0.12), life: rnd(28, 48), fall: rnd(2.2, 3.2), baseScale: 1)
        f.size = s
        floaters.append(f)
    }

    private func updateFloaters(_ dt: Double, surfaceOffset: V2, shadowAlpha: Double) {
        for f in floaters {
            switch f.place {
            case .falling:
                f.fallT = min(1, f.fallT + dt / f.fallDuration)
                let t = f.fallT
                let e = t * t                                 // accelerate into the water
                var p = f.start + (f.land - f.start) * e
                p += V2(sin(t * 7 + f.swayPhase), 0) * (22 * ws * (1 - t))   // flutter
                let height = 1 - e                                         // 1 = high above the water
                f.node.position = p.cg
                f.node.setScale(CGFloat(1 + 1.6 * height))
                f.node.zRotation += CGFloat(dt * (1.6 * (1 - t) + 0.2) * (f.spin >= 0 ? 1 : -1))
                f.node.alpha = CGFloat(min(1, t * 4))
                f.shadow.position = (p + surfaceOffset * (1 + 4 * height)).cg
                f.shadow.zRotation = f.node.zRotation
                f.shadow.setScale(CGFloat(1 + 0.8 * height))
                f.shadow.alpha = CGFloat(shadowAlpha * (0.25 + 0.6 * t))
                if t >= 1 { land(f) }
            case .sliding:
                f.slideT = min(1, f.slideT + dt / 0.9)
                let e = f.slideT * f.slideT
                let p = f.slideFrom + (f.slideTo - f.slideFrom) * e
                f.node.position = p.cg
                f.node.zRotation += CGFloat(f.spin * 3 * dt)
                f.shadow.position = (p + surfaceOffset * 0.12).cg
                f.shadow.zRotation = f.node.zRotation
                f.shadow.alpha = CGFloat(shadowAlpha * 0.9)
                if f.slideT >= 1 { enterWater(f, splash: 0.55) }
            case .pad:
                // Resting on a lily pad: no ripple, no drift; just fades out eventually.
                f.age += dt
                let a = floaterAlpha(f)
                f.node.alpha = CGFloat(a)
                f.shadow.position = (f.node.position.v2 + surfaceOffset * 0.12).cg
                f.shadow.zRotation = f.node.zRotation
                f.shadow.alpha = CGFloat(shadowAlpha * 0.9 * a)
            case .water:
                f.age += dt
                f.swayPhase += dt * 0.6
                let wobble = V2(cos(f.swayPhase), sin(f.swayPhase * 0.8)) * (1.2 * ws)
                var p = f.node.position.v2 + (f.vel + wobble) * dt
                // Floating things bump along the pads instead of drifting under them.
                if let hit = padAt(p, inset: 0.9) {
                    let h = padHits[hit.i]
                    let n = hit.d > 1e-3 ? (p - h.c) / hit.d : V2.dir(rnd(0, 6.28))
                    p = h.c + n * (h.r * 0.9)
                    let vn = f.vel.x * n.x + f.vel.y * n.y
                    if vn < 0 { f.vel = f.vel - n * (vn * 1.3) }
                }
                f.node.position = p.cg
                f.node.zRotation += CGFloat(f.spin * dt)
                f.vel = f.vel * (1 - 0.02 * dt)
                let a = floaterAlpha(f)
                f.node.alpha = CGFloat(a)
                f.shadow.position = (p + surfaceOffset).cg
                f.shadow.zRotation = f.node.zRotation
                f.shadow.alpha = CGFloat(shadowAlpha * 0.85 * a)
                // occasional tiny ripple while floating
                if chance(dt * 0.06) { ripple(at: p, diameter: 70 * ws, rings: 1, strength: 0.4) }
            }
        }
        floaters.removeAll { f in
            let dead = (f.place == .water || f.place == .pad) && f.age >= f.life
            if dead { f.node.removeFromParent(); f.shadow.removeFromParent() }
            return dead
        }
    }

    private func floaterAlpha(_ f: Floater) -> Double {
        let fadeStart = f.life - 5
        return f.age < fadeStart ? 1.0 : max(0, 1 - (f.age - fadeStart) / 5)
    }

    /// Touch-down: on a pad it rests (or slides off if it hit the rim), on water it
    /// makes rings and startles the fish.
    private func land(_ f: Floater) {
        f.landed = true
        f.node.setScale(1)
        f.shadow.setScale(1)
        if let hit = padAt(f.land) {
            let h = padHits[hit.i]
            f.node.removeFromParent()
            onPadLayer.addChild(f.node)
            f.node.zPosition = 0.1 + CGFloat(floaters.count % 50) * 0.001
            f.shadow.removeFromParent()
            onPadLayer.addChild(f.shadow)
            f.shadow.zPosition = 0
            if hit.d < h.r * 0.7 {
                f.place = .pad
                f.vel = V2(0, 0)
            } else {
                let dir = hit.d > 1e-3 ? (f.land - h.c) / hit.d : V2.dir(rnd(0, 6.28))
                f.place = .sliding
                f.slideFrom = f.land
                f.slideTo = h.c + dir * (h.r * 1.02 + f.size * 0.45)
                f.slideT = 0
                f.vel = dir * (5 * ws)
            }
        } else {
            enterWater(f, splash: 1)
        }
    }

    private func enterWater(_ f: Floater, splash: Double) {
        f.place = .water
        f.node.removeFromParent()
        surfaceLayer.addChild(f.node)
        f.node.zPosition = 1 + CGFloat(floaters.count % 50) * 0.01
        f.shadow.removeFromParent()
        shadowLayer.addChild(f.shadow)
        f.shadow.zPosition = 0
        let p = f.node.position.v2
        ripple(at: p, diameter: 230 * ws * (0.45 + 0.55 * splash), rings: splash > 0.8 ? 3 : 2, strength: splash)
        startle(at: p, radius: 260 * ws * (0.5 + 0.5 * splash), interest: f.node)
    }

    // MARK: - Ripples & fish reactions

    func ripple(at p: V2, diameter: Double, rings: Int, strength: Double, duration: Double = 2.6) {
        let baseSize = 256.0
        for i in 0..<rings {
            let r = SKSpriteNode(texture: bank.ring, size: CGSize(width: baseSize, height: baseSize))
            r.position = p.cg
            r.zPosition = -0.5            // under pads, above water
            r.setScale(0.04)
            r.alpha = 0
            let maxScale = diameter / baseSize * (1 - Double(i) * 0.16)
            let dur = duration + Double(i) * 0.35
            let grow = SKAction.scale(to: CGFloat(maxScale), duration: dur)
            grow.timingMode = .easeOut
            let fade = SKAction.sequence([
                .fadeAlpha(to: CGFloat(0.55 * strength), duration: 0.12),
                .fadeOut(withDuration: dur - 0.12)
            ])
            r.run(.sequence([.wait(forDuration: Double(i) * 0.3), .group([grow, fade]), .removeFromParent()]))
            surfaceLayer.addChild(r)
        }
    }

    func startle(at p: V2, radius: Double, interest: SKNode?) {
        for f in fish where !f.removing {
            let d = (f.center - p).len
            if d < radius {
                f.startle(from: p, distance: d, radius: radius, interest: interest)
            } else if d < radius * 1.6 {
                f.nudgeAway(from: p)
            }
        }
    }

    // MARK: - Rain

    private func updateRain(_ dt: Double) {
        guard let e = rainEmitter else { return }
        let W = Double(size.width), H = Double(size.height)
        if settings.rainEnabled {
            e.particleBirthRate = CGFloat(300 * W / 1440)
            let rate = 26 * (W * H) / (1440 * 900)
            rainAccumulator += dt * rate
            while rainAccumulator >= 1 {
                rainAccumulator -= 1
                ripple(at: V2(rnd(0, W), rnd(0, H)), diameter: rnd(26, 60) * ws, rings: chance(0.3) ? 2 : 1,
                       strength: rnd(0.35, 0.7), duration: rnd(0.7, 1.1))
            }
        } else {
            e.particleBirthRate = 0
            rainAccumulator = 0
        }
    }

    // MARK: - Interaction (window mode only)

    override func mouseDown(with event: NSEvent) {
        guard interactive, built else { return }
        let p = event.location(in: self).v2
        ripple(at: p, diameter: 170 * ws, rings: 3, strength: 0.9)
        startle(at: p, radius: 210 * ws, interest: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, built, chance(0.25) else { return }
        let p = event.location(in: self).v2
        ripple(at: p, diameter: 70 * ws, rings: 1, strength: 0.5, duration: 1.2)
        startle(at: p, radius: 120 * ws, interest: nil)
    }
}

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(clampD(r, 0, 1)), green: CGFloat(clampD(g, 0, 1)), blue: CGFloat(clampD(b, 0, 1)), alpha: 1)
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) ?? NSColor.white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}
