import AppKit
import SpriteKit

/// Koi varieties seen in the reference: solid orange-red, kohaku (white/red),
/// sanke (white/red/black) plus a few extra classic patterns.
enum KoiPattern: CaseIterable {
    case kohaku, sanke, hi, orenji, tancho, yamabuki, showa

    static func random() -> KoiPattern {
        let r = Double.random(in: 0..<1)
        switch r {
        case ..<0.30: return .kohaku
        case ..<0.50: return .hi
        case ..<0.68: return .sanke
        case ..<0.78: return .orenji
        case ..<0.86: return .tancho
        case ..<0.93: return .yamabuki
        default: return .showa
        }
    }
}

struct FishTextures {
    let body: SKTexture        // body + tail, head pointing +x, canvas L × 0.42L
    let shadow: SKTexture      // blurred silhouette on the same canvas
    let fin: SKTexture         // pectoral fin pointing +x, root at the left edge
    let canvas: CGSize         // points
    let finSize: CGSize        // points
    let finColor: RGB
}

enum FishArt {
    static let heightRatio = 0.42
    static let pixelsPerPoint = 2.0

    /// Body half-width at normalised body position s (0 = caudal peduncle, 1 = nose).
    static func halfWidth(_ s: Double, wmax: Double) -> Double {
        if s < 0.6 {
            return wmax * (0.16 + 0.84 * pow(sin(s / 0.6 * Double.pi / 2), 1.2))
        }
        let q = (s - 0.6) / 0.4
        return wmax * sqrt(max(0, 1 - pow(q, 2.2)))
    }

