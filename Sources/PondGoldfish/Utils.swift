import Foundation
import CoreGraphics
import simd

// MARK: - Small vector / math helpers (pure Swift, no AppKit)

typealias V2 = SIMD2<Double>

extension SIMD2 where Scalar == Double {
    var len: Double { simd_length(self) }
    var normalized: V2 {
        let l = simd_length(self)
        return l > 1e-9 ? self / l : V2(0, 0)
    }
    var angle: Double { atan2(y, x) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
    var perp: V2 { V2(-y, x) }
    static func dir(_ a: Double) -> V2 { V2(cos(a), sin(a)) }
    func rotated(_ a: Double) -> V2 {
        let c = cos(a), s = sin(a)
        return V2(x * c - y * s, x * s + y * c)
    }
}

extension CGPoint {
    var v2: V2 { V2(Double(x), Double(y)) }
}

@inline(__always) func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clampD((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Wraps an angle into (-pi, pi].
func wrapAngle(_ a: Double) -> Double {
    var r = fmod(a + .pi, 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r - .pi
}

/// Uniform random in [a, b] (order-insensitive).
func rnd(_ a: Double, _ b: Double) -> Double {
    if a == b { return a }
    return Double.random(in: min(a, b)...max(a, b))
}

/// Approximately normal distributed random number (mean 0, sd 1).
func rndNormal() -> Double {
    let u1 = max(Double.random(in: 0..<1), 1e-12)
    let u2 = Double.random(in: 0..<1)
    return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}

func chance(_ p: Double) -> Bool { Double.random(in: 0..<1) < p }

// MARK: - Color

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// 0...255 components.
    static func bytes(_ r: Double, _ g: Double, _ b: Double) -> RGB {
        RGB(r / 255, g / 255, b / 255)
    }

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x71E6C2
        if s.count >= 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            r = 0x71 / 255; g = 0xE6 / 255; b = 0xC2 / 255
        }
    }

    var hex: String {
        let ri = Int((clampD(r, 0, 1) * 255).rounded())
        let gi = Int((clampD(g, 0, 1) * 255).rounded())
        let bi = Int((clampD(b, 0, 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t))
    }

    func scaled(_ k: Double) -> RGB { RGB(r * k, g * k, b * k) }
    func times(_ o: RGB) -> RGB { RGB(r * o.r, g * o.g, b * o.b) }

    var simd3: SIMD3<Float> { SIMD3<Float>(Float(r), Float(g), Float(b)) }

    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(clampD(r, 0, 1)), green: CGFloat(clampD(g, 0, 1)),
                blue: CGFloat(clampD(b, 0, 1)), alpha: CGFloat(alpha))
    }

    /// Small random variation, used for painterly palettes.
    func jitter(_ amount: Double) -> RGB {
        RGB(r + rnd(-amount, amount), g + rnd(-amount, amount), b + rnd(-amount, amount))
    }
}
