import AppKit
import CoreImage
import SpriteKit

/// Low-level Core Graphics helpers used to paint every texture procedurally.
enum Painter {
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let ciContext = CIContext(options: nil)

    /// Creates an RGBA bitmap context of `pw`×`ph` pixels whose user space is scaled by `scale`
    /// (so callers draw in points). Origin is bottom-left, y up — same as SpriteKit.
    static func image(pw: Int, ph: Int, scale: Double = 1, _ draw: (CGContext) -> Void) -> CGImage {
        let w = max(1, pw), h = max(1, ph)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not create bitmap context \(w)x\(h)")
        }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(ctx)
        guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
        return img
    }

    static func blurred(_ img: CGImage, radius: Double) -> CGImage {
        guard radius > 0.1, let f = CIFilter(name: "CIGaussianBlur") else { return img }
        let ci = CIImage(cgImage: img)
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: ci.extent),
              let cg = ciContext.createCGImage(out, from: ci.extent) else { return img }
        return cg
    }

    static func texture(_ img: CGImage) -> SKTexture {
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        return t
    }

    // MARK: drawing shortcuts (all in user space / points)

    static func fillCircle(_ ctx: CGContext, _ c: V2, _ r: Double, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func fillEllipse(_ ctx: CGContext, center c: V2, rx: Double, ry: Double, angle: Double, _ color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(c.x), y: CGFloat(c.y))
        ctx.rotate(by: CGFloat(angle))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
        ctx.restoreGState()
    }

    static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    }

    static func radial(_ ctx: CGContext, center c: V2, radius r: Double, inner: CGColor, outer: CGColor, extend: Bool = false) {
        let g = gradient([inner, outer], [0, 1])
        ctx.drawRadialGradient(g, startCenter: c.cg, startRadius: 0, endCenter: c.cg, endRadius: CGFloat(r),
                               options: extend ? [.drawsAfterEndLocation] : [])
    }

    /// Closed smooth blob path with a noisy radius (used for rocks and pads).
    static func blobPath(center c: V2, radius r: Double, roughness: Double, points n: Int = 22, squash: Double = 1, rotation: Double = 0) -> CGPath {
        var pts: [V2] = []
        let ph1 = rnd(0, 6.28), ph2 = rnd(0, 6.28)
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * Double.pi
            let k = 1 + roughness * (0.55 * sin(a * 3 + ph1) + 0.35 * sin(a * 5 + ph2) + 0.25 * rnd(-1, 1))
            let local = V2(cos(a) * r * k, sin(a) * r * k * squash).rotated(rotation)
            pts.append(c + local)
        }
        let path = CGMutablePath()
        // Quadratic curves through midpoints -> smooth closed outline.
        let m0 = (pts[n - 1] + pts[0]) * 0.5
        path.move(to: m0.cg)
        for i in 0..<n {
            let p = pts[i]
            let next = pts[(i + 1) % n]
            path.addQuadCurve(to: ((p + next) * 0.5).cg, control: p.cg)
        }
        path.closeSubpath()
        return path
    }
}

/// Convenience: 0...255 sRGB colour.
@inline(__always) func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    RGB.bytes(r, g, b).cg(a)
}