    static func make(length L: Double, pattern: KoiPattern) -> FishTextures {
        let W = L, H = L * heightRatio
        let cy = H / 2
        let xp = 0.28 * L, xn = 0.94 * L, wmax = 0.11 * L
        let px = pixelsPerPoint

        // ---- outline paths
        let body = CGMutablePath()
        let N = 44
        for i in 0...N {
            let s = Double(i) / Double(N)
            let p = CGPoint(x: xp + (xn - xp) * s, y: cy + halfWidth(s, wmax: wmax))
            if i == 0 { body.move(to: p) } else { body.addLine(to: p) }
        }
        for i in stride(from: N, through: 0, by: -1) {
            let s = Double(i) / Double(N)
            body.addLine(to: CGPoint(x: xp + (xn - xp) * s, y: cy - halfWidth(s, wmax: wmax)))
        }
        body.closeSubpath()

        let spread = rnd(0.13, 0.17) * L
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: xp + 0.03 * L, y: cy + 0.02 * L))
        tail.addQuadCurve(to: CGPoint(x: 0.05 * L, y: cy + spread), control: CGPoint(x: 0.20 * L, y: cy + 0.11 * L))
        tail.addQuadCurve(to: CGPoint(x: 0.15 * L, y: cy), control: CGPoint(x: 0.07 * L, y: cy + 0.05 * L))
        tail.addQuadCurve(to: CGPoint(x: 0.05 * L, y: cy - spread), control: CGPoint(x: 0.07 * L, y: cy - 0.05 * L))
        tail.addQuadCurve(to: CGPoint(x: xp + 0.03 * L, y: cy - 0.02 * L), control: CGPoint(x: 0.20 * L, y: cy - 0.11 * L))
        tail.closeSubpath()

        // ---- palette
        let white = RGB.bytes(248, 244, 238).jitter(0.01)
        let red = RGB.bytes(224, 58, 34).jitter(0.03)
        let orange = RGB.bytes(242, 112, 36).jitter(0.03)
        let gold = RGB.bytes(244, 190, 72).jitter(0.02)
        let black = RGB.bytes(26, 26, 32)

        var base = white
        var finColor = white
        switch pattern {
        case .hi: base = RGB.mix(red, orange, rnd(0, 0.5)); finColor = orange.scaled(1.05)
        case .orenji: base = orange; finColor = orange.scaled(1.08)
        case .yamabuki: base = gold; finColor = gold.scaled(1.05)
        case .showa: base = black; finColor = RGB.bytes(60, 56, 60)
        default: break
        }

        func blob(_ ctx: CGContext, at x: Double, _ y: Double, size r: Double, _ color: RGB) {
            let n = Int.random(in: 3...6)
            for _ in 0..<n {
                let p = V2(x, y) + V2(rnd(-1, 1), rnd(-1, 1)) * (r * 0.7)
                Painter.fillEllipse(ctx, center: p, rx: r * rnd(0.6, 1.1), ry: r * rnd(0.5, 0.9), angle: rnd(0, 3.14), color.cg())
            }
        }

        let bodyImg = Painter.image(pw: Int(W * px), ph: Int(H * px), scale: px) { ctx in
            // tail fin (translucent, with rays)
            ctx.saveGState()
            ctx.addPath(tail)
            ctx.setFillColor(finColor.cg(0.58))
            ctx.fillPath()
            ctx.addPath(tail)
            ctx.clip()
            ctx.setLineWidth(CGFloat(0.006 * L))
            ctx.setStrokeColor(finColor.scaled(0.8).cg(0.35))
            for i in 0...10 {
                let a = Double(i) / 10 * 2 - 1
                ctx.move(to: CGPoint(x: xp + 0.03 * L, y: cy))
                ctx.addLine(to: CGPoint(x: 0.03 * L, y: cy + a * spread * 1.1))
                ctx.strokePath()
            }
            ctx.restoreGState()

            // body
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.setFillColor(base.cg())
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            switch pattern {
            case .kohaku, .sanke:
                let count = Int.random(in: 2...4)
                for k in 0..<count {
                    let x = xp + (xn - xp) * (0.15 + 0.8 * (Double(k) + rnd(0.1, 0.9)) / Double(count))
                    blob(ctx, at: x, cy + rnd(-0.03, 0.03) * L, size: rnd(0.05, 0.08) * L, red)
                }
                if pattern == .sanke {
                    for _ in 0..<Int.random(in: 3...7) {
                        let x = xp + (xn - xp) * rnd(0.05, 0.85)
                        blob(ctx, at: x, cy + rnd(-0.06, 0.06) * L, size: rnd(0.018, 0.035) * L, black)
                    }
                }
            case .tancho:
                Painter.fillCircle(ctx, V2(xp + (xn - xp) * 0.84, cy), 0.045 * L, red.cg())
            case .showa:
                for _ in 0..<3 { blob(ctx, at: xp + (xn - xp) * rnd(0.2, 0.95), cy + rnd(-0.03, 0.03) * L, size: rnd(0.04, 0.07) * L, red) }
                for _ in 0..<2 { blob(ctx, at: xp + (xn - xp) * rnd(0.1, 0.9), cy + rnd(-0.05, 0.05) * L, size: rnd(0.03, 0.05) * L, white) }
            case .hi, .orenji, .yamabuki:
                // subtle lighter flanks / darker back
                for _ in 0..<4 { blob(ctx, at: xp + (xn - xp) * rnd(0.1, 0.9), cy + rnd(-0.08, 0.08) * L, size: rnd(0.03, 0.05) * L, base.scaled(1.12)) }
            }
            // dorsal sheen down the spine (top-down light)
            Painter.fillEllipse(ctx, center: V2(xp + (xn - xp) * 0.52, cy), rx: (xn - xp) * 0.36, ry: 0.022 * L, angle: 0,
                                rgba(255, 255, 255, pattern == .showa ? 0.10 : 0.20))
            // darker edges
            ctx.addPath(body)
            ctx.setStrokeColor(rgba(40, 20, 10, 0.25))
            ctx.setLineWidth(CGFloat(0.03 * L))
            ctx.strokePath()
            ctx.restoreGState()

            // dorsal fin (thin translucent ridge)
            Painter.fillEllipse(ctx, center: V2(xp + (xn - xp) * 0.38, cy), rx: (xn - xp) * 0.22, ry: 0.008 * L, angle: 0, finColor.scaled(0.9).cg(0.45))

            // eyes
            let ex = xp + (xn - xp) * 0.88
            let ey = halfWidth(0.88, wmax: wmax) * 0.78
            for side in [-1.0, 1.0] {
                Painter.fillCircle(ctx, V2(ex, cy + side * ey), 0.013 * L, rgba(18, 16, 20, 0.95))
                Painter.fillCircle(ctx, V2(ex + 0.004 * L, cy + side * ey + 0.004 * L), 0.004 * L, rgba(255, 255, 255, 0.7))
            }
        }

        let silhouette = Painter.image(pw: Int(W * px), ph: Int(H * px), scale: px) { ctx in
            ctx.addPath(tail)
            ctx.setFillColor(rgba(0, 0, 0, 0.55))
            ctx.fillPath()
            ctx.addPath(body)
            ctx.setFillColor(rgba(0, 0, 0, 1))
            ctx.fillPath()
        }
        let shadowImg = Painter.blurred(silhouette, radius: 0.022 * L * px)

        // pectoral fin
        let fw = 0.17 * L, fh = 0.12 * L
        let finImg = Painter.image(pw: Int(fw * px) + 1, ph: Int(fh * px) + 1, scale: px) { ctx in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: fh * 0.6))
            p.addQuadCurve(to: CGPoint(x: fw * 0.95, y: fh * 0.95), control: CGPoint(x: fw * 0.4, y: fh * 0.98))
            p.addQuadCurve(to: CGPoint(x: fw * 0.82, y: fh * 0.06), control: CGPoint(x: fw * 1.08, y: fh * 0.5))
            p.addQuadCurve(to: CGPoint(x: 0, y: fh * 0.4), control: CGPoint(x: fw * 0.4, y: fh * 0.12))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(finColor.cg(0.55))
            ctx.fillPath()
            ctx.addPath(p)
            ctx.clip()
            ctx.setStrokeColor(finColor.scaled(0.8).cg(0.4))
            ctx.setLineWidth(CGFloat(0.005 * L))
            for i in 0...6 {
                let t = Double(i) / 6
                ctx.move(to: CGPoint(x: 0, y: fh * 0.5))
                ctx.addLine(to: CGPoint(x: fw, y: fh * (0.02 + 0.96 * t)))
                ctx.strokePath()
            }
        }

        return FishTextures(body: Painter.texture(bodyImg), shadow: Painter.texture(shadowImg),
                            fin: Painter.texture(finImg),
                            canvas: CGSize(width: W, height: H), finSize: CGSize(width: fw, height: fh),
                            finColor: finColor)
    }
}
