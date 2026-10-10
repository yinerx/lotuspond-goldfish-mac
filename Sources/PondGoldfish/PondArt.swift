import AppKit
import SpriteKit

/// Random large-scale structure of one pond: where the deep pockets, shallow sandy
/// flats, pebble beds and rocks are. Shared by the floor painting and the depth map
/// so the haze darkens exactly the pockets that were painted dark.
struct PondLayout {
    struct Spot { var c: V2; var r: Double }
    var size: V2
    var deep: [Spot] = []
    var shallow: [Spot] = []
    var pebbleBeds: [Spot] = []
    var rocks: [Spot] = []
    var moss: [Spot] = []

    init(width W: Double, height H: Double, ws: Double) {
        size = V2(W, H)
        let area = W * H
        let unit = 260.0 * 260.0 * ws * ws
        let nDeep = max(6, Int(area / unit * 0.9))
        for _ in 0..<nDeep {
            deep.append(Spot(c: V2(rnd(0.08, 0.92) * W, rnd(0.08, 0.92) * H), r: rnd(90, 210) * ws))
        }
        let nShallow = max(6, Int(area / unit * 1.1))
        for _ in 0..<nShallow {
            shallow.append(Spot(c: V2(rnd(0, 1) * W, rnd(0, 1) * H), r: rnd(70, 190) * ws))
        }
        for _ in 0..<max(8, Int(area / unit * 1.4)) {
            pebbleBeds.append(Spot(c: V2(rnd(0, 1) * W, rnd(0, 1) * H), r: rnd(60, 160) * ws))
        }
        // Rocks hug the edges, mostly bottom-left and top-right like the reference.
        rocks = [
            Spot(c: V2(0.03 * W, 0.10 * H), r: 115 * ws),
            Spot(c: V2(0.13 * W, 0.015 * H), r: 85 * ws),
            Spot(c: V2(-0.01 * W, 0.42 * H), r: 70 * ws),
            Spot(c: V2(0.985 * W, 0.94 * H), r: 105 * ws),
            Spot(c: V2(0.90 * W, 1.0 * H), r: 70 * ws),
            Spot(c: V2(0.30 * W, 0.20 * H), r: 95 * ws),
            Spot(c: V2(1.0 * W, 0.55 * H), r: 60 * ws)
        ]
        // Moss / algae concentrates near edges & corners.
        for _ in 0..<max(10, Int(area / unit * 1.2)) {
            let edge = Int.random(in: 0..<4)
            var p = V2(rnd(0, 1) * W, rnd(0, 1) * H)
            switch edge {
            case 0: p.x = rnd(0, 0.14) * W
            case 1: p.x = rnd(0.86, 1) * W
            case 2: p.y = rnd(0, 0.14) * H
            default: p.y = rnd(0.86, 1) * H
            }
            moss.append(Spot(c: p, r: rnd(40, 120) * ws))
        }
    }

    /// 0 (shallow) ... 1 (deep)
    func depth(at p: V2) -> Double {
        var d = 0.35
        for s in deep {
            let q = (p - s.c).len / s.r
            d += 0.55 * exp(-q * q * 1.6)
        }
        for s in shallow {
            let q = (p - s.c).len / s.r
            d -= 0.35 * exp(-q * q * 1.8)
        }
        return clampD(d, 0, 1)
    }
}

enum PondArt {

    // MARK: - Pond floor (painterly: patches, dabs, pebbles, moss, rocks, reeds)

    static func floor(layout: PondLayout, ws: Double) -> SKTexture {
        let W = layout.size.x, H = layout.size.y
        let scale = min(1.25, 3600.0 / max(W, H))
        let img = Painter.image(pw: Int(W * scale), ph: Int(H * scale), scale: scale) { ctx in
            let deepC = RGB.bytes(20, 96, 90)
            let midC = RGB.bytes(38, 128, 106)
            let flatC = RGB.bytes(84, 168, 124)

            ctx.setFillColor(midC.cg())
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

            // Large tonal patches with scalloped edges (the reference's "cellular" look).
            for s in layout.deep { scallop(ctx, s, deepC, alpha: 0.55, ws: ws) }
            for s in layout.shallow { scallop(ctx, s, flatC, alpha: 0.46, ws: ws) }

            // Painterly dabs whose tone follows the local depth.
            let area = W * H
            let nDabs = Int(area / (95 * ws * ws))
            for _ in 0..<nDabs {
                let p = V2(rnd(0, W), rnd(0, H))
                let d = layout.depth(at: p)
                let base = d > 0.5 ? RGB.mix(midC, deepC, (d - 0.5) * 2) : RGB.mix(flatC, midC, d * 2)
                let c = base.jitter(0.05)
                let r = rnd(2.5, 10) * ws
                Painter.fillEllipse(ctx, center: p, rx: r, ry: r * rnd(0.6, 1), angle: rnd(0, 3.14), c.cg(rnd(0.10, 0.28)))
            }

            // Soft algae fields.
            for s in layout.moss {
                for _ in 0..<Int(10 + s.r / (6 * ws)) {
                    let p = s.c + V2(rndNormal(), rndNormal()) * (s.r * 0.45)
                    let r = rnd(4, 16) * ws
                    let c = chance(0.6) ? RGB.bytes(36, 100, 58) : RGB.bytes(92, 140, 66)
                    Painter.fillEllipse(ctx, center: p, rx: r, ry: r * rnd(0.5, 1), angle: rnd(0, 3.14), c.jitter(0.04).cg(rnd(0.10, 0.25)))
                }
            }

            // Pebbles: clustered beds + a uniform sprinkle.
            let nPebbles = Int(area / (380 * ws * ws))
            let stones: [RGB] = [
                .bytes(92, 142, 116), .bytes(62, 112, 96), .bytes(122, 160, 126),
                .bytes(46, 96, 86), .bytes(140, 170, 132), .bytes(104, 128, 108), .bytes(78, 120, 100)
            ]
            for i in 0..<nPebbles {
                var p: V2
                if i % 5 < 3, let bed = layout.pebbleBeds.randomElement() {
                    p = bed.c + V2(rndNormal(), rndNormal()) * (bed.r * 0.5)
                } else {
                    p = V2(rnd(0, W), rnd(0, H))
                }
                if p.x < -10 || p.y < -10 || p.x > W + 10 || p.y > H + 10 { continue }
                // Mostly small, a few big ones (power-law-ish).
                let u = Double.random(in: 0..<1)
                let r = (1.6 + 7.5 * pow(u, 3.2)) * ws
                pebble(ctx, at: p, r: r, color: stones.randomElement()!.jitter(0.035), ws: ws)
            }

            // Moss specks on top of pebbles near edges.
            for s in layout.moss {
                for _ in 0..<Int(s.r / (1.4 * ws)) {
                    let p = s.c + V2(rndNormal(), rndNormal()) * (s.r * 0.5)
                    let c = chance(0.5) ? RGB.bytes(30, 82, 48) : RGB.bytes(118, 156, 72)
                    Painter.fillCircle(ctx, p, rnd(0.8, 2.6) * ws, c.cg(rnd(0.35, 0.7)))
                }
            }

            // Rocks.
            for s in layout.rocks { rock(ctx, s, ws: ws, scale: scale) }

            // Underwater reeds / grass at the left and bottom edges.
            for _ in 0..<Int(28 * ws + 10) {
                let fromLeft = chance(0.6)
                let base = fromLeft ? V2(rnd(-10, 40) * ws, rnd(0.0, 0.75) * H) : V2(rnd(0, 0.35) * W, rnd(-10, 30) * ws)
                let len = rnd(40, 130) * ws
                let ang = fromLeft ? rnd(-0.3, 0.9) : rnd(0.9, 2.0)
                let tip = base + V2.dir(ang) * len
                let ctrl = base + V2.dir(ang + rnd(-0.5, 0.5)) * (len * 0.6)
                let path = CGMutablePath()
                path.move(to: base.cg)
                path.addQuadCurve(to: tip.cg, control: ctrl.cg)
                ctx.addPath(path)
                ctx.setLineCap(.round)
                ctx.setLineWidth(CGFloat(rnd(1.5, 3.8) * ws))
                let c = chance(0.5) ? RGB.bytes(40, 104, 58) : RGB.bytes(74, 130, 62)
                ctx.setStrokeColor(c.cg(rnd(0.35, 0.6)))
                ctx.strokePath()
            }

            // Gentle vignette (deeper at the borders).
            let center = V2(W / 2, H / 2)
            let g = Painter.gradient([rgba(0, 0, 0, 0), rgba(0, 20, 22, 0.30)], [0.55, 1])
            ctx.drawRadialGradient(g, startCenter: center.cg, startRadius: 0, endCenter: center.cg,
                                   endRadius: CGFloat(hypot(W, H) * 0.55), options: [.drawsAfterEndLocation])
        }
        return Painter.texture(img)
    }

    private static func scallop(_ ctx: CGContext, _ s: PondLayout.Spot, _ color: RGB, alpha: Double, ws: Double) {
        let n = Int(10 + s.r / (9 * ws))
        for _ in 0..<n {
            let p = s.c + V2(rndNormal(), rndNormal()) * (s.r * 0.33)
            let r = rnd(0.22, 0.5) * s.r
            Painter.fillCircle(ctx, p, r, color.jitter(0.025).cg(alpha * rnd(0.5, 1)))
        }
        // Scalloped rim of small circles.
        let rim = Int(14 + s.r / (5 * ws))
        for i in 0..<rim {
            let a = Double(i) / Double(rim) * 2 * Double.pi + rnd(-0.1, 0.1)
            let p = s.c + V2.dir(a) * (s.r * rnd(0.62, 0.85))
            Painter.fillCircle(ctx, p, s.r * rnd(0.10, 0.2), color.jitter(0.025).cg(alpha * rnd(0.5, 0.9)))
        }
    }

    private static func pebble(_ ctx: CGContext, at p: V2, r: Double, color: RGB, ws: Double) {
        let ang = rnd(0, 3.14)
        let ry = r * rnd(0.6, 0.95)
        // contact shadow
        Painter.fillEllipse(ctx, center: p + V2(0.25, -0.3) * r, rx: r * 1.08, ry: ry * 1.08, angle: ang, rgba(8, 40, 38, 0.2))
        Painter.fillEllipse(ctx, center: p, rx: r, ry: ry, angle: ang, color.cg(0.6))
        if r > 2.2 * ws {
            Painter.fillEllipse(ctx, center: p + V2(-0.3, 0.32) * r, rx: r * 0.5, ry: ry * 0.42, angle: ang,
                                color.scaled(1.18).cg(0.3))
        }
    }

    private static func rock(_ ctx: CGContext, _ s: PondLayout.Spot, ws: Double, scale: Double) {
        let path = Painter.blobPath(center: s.c, radius: s.r, roughness: 0.12, points: 26, squash: rnd(0.7, 0.95), rotation: rnd(0, 3.14))
        // soft drop shadow (CG shadow params are in device space → multiply by scale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 10 * ws * scale, height: -12 * ws * scale), blur: CGFloat(22 * ws * scale),
                      color: rgba(5, 30, 30, 0.55))
        ctx.addPath(path)
        ctx.setFillColor(rgba(78, 104, 96))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = Painter.gradient([rgba(150, 168, 146), rgba(92, 116, 104), rgba(52, 78, 74)], [0, 0.55, 1])
        ctx.drawLinearGradient(g, start: (s.c + V2(-0.7, 0.7) * s.r).cg, end: (s.c + V2(0.7, -0.7) * s.r).cg, options: [])
        // painterly facets
        for _ in 0..<Int(30 + s.r / ws) {
            let p = s.c + V2(rnd(-1, 1), rnd(-1, 1)) * s.r
            let c = chance(0.5) ? RGB.bytes(160, 176, 150) : RGB.bytes(60, 84, 78)
            Painter.fillEllipse(ctx, center: p, rx: rnd(3, 12) * ws, ry: rnd(2, 6) * ws, angle: rnd(0, 3.14), c.cg(rnd(0.08, 0.22)))
        }
        // moss on the top-left side
        for _ in 0..<Int(s.r / (0.9 * ws)) {
            let p = s.c + V2(rnd(-1, 0.4), rnd(-0.2, 1)) * s.r
            let c = chance(0.5) ? RGB.bytes(96, 140, 64) : RGB.bytes(52, 104, 54)
            Painter.fillCircle(ctx, p, rnd(1, 3.5) * ws, c.cg(rnd(0.25, 0.6)))
        }
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(rgba(30, 56, 52, 0.45))
        ctx.setLineWidth(CGFloat(1.5 * ws))
        ctx.strokePath()
    }

    /// Low-res grey depth map for the haze shader (red channel = depth).
    static func depthMap(layout: PondLayout) -> SKTexture {
        let W = layout.size.x, H = layout.size.y
        let pw = 256
        let ph = max(16, Int(256 * H / W))
        let s = 256.0 / W
        let img = Painter.image(pw: pw, ph: ph, scale: s) { ctx in
            ctx.setFillColor(rgba(90, 90, 90))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for d in layout.deep {
                Painter.radial(ctx, center: d.c, radius: d.r * 1.15, inner: rgba(255, 255, 255, 0.85), outer: rgba(255, 255, 255, 0))
            }
            for d in layout.shallow {
                Painter.radial(ctx, center: d.c, radius: d.r * 1.1, inner: rgba(0, 0, 0, 0.6), outer: rgba(0, 0, 0, 0))
            }
            for d in layout.rocks {
                Painter.radial(ctx, center: d.c, radius: d.r * 1.3, inner: rgba(0, 0, 0, 0.9), outer: rgba(0, 0, 0, 0))
            }
        }
        return Painter.texture(Painter.blurred(img, radius: 4))
    }

    // MARK: - Surface decor (lily pads & lotus: see LilyArt.swift)

    /// Curled autumn leaf, pointing +x, 128×128.
    static func leaf(variant: Int) -> SKTexture {
        let S = 128.0
        let colors: [RGB] = [.bytes(234, 184, 58), .bytes(224, 128, 44), .bytes(176, 98, 46), .bytes(206, 156, 62), .bytes(196, 70, 40)]
        let col = colors[variant % colors.count]
        let narrow = variant % 2 == 1
        let img = Painter.image(pw: 128, ph: 128) { ctx in
            let base = CGPoint(x: S * 0.16, y: S * 0.5)
            let tipP = CGPoint(x: S * 0.93, y: S * 0.52)
            let wTop = narrow ? 0.30 : 0.42, wBot = narrow ? 0.26 : 0.36
            let path = CGMutablePath()
            path.move(to: base)
            path.addCurve(to: tipP, control1: CGPoint(x: S * 0.30, y: S * (0.5 + wTop)), control2: CGPoint(x: S * 0.78, y: S * (0.5 + wTop * 0.7)))
            path.addCurve(to: base, control1: CGPoint(x: S * 0.78, y: S * (0.5 - wBot * 0.75)), control2: CGPoint(x: S * 0.32, y: S * (0.5 - wBot)))
            path.closeSubpath()

            // stem
            ctx.setLineCap(.round)
            ctx.move(to: base)
            ctx.addQuadCurve(to: CGPoint(x: S * 0.02, y: S * 0.44), control: CGPoint(x: S * 0.08, y: S * 0.5))
            ctx.setStrokeColor(col.scaled(0.6).cg())
            ctx.setLineWidth(3)
            ctx.strokePath()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let g = Painter.gradient([col.scaled(1.1).cg(), col.cg(), col.scaled(0.72).cg()], [0, 0.5, 1])
            ctx.drawLinearGradient(g, start: base, end: tipP, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // curl: one half in shadow, the other catching light
            ctx.setFillColor(rgba(40, 20, 0, 0.22))
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S * 0.49))
            Painter.fillEllipse(ctx, center: V2(S * 0.5, S * 0.7), rx: S * 0.3, ry: S * 0.06, angle: 0.05, rgba(255, 250, 220, 0.18))
            // blotches
            for _ in 0..<10 {
                Painter.fillCircle(ctx, V2(rnd(0.2, 0.9) * S, rnd(0.25, 0.75) * S), rnd(1.5, 4.5), col.scaled(0.55).cg(rnd(0.15, 0.4)))
            }
            // midrib + veins
            ctx.move(to: base)
            ctx.addQuadCurve(to: tipP, control: CGPoint(x: S * 0.55, y: S * 0.55))
            ctx.setStrokeColor(col.scaled(0.55).cg(0.8))
            ctx.setLineWidth(1.8)
            ctx.strokePath()
            for i in 1...5 {
                let t = Double(i) / 6.5
                let px = Double(base.x) + (Double(tipP.x) - Double(base.x)) * t
                let py = S * 0.5 + S * 0.04 * t
                for side in [-1.0, 1.0] {
                    ctx.move(to: CGPoint(x: px, y: py))
                    ctx.addLine(to: CGPoint(x: px + S * 0.13, y: py + side * S * (narrow ? 0.18 : 0.26) * (1 - t * 0.6)))
                    ctx.setStrokeColor(col.scaled(0.6).cg(0.5))
                    ctx.setLineWidth(1)
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(col.scaled(0.5).cg(0.7))
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
        return Painter.texture(img)
    }

    /// Single pink lotus petal, pointing +x, 96×96.
    static func fallingPetal(variant: Int) -> SKTexture {
        let S = 96.0
        let tip = variant % 2 == 0 ? RGB.bytes(240, 128, 172) : RGB.bytes(246, 160, 190)
        let img = Painter.image(pw: 96, ph: 96) { ctx in
            let path = CGMutablePath()
            let b = CGPoint(x: S * 0.08, y: S * 0.5)
            path.move(to: b)
            path.addCurve(to: CGPoint(x: S * 0.9, y: S * 0.5), control1: CGPoint(x: S * 0.25, y: S * 0.88), control2: CGPoint(x: S * 0.92, y: S * 0.82))
            path.addCurve(to: b, control1: CGPoint(x: S * 0.92, y: S * 0.2), control2: CGPoint(x: S * 0.25, y: S * 0.12))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let g = Painter.gradient([rgba(252, 232, 238), tip.scaled(1.02).cg(), tip.scaled(0.92).cg()], [0, 0.6, 1])
            ctx.drawLinearGradient(g, start: b, end: CGPoint(x: S * 0.9, y: S * 0.5), options: [.drawsAfterEndLocation])
            ctx.setFillColor(rgba(120, 30, 70, 0.12))
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S * 0.45))
            ctx.move(to: CGPoint(x: S * 0.14, y: S * 0.5))
            ctx.addQuadCurve(to: CGPoint(x: S * 0.82, y: S * 0.52), control: CGPoint(x: S * 0.5, y: S * 0.56))
            ctx.setStrokeColor(rgba(255, 248, 250, 0.45))
            ctx.setLineWidth(1.5)
            ctx.strokePath()
            ctx.restoreGState()
        }
        return Painter.texture(img)
    }

    static func duckweed() -> SKTexture {
        let S = 64.0
        let img = Painter.image(pw: 64, ph: 64) { ctx in
            let n = Int.random(in: 4...11)
            for _ in 0..<n {
                let p = V2(S / 2, S / 2) + V2(rndNormal(), rndNormal()) * (S * 0.16)
                let r = rnd(3.2, 6.5)
                let c = chance(0.5) ? RGB.bytes(132, 196, 74) : RGB.bytes(98, 168, 62)
                let a = rnd(0, 3.14)
                Painter.fillEllipse(ctx, center: p + V2(0.6, -0.8), rx: r, ry: r * 0.75, angle: a, rgba(10, 50, 30, 0.35))
                Painter.fillEllipse(ctx, center: p, rx: r, ry: r * 0.75, angle: a, c.cg())
                Painter.fillEllipse(ctx, center: p + V2(-0.25, 0.25) * r, rx: r * 0.45, ry: r * 0.3, angle: a, rgba(220, 240, 160, 0.35))
            }
        }
        return Painter.texture(img)
    }

    /// Ripple ring: bright crest + faint dark trough (normal alpha blending).
    static func ring() -> SKTexture {
        let img = Painter.image(pw: 256, ph: 256) { ctx in
            ctx.setStrokeColor(rgba(255, 255, 255, 0.9))
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: 128 - 114, y: 128 - 114, width: 228, height: 228))
            ctx.setStrokeColor(rgba(0, 30, 30, 0.22))
            ctx.setLineWidth(6)
            ctx.strokeEllipse(in: CGRect(x: 128 - 104, y: 128 - 104, width: 208, height: 208))
            ctx.setStrokeColor(rgba(255, 255, 255, 0.25))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 128 - 95, y: 128 - 95, width: 190, height: 190))
        }
        return Painter.texture(Painter.blurred(img, radius: 1.6))
    }

    /// Rain streak, vertical, 8×128.
    static func streak() -> SKTexture {
        let img = Painter.image(pw: 8, ph: 128) { ctx in
            let g = Painter.gradient([rgba(255, 255, 255, 0), rgba(235, 250, 255, 0.85), rgba(255, 255, 255, 0)], [0, 0.65, 1])
            ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: 0, width: 2, height: 128), cornerWidth: 1, cornerHeight: 1, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 128), options: [])
        }
        return Painter.texture(img)
    }

    /// Generic soft shadow blob (white-on-transparent so node colour/alpha control it).
    static func softDisc() -> SKTexture {
        let img = Painter.image(pw: 128, ph: 128) { ctx in
            Painter.fillCircle(ctx, V2(64, 64), 44, rgba(0, 0, 0, 1))
        }
        return Painter.texture(Painter.blurred(img, radius: 12))
    }

    /// Shadow of a leaf/petal (blurred lens shape, pointing +x).
    static func softLens() -> SKTexture {
        let img = Painter.image(pw: 128, ph: 128) { ctx in
            Painter.fillEllipse(ctx, center: V2(64, 64), rx: 44, ry: 22, angle: 0, rgba(0, 0, 0, 1))
        }
        return Painter.texture(Painter.blurred(img, radius: 8))
    }

    static func white() -> SKTexture {
        let img = Painter.image(pw: 4, ph: 4) { ctx in
            ctx.setFillColor(rgba(255, 255, 255))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return Painter.texture(img)
    }
}

/// Textures that do not depend on the screen size; built once and shared by all scenes.
final class TextureBank {
    static let shared = TextureBank()

    let leaves: [SKTexture]
    let petals: [SKTexture]
    let duckweed: [SKTexture]
    let ring: SKTexture
    let streak: SKTexture
    let softDisc: SKTexture
    let softLens: SKTexture
    let white: SKTexture

    private init() {
        leaves = (0..<5).map { PondArt.leaf(variant: $0) }
        petals = (0..<2).map { PondArt.fallingPetal(variant: $0) }
        duckweed = (0..<6).map { _ in PondArt.duckweed() }
        ring = PondArt.ring()
        streak = PondArt.streak()
        softDisc = PondArt.softDisc()
        softLens = PondArt.softLens()
        white = PondArt.white()
    }
}
