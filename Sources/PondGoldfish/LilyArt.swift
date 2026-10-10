import AppKit
import CoreGraphics
import ImageIO
import simd

// 荷叶 / 荷花 — Swift port of design/lotus/lotus_preview.py (v3).
//
// Every texture is a pure function of (size, params, seed), evaluated per pixel on
// Float buffers in image coordinates (x right, y DOWN, light from the top-left at
// -135°), exactly like the numpy mockup. Strokes (veins, stamens, stalks) are
// rasterised with Core Graphics into a coverage mask first and then used by the
// per-pixel pass, again like the mockup.
//
// Flowers stand in open water on their own stalks (never on a pad); see placeFlowers.
//
// Design (see README / release notes):
//  * A pool of 24 unique pad textures in 3 size classes (8 large, 9 medium, 7 small)
//    is generated once per launch, off the main thread, in parallel.
//  * Lighting is baked for one canonical light direction. Instances are only rotated
//    by ±10° and optionally MIRRORED ACROSS THE LIGHT AXIS (a reflection that maps the
//    top-left light onto itself), so highlights/droplets stay lit from the top-left.
//    Variety comes from the pool (outline, notch, palette, droplets) + mirror + scale.
//  * All pads of one screen, with their short contact shadows onto lower pads and the
//    meniscus ring, are flattened into ONE texture with Core Graphics; their long soft
//    shadow is a second, low-resolution texture that the scene offsets with the sun.
//    Only rebuilt when the layout changes (screen size, 荷叶密度).

// MARK: - Deterministic RNG / noise

struct LRng {
    private var s: UInt64
    init(_ seed: UInt64) { s = (seed &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9; if s == 0 { s = 1 } }
    mutating func next() -> UInt64 {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return s
    }
    mutating func u() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func r(_ a: Double, _ b: Double) -> Double { a + (b - a) * u() }
    /// [a, b)
    mutating func i(_ a: Int, _ b: Int) -> Int { b <= a ? a : a + Int(next() % UInt64(b - a)) }
    mutating func normal() -> Double {
        let u1 = max(u(), 1e-12), u2 = u()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
    mutating func poisson(_ lam: Double) -> Int {
        let L = exp(-lam); var k = 0; var p = 1.0
        repeat { k += 1; p *= u() } while p > L && k < 200
        return k - 1
    }
    mutating func permutation(_ n: Int) -> [Int] {
        var a = Array(0..<n)
        if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, self.i(0, i + 1)) } }
        return a
    }
}

/// Smooth value noise in [-1, 1] with feature size ~`cell` px.
struct VNoise {
    let gw: Int, gh: Int
    let g: [Float]
    let inv: Float
    init(w: Int, h: Int, cell: Double, rng: inout LRng) {
        let c = max(cell, 1.0)
        gw = Int(Double(w) / c) + 3
        gh = Int(Double(h) / c) + 3
        var a = [Float](repeating: 0, count: gw * gh)
        for k in 0..<a.count { a[k] = Float(rng.u() * 2 - 1) }
        g = a
        inv = Float(1 / c)
    }
    @inline(__always) func at(_ x: Float, _ y: Float) -> Float {
        let fx = max(0, x * inv), fy = max(0, y * inv)
        var ix = Int(fx), iy = Int(fy)
        var tx = fx - Float(ix), ty = fy - Float(iy)
        if ix >= gw - 1 { ix = gw - 2; tx = 1 }
        if iy >= gh - 1 { iy = gh - 2; ty = 1 }
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
        let i0 = iy * gw + ix
        let a = g[i0] + (g[i0 + 1] - g[i0]) * tx
        let b = g[i0 + gw] + (g[i0 + gw + 1] - g[i0 + gw]) * tx
        return (a + (b - a) * ty) * 0.75
    }
}

struct FBM {
    let o: [VNoise]
    init(w: Int, h: Int, cell: Double, octaves: Int, rng: inout LRng) {
        var arr: [VNoise] = []
        for i in 0..<octaves { arr.append(VNoise(w: w, h: h, cell: cell / pow(2, Double(i)), rng: &rng)) }
        o = arr
    }
    @inline(__always) func at(_ x: Float, _ y: Float) -> Float {
        var s: Float = 0, amp: Float = 1, tot: Float = 0
        for n in o { s += amp * n.at(x, y); tot += amp; amp *= 0.5 }
        return s / tot
    }
}

// MARK: - Small float helpers

typealias C3 = SIMD3<Float>
@inline(__always) func c3(_ r: Double, _ g: Double, _ b: Double) -> C3 { C3(Float(r / 255), Float(g / 255), Float(b / 255)) }
@inline(__always) func sm(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}
@inline(__always) func mixc(_ a: C3, _ b: C3, _ t: Float) -> C3 { a + (b - a) * t }
@inline(__always) func clamp01(_ c: C3) -> C3 { simd_clamp(c, C3(repeating: 0), C3(repeating: 1)) }
@inline(__always) func wrapF(_ a: Float) -> Float {
    var r = fmodf(a + .pi, 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r - .pi
}
@inline(__always) func logaddexp(_ a: Float, _ b: Float) -> Float {
    let m = max(a, b)
    return m + log1pf(expf(-abs(a - b)))
}

/// Rasterises round-capped polylines with linearly tapering width into an N×N coverage
/// buffer (image coordinates, y down).
func strokeMask(_ N: Int, _ paths: [([V2], Double, Double)], extraCircles: [(V2, Double)] = []) -> [Float] {
    let cs = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        return [Float](repeating: 0, count: N * N)
    }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: N, height: N))
    ctx.translateBy(x: 0, y: CGFloat(N))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setStrokeColor(gray: 1, alpha: 1)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.setLineCap(.round)
    ctx.setShouldAntialias(true)
    for (pts, w0, w1) in paths where pts.count > 1 {
        let n = pts.count
        for i in 0..<(n - 1) {
            let t = Double(i) / Double(max(1, n - 2))
            ctx.setLineWidth(CGFloat(max(0.3, w0 + (w1 - w0) * t)))
            ctx.move(to: pts[i].cg)
            ctx.addLine(to: pts[i + 1].cg)
            ctx.strokePath()
        }
    }
    for (c, r) in extraCircles {
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    var out = [Float](repeating: 0, count: N * N)
    guard let data = ctx.data else { return out }
    let bpr = ctx.bytesPerRow
    let p = data.bindMemory(to: UInt8.self, capacity: bpr * N)
    for y in 0..<N {
        for x in 0..<N { out[y * N + x] = Float(p[y * bpr + x]) / 255 }
    }
    return out
}

/// Small separable gaussian blur of a single-channel N×N buffer.
func blurMask(_ m: inout [Float], _ N: Int, sigma: Double) {
    guard sigma > 0.2 else { return }
    let r = max(1, Int(ceil(sigma * 2.5)))
    var k = [Float](repeating: 0, count: 2 * r + 1)
    var sum: Float = 0
    for i in -r...r { let v = Float(exp(-Double(i * i) / (2 * sigma * sigma))); k[i + r] = v; sum += v }
    for i in 0..<k.count { k[i] /= sum }
    var tmp = [Float](repeating: 0, count: N * N)
    for y in 0..<N {
        for x in 0..<N {
            var s: Float = 0
            for i in -r...r { let xx = min(max(x + i, 0), N - 1); s += m[y * N + xx] * k[i + r] }
            tmp[y * N + x] = s
        }
    }
    for y in 0..<N {
        for x in 0..<N {
            var s: Float = 0
            for i in -r...r { let yy = min(max(y + i, 0), N - 1); s += tmp[yy * N + x] * k[i + r] }
            m[y * N + x] = s
        }
    }
}

/// Premultiplied float RGBA canvas (image coordinates, y down).
final class FLayer {
    let w: Int, h: Int
    var rgb: [C3]
    var a: [Float]
    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        rgb = [C3](repeating: C3(repeating: 0), count: w * h)
        a = [Float](repeating: 0, count: w * h)
    }
    @inline(__always) func over(_ i: Int, _ col: C3, _ alpha: Float) {
        let al = min(max(alpha, 0), 1)
        rgb[i] = col * al + rgb[i] * (1 - al)
        a[i] = al + a[i] * (1 - al)
    }
    /// Anti-aliased filled ellipse (port of Layer.ellipse).
    func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ ang: Double, _ col: C3, _ alpha: Double = 1) {
        let R = max(rx, ry) + 2
        let x0 = max(0, Int(cx - R)), x1 = min(w, Int(cx + R + 1))
        let y0 = max(0, Int(cy - R)), y1 = min(h, Int(cy + R + 1))
        guard x0 < x1, y0 < y1 else { return }
        let ca = cos(ang), sa = sin(ang)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let lx = dx * ca + dy * sa, ly = -dx * sa + dy * ca
                let q = sqrt((lx / rx) * (lx / rx) + (ly / ry) * (ly / ry)) + 1e-6
                let th = atan2(ly, lx)
                let reff = rx * ry / sqrt(pow(ry * cos(th), 2) + pow(rx * sin(th), 2))
                let cov = min(max((1 - q) * reff + 0.5, 0), 1)
                if cov > 0 { over(y * w + x, col, Float(cov * alpha)) }
            }
        }
    }
    func circle(_ cx: Double, _ cy: Double, _ r: Double, _ col: C3, _ alpha: Double = 1) {
        ellipse(cx, cy, r, r, 0, col, alpha)
    }
    /// Composites a colour through a coverage mask.
    func overMask(_ m: [Float], _ col: C3, _ k: Float) {
        for i in 0..<(w * h) where m[i] > 0.002 { over(i, col, m[i] * k) }
    }
    func cgImage() -> CGImage { makeImage(w, h) { i in (self.rgb[i], self.a[i]) } }
}

/// Builds a premultiplied RGBA8 CGImage; `px(i)` returns premultiplied colour + alpha.
func makeImage(_ w: Int, _ h: Int, _ px: (Int) -> (C3, Float)) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        let (c, a) = px(i)
        let al = min(max(a, 0), 1)
        let cc = simd_clamp(c, C3(repeating: 0), C3(repeating: al))
        bytes[i * 4 + 0] = UInt8(cc.x * 255 + 0.5)
        bytes[i * 4 + 1] = UInt8(cc.y * 255 + 0.5)
        bytes[i * 4 + 2] = UInt8(cc.z * 255 + 0.5)
        bytes[i * 4 + 3] = UInt8(al * 255 + 0.5)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: Painter.colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

// MARK: - Lily pads

enum PadKind: Int, CaseIterable { case yellowgreen, fresh, mint, blue, young }

struct PadParams {
    var kind: PadKind = .fresh
    var aspect = 1.0, aspectAng = 0.0
    var kidney = 0.0, kidneyAng = 0.0
    var waveAmp = 0.012, waveFreq = 7
    var nibbles = 0
    var notch: Double? = nil
    var old = false
    var nDrops = 8
    var centerDrop = false
    var seed: UInt64 = 0

    /// Port of random_pad_params(rng, r_final).
    static func random(_ rng: inout LRng, rFinal: Double) -> PadParams {
        var p = PadParams()
        let u = rng.u()
        p.kind = u < 0.22 ? .yellowgreen : u < 0.52 ? .fresh : u < 0.75 ? .mint : u < 0.955 ? .blue : .young
        p.aspect = rng.u() < 0.7 ? rng.r(0.74, 1.0) : 1.0
        p.aspectAng = rng.r(0, .pi)
        p.kidney = rng.u() < 0.3 ? rng.r(0.12, 0.24) : 0
        p.kidneyAng = rng.r(0, 2 * .pi)
        p.waveAmp = rng.r(0.006, 0.03)
        p.waveFreq = rng.i(5, 13)
        p.nibbles = rng.u() < 0.22 ? rng.i(1, 4) : 0
        p.notch = rng.u() < 0.45 ? rng.r(0, 2 * .pi) : nil
        p.old = rng.u() < 0.07 && p.kind != .young
        p.seed = rng.next()
        let area = pow(rFinal / 100, 2)
        p.nDrops = rFinal > 34 ? min(26, max(0, rng.poisson(14 * area))) : rng.i(0, 2)
        p.centerDrop = rFinal > 70 && rng.u() < 0.6
        return p
    }
}

enum LilyArt {
    static let light: Float = -135 * .pi / 180      // image coords, y down → top-left
    /// Texture pixels per layout unit (1 unit = 1 pt on a 900 pt tall screen).
    static let pxPerUnit = 2.7

    static let palettes: [PadKind: (C3, C3, C3, C3)] = [
        .yellowgreen: (c3(118, 156, 62), c3(150, 186, 74), c3(176, 204, 96), c3(226, 238, 170)),
        .fresh: (c3(84, 148, 70), c3(116, 176, 82), c3(146, 198, 100), c3(210, 236, 180)),
        .mint: (c3(80, 152, 112), c3(106, 178, 134), c3(132, 198, 154), c3(214, 242, 224)),
        .blue: (c3(52, 116, 102), c3(74, 140, 120), c3(98, 162, 138), c3(184, 222, 206)),
        .young: (c3(140, 152, 96), c3(176, 142, 116), c3(196, 146, 136), c3(236, 210, 200))
    ]

    /// Port of pad_v3. `nPy` is the size the mockup would use for this pad (keeps vein
    /// count / strength identical); `N` is the actual texture size.
    static func pad(N: Int, nPy: Double, _ p: PadParams) -> CGImage {
        var rng = LRng(p.seed)
        let Rd = 0.46 * Double(N)
        let R = Float(Rd)
        let c = Float(N) / 2
        let sc = Float(N) / 600
        let vis = Float(min(max((nPy - 60) / 360, 0.25), 1.0))
        let L = light
        let cosL = cos(L), sinL = sin(L)
        let ph = (0..<6).map { _ in rng.r(0, 2 * .pi) }

        func redgeF(_ a: Double) -> Double {
            let ca: Double = cos(a - p.aspectAng), sa: Double = sin(a - p.aspectAng) / p.aspect
            var e: Double = 1.0 / sqrt(ca * ca + sa * sa)
            let wk = Double(wrapF(Float(a - p.kidneyAng)))
            e *= 1 - p.kidney * exp(-pow(wk / 0.34, 2))
            let f = Double(p.waveFreq)
            let w1: Double = p.waveAmp * sin(f * a + ph[0])
            let w2: Double = p.waveAmp * 0.5 * sin(2.3 * f * a + ph[1])
            e *= 1 + w1 + w2 + 0.004 * sin(17 * a + ph[2])
            return Rd * e
        }
        // Lookup table over the angle (the outline is evaluated for every pixel).
        let TN = 2048
        var tbl = [Float](repeating: 0, count: TN + 1)
        for i in 0...TN { tbl[i] = Float(redgeF(-.pi + 2 * .pi * Double(i) / Double(TN))) }
        @inline(__always) func redgeT(_ th: Float) -> Float {
            let f = (th + .pi) / (2 * .pi) * Float(TN)
            let i = min(max(Int(f), 0), TN - 1)
            let t = f - Float(i)
            return tbl[i] + (tbl[i + 1] - tbl[i]) * t
        }

        // nibbled bites
        var bites: [(Float, Float, Float)] = []
        for _ in 0..<p.nibbles {
            let a = rng.r(0, 2 * .pi)
            let br = Rd * rng.r(0.06, 0.11)
            let rr = redgeF(a) + br * 0.25
            let bx = Double(c) + rr * cos(a), by = Double(c) + rr * sin(a)
            for _ in 0..<rng.i(1, 4) {
                let ox = rng.normal() * br * 0.5, oy = rng.normal() * br * 0.5
                bites.append((Float(bx + ox), Float(by + oy), Float(br * rng.r(0.6, 1.0))))
            }
        }

        let palette = palettes[p.kind]!
        var c0 = palette.0, c1 = palette.1, c2 = palette.2
        let rimc = palette.3
        let jit = C3(1, 1, 1) + C3(Float(rng.r(-0.04, 0.04)), Float(rng.r(-0.04, 0.04)), Float(rng.r(-0.04, 0.04)))
        c0 *= jit; c1 *= jit; c2 *= jit
        var grooveC = clamp01(c1 * 0.58 + c3(0, 6, 8))
        let ridgeC = clamp01(mixc(c1, C3(1, 1, 1), 0.45))
        if p.kind == .young { grooveC = clamp01(c1 * 0.70) }

        // vein angles
        let nveins = Int(min(max(10 + nPy / 60, 11), 19))
        let bend = rng.r(-0.10, 0.10)
        let ref = p.notch ?? rng.r(0, 2 * .pi)
        var va: [Double]
        let edges: [Double]
        if p.notch != nil {
            let lo = 0.17, hi = 2 * Double.pi - 0.17
            let step: Double = (hi - lo) / Double(nveins - 1)
            va = []
            for i in 0..<nveins {
                let base: Double = lo + step * Double(i)
                let jitter: Double = rng.r(-0.18, 0.18) * step
                va.append(base + jitter)
            }
            va.sort()
            edges = [0] + va + [2 * .pi]
        } else {
            let gap0 = 2 * Double.pi / Double(nveins)
            va = []
            for i in 0..<nveins {
                let base: Double = Double(i) * gap0
                let jitter: Double = rng.r(-0.18, 0.18) * gap0
                va.append(fmod(base + jitter + 4 * Double.pi, 2 * Double.pi))
            }
            va.sort()
            let v0 = va[0]
            va = va.map { $0 - v0 }
            edges = va + [2 * .pi]
        }
        let gap = 2 * Double.pi / Double(nveins)
        let edgesF = edges.map { Float($0) }
        let nE = edgesF.count
        let hasNotch = p.notch != nil

        let nlow = FBM(w: N, h: N, cell: Double(N) / 5, octaves: 3, rng: &rng)
        let nmid = FBM(w: N, h: N, cell: Double(N) / 25, octaves: 3, rng: &rng)
        let nfine = VNoise(w: N, h: N, cell: max(1.5, Double(N) / 140), rng: &rng)
        let tilt = (0..<nE).map { _ in Float(rng.r(-0.035, 0.035)) }

        // vein strokes (groove + ridge), rasterised like tapered_cov
        var groove: [([V2], Double, Double)] = []
        var ridgeL: [([V2], Double, Double)] = []
        let rStart = Rd * (p.centerDrop ? 0.095 : 0.035)
        let scD = Double(sc)
        let off = max(1.2, 2.3 * scD)
        let cD = Double(c)
        for a in va {
            let re = redgeF(ref + a + bend) * 0.965
            var g: [V2] = [], rl: [V2] = []
            for i in 0..<32 {
                let s = Double(i) / 31
                let rr = rStart + (re - rStart) * s
                let aa = ref + a + bend * pow(rr / Rd, 1.6) + 0.006 * sin(s * 9 + a * 3)
                let x = cD + rr * cos(aa), y = cD + rr * sin(aa)
                g.append(V2(x, y))
                rl.append(V2(x - off * sin(aa), y + off * cos(aa)))
            }
            groove.append((g, max(1.2, 3.2 * scD), max(0.8, 1.4 * scD)))
            ridgeL.append((rl, max(1.0, 2.0 * scD), max(0.7, 0.9 * scD)))
            if nPy > 250 && rng.u() < 0.45 {
                let rf = Rd * rng.r(0.58, 0.75)
                let da = gap * rng.r(0.18, 0.28) * (rng.u() < 0.5 ? 1 : -1)
                var g2: [V2] = [], r2: [V2] = []
                for i in 0..<14 {
                    let s = Double(i) / 13
                    let rr = rf + (re - rf) * s
                    let aa = ref + a + bend * pow(rr / Rd, 1.6) + da * pow(s, 1.3)
                    let x = cD + rr * cos(aa), y = cD + rr * sin(aa)
                    g2.append(V2(x, y))
                    r2.append(V2(x - off * 0.8 * sin(aa), y + off * 0.8 * cos(aa)))
                }
                groove.append((g2, 1.8 * scD, 1.0 * scD))
                ridgeL.append((r2, 1.3 * scD, 0.7 * scD))
            }
        }
        var gm = strokeMask(N, groove)
        var rm = strokeMask(N, ridgeL)
        blurMask(&gm, N, sigma: max(0.5, 0.7 * scD))
        blurMask(&rm, N, sigma: max(0.5, 0.8 * scD))

        var col = [C3](repeating: C3(repeating: 0), count: N * N)
        var cov = [Float](repeating: 0, count: N * N)
        let refF = Float(ref), bendF = Float(bend)
        let oldA = c3(196, 172, 80), oldB = c3(128, 96, 46), biteC = c3(130, 104, 56)
        let rimC = p.old ? c3(232, 214, 150) : rimc
        let youngC = c3(190, 128, 124)
        let sheenC = c3(220, 255, 235)
        let centreC = mixc(c2, c3(240, 248, 220), 0.6)
        let slx = c + cosL * R * 0.4, sly = c + sinL * R * 0.4

        for y in 0..<N {
            let yy = Float(y) + 0.5
            for x in 0..<N {
                let xx = Float(x) + 0.5
                let dx = xx - c, dy = yy - c
                let rho = sqrtf(dx * dx + dy * dy) + 1e-4
                if rho > R * 1.45 { continue }
                let th = atan2f(dy, dx)
                var redge = redgeT(th)
                var d = redge - rho
                if let notch = p.notch {
                    let phi = abs(wrapF(th - Float(notch)))
                    let q = (phi - 0.2) / 0.35
                    redge *= 1 - 0.03 * expf(-q * q)
                    let half = 0.11 * (0.5 + 0.5 * min(max(rho / R, 0), 1)) * sm(0.07, 0.22, rho / R)
                    let kk = 0.02 * R
                    d = -kk * logaddexp(-(redge - rho) / kk, -((phi - half) * rho) / kk)
                }
                var dBite: Float = 1e3
                for (bx, by, br) in bites {
                    let ddx = xx - bx, ddy = yy - by
                    dBite = min(dBite, sqrtf(ddx * ddx + ddy * ddy) - br)
                }
                d = min(d, dBite)
                let cv = min(max(d + 0.5, 0), 1)
                let i = y * N + x
                if cv <= 0 { continue }
                cov[i] = cv
                let t = min(max(rho / redge, 0), 1)

                // vein sector
                let swirl = bendF * powf(rho / R, 1.6)
                var psi = fmodf(th - refF - swirl, 2 * .pi)
                if psi < 0 { psi += 2 * .pi }
                var k = 0
                while k < nE - 2 && edgesF[k + 1] <= psi { k += 1 }
                let a0 = edgesF[k], a1 = edgesF[k + 1]
                let f = min(max((psi - a0) / max(a1 - a0, 1e-4), 0), 1)
                let dNext = (a1 - psi) * rho, dPrev = (psi - a0) * rho
                let nxt: Float = hasNotch ? (k < nE - 2 ? 1 : 0) : 1
                let prv: Float = hasNotch ? (k > 0 ? 1 : 0) : 1

                let nl = nlow.at(xx, yy), nm = nmid.at(xx, yy), nf = nfine.at(xx, yy)
                var cc = t < 0.6 ? mixc(c0, c1, sm(0, 0.6, t)) : mixc(c1, c2, sm(0.6, 1, t))
                if p.kind == .young { cc = mixc(cc, youngC, sm(0.2, 0.7, nl * 0.5 + 0.5) * 0.25) }
                let lamb = (dx * cosL + dy * sinL) / R
                let lightK: Float = 1 + 0.07 * lamb + 0.035 * nl
                cc *= lightK + 0.025 * nm + 0.015 * nf
                let midA = (a0 + a1) / 2 + refF
                let pTilt: Float = 0.045 * cosf(midA - L) * sm(0.15, 0.7, t)
                let pConc: Float = 0.05 * (1 - sqrtf(max(0, sinf(Float.pi * f))))
                var panel: Float = 1 + (tilt[k] + pTilt - pConc) * vis
                let cf = sm(0.06, 0.2, t)
                let crease: Float = 0.10 * vis * expf(-dNext / (9 * sc)) * nxt * cf
                let ridgeLit: Float = 0.05 * vis * expf(-dPrev / (7 * sc)) * prv * cf
                panel = panel - crease + ridgeLit
                cc *= panel

                let vf = (1 - 0.35 * sm(0.85, 1.0, t)) * (0.45 + 0.55 * vis)
                cc = mixc(cc, ridgeC, rm[i] * 0.55 * vf)
                cc = mixc(cc, grooveC, gm[i] * 0.70 * vf)

                if p.old {
                    let yel = sm(0.70, 1.0, t + 0.22 * nl + 0.08 * nm)
                    cc = mixc(cc, oldA * (1 + 0.08 * nm), yel * 0.85)
                    cc = mixc(cc, oldB, sm(0.45, 0.75, nm * 0.8 + nf * 0.4) * sm(0.7, 0.97, t) * 0.55)
                }
                if p.nibbles > 0 { cc = mixc(cc, biteC, expf(-max(dBite, 0) / (2.5 * sc + 0.8)) * 0.55) }
                let q1 = (d - 4.2 * sc) / (1.6 * sc + 0.4)
                cc *= 1 - 0.14 * expf(-q1 * q1)
                let q2 = (d - 1.2 * sc) / (1.3 * sc + 0.35)
                cc = mixc(cc, rimC, min(max(expf(-q2 * q2) * (0.6 + 0.25 * min(max(-lamb, 0), 1)), 0), 0.9))
                let sx = (xx - slx) / (R * 0.6), sy = (yy - sly) / (R * 0.45)
                cc += sheenC * (expf(-(sx * sx + sy * sy)) * 0.05)
                if !p.centerDrop {
                    let q3 = rho / max(1.2, 0.028 * R)
                    cc = mixc(cc, centreC, expf(-q3 * q3) * 0.85)
                }
                col[i] = clamp01(cc)
            }
        }

        // droplets
        var drops: [(Double, Double, Double)] = []
        if p.centerDrop { drops.append((cD, cD, Rd * 0.095)) }
        var tries = 0
        let want = p.nDrops + (p.centerDrop ? 1 : 0)
        while drops.count < want && tries < 2000 {
            tries += 1
            var pr = Rd * (0.011 + 0.050 * pow(rng.u(), 2.2))
            if p.nDrops >= 12 && drops.count < 3 + (p.centerDrop ? 1 : 0) { pr = Rd * rng.r(0.06, 0.08) }
            pr = max(pr, 2.2)
            let rr = Rd * sqrt(rng.r(0.03, 0.72)), a = rng.r(0, 2 * .pi)
            if let notch = p.notch, abs(Double(wrapF(Float(a - notch)))) < 0.35 { continue }
            let px = cD + rr * cos(a), py = cD + rr * sin(a)
            if rr + pr > redgeF(a) * 0.88 { continue }
            if drops.contains(where: { hypot(px - $0.0, py - $0.1) < (pr + $0.2) * 1.5 }) { continue }
            drops.append((px, py, pr))
        }
        for (px, py, pr) in drops {
            droplet(&col, N, Float(px), Float(py), Float(pr), rimCol: grooveC)
        }
        return makeImage(N, N) { i in (col[i] * cov[i], cov[i]) }
    }

    /// Port of draw_droplet: clear bead with magnified leaf, contact shadow, rim,
    /// caustic crescent and specular highlights.
    static func droplet(_ col: inout [C3], _ N: Int, _ px: Float, _ py: Float, _ pr: Float, rimCol: C3, strength: Float = 1) {
        let pad = pr * 1.8 + 3
        let y0 = max(0, Int(py - pad)), y1 = min(N, Int(py + pad + 1))
        let x0 = max(0, Int(px - pad)), x1 = min(N, Int(px + pad + 1))
        guard y0 < y1, x0 < x1 else { return }
        let lx = cosf(light), ly = sinf(light)
        let ox = -lx * pr * 0.38, oy = -ly * pr * 0.38
        for y in y0..<y1 {
            for x in x0..<x1 {
                let X = Float(x) + 0.5, Y = Float(y) + 0.5
                let dsh = hypotf(X - px - ox, Y - py - oy) / (pr * 1.02)
                let sh = 1 - sm(0.75, 1.25, dsh)
                col[y * N + x] *= 1 - 0.30 * strength * sh
            }
        }
        let bw = x1 - x0, bh = y1 - y0
        var snap = [C3](repeating: C3(repeating: 0), count: bw * bh)
        for y in 0..<bh { for x in 0..<bw { snap[y * bw + x] = col[(y + y0) * N + x + x0] } }
        @inline(__always) func sample(_ sx: Float, _ sy: Float) -> C3 {
            let fx = min(max(sx - 0.5 - Float(x0), 0), Float(bw - 1))
            let fy = min(max(sy - 0.5 - Float(y0), 0), Float(bh - 1))
            let ix = min(Int(fx), bw - 2 < 0 ? 0 : bw - 2), iy = min(Int(fy), bh - 2 < 0 ? 0 : bh - 2)
            let tx = fx - Float(ix), ty = fy - Float(iy)
            let ix1 = min(ix + 1, bw - 1), iy1 = min(iy + 1, bh - 1)
            let a = snap[iy * bw + ix] + (snap[iy * bw + ix1] - snap[iy * bw + ix]) * tx
            let b = snap[iy1 * bw + ix] + (snap[iy1 * bw + ix1] - snap[iy1 * bw + ix]) * tx
            return a + (b - a) * ty
        }
        let rimCol8 = rimCol * 0.8
        let bodyAdd = c3(16, 22, 18), cauC = c3(225, 255, 235), g2C = c3(250, 255, 250)
        let cx_ = px - lx * pr * 0.42, cy_ = py - ly * pr * 0.42
        let spx = px + lx * pr * 0.42, spy = py + ly * pr * 0.42
        let gx = px - lx * pr * 0.5, gy = py - ly * pr * 0.5
        for y in y0..<y1 {
            for x in x0..<x1 {
                let X = Float(x) + 0.5, Y = Float(y) + 0.5
                let dd = hypotf(X - px, Y - py)
                let cv = min(max(pr - dd + 0.5, 0), 1)
                if cv <= 0 { continue }
                let q = dd / pr
                let ref = sample(px + (X - px) * 0.5, py + (Y - py) * 0.5)
                let lam = ((X - px) * lx + (Y - py) * ly) / pr
                var body = ref * 1.10 + bodyAdd * (0.5 + 0.5 * min(max(-lam, 0), 1))
                let rimw = sm(0.68, 0.97, q) * (1 - sm(0.97, 1.05, q))
                body = mixc(body, rimCol8, rimw * (0.38 + 0.32 * min(max(lam + 0.2, 0), 1)) * strength)
                let qc = hypotf(X - cx_, Y - cy_) / (pr * 0.38)
                body += cauC * (expf(-qc * qc) * (q < 1 ? 1 : 0) * 0.30)
                let spec = expf(-powf(hypotf(X - spx, Y - spy) / (pr * 0.21), 2.4))
                body = mixc(body, C3(1, 1, 1), min(max(spec, 0), 1))
                let qg = hypotf(X - gx, Y - gy) / (pr * 0.09)
                body = mixc(body, g2C, expf(-qg * qg) * 0.55)
                let i = y * N + x
                col[i] = mixc(col[i], clamp01(body), cv)
            }
        }
    }

    // MARK: - Lotus

    typealias Pal = (C3, C3, C3, C3)   // cream, blush, pink, deep
    static let pinkA: Pal = (c3(253, 248, 236), c3(246, 196, 214), c3(232, 108, 152), c3(214, 80, 132))
    static let pinkB: Pal = (c3(253, 249, 240), c3(248, 206, 220), c3(238, 128, 166), c3(222, 98, 146))

    /// Port of after_petal, evaluated only inside the petal's bounding box. The
    /// between-layer shadow (a blurred, offset copy of the petal in the mockup) is
    /// approximated analytically from the petal's distance field.
    static func petal(_ tex: FLayer, _ rng: inout LRng, _ bx: Double, _ by: Double, _ ang: Double, _ Lp: Double, _ Wp: Double,
                      _ pal: Pal, pinkness: Float = 1, bright: Float = 0, edgeDark: Float = 0.12, shadow: Float = 0.30,
                      a: Double = 0.9, b: Double = 0.7, veinK: Float = 13, pinkBase: Float = 0) {
        let N = tex.w
        let sc = Float(N) / 512
        let ca = cos(ang), sa = sin(ang)
        let peak = pow(a / (a + b), a) * pow(b / (a + b), b)
        let nz = VNoise(w: N, h: N, cell: 18 * Double(sc), rng: &rng)
        let nv = VNoise(w: N, h: N, cell: 30 * Double(sc), rng: &rng)
        let sig = 4.5 * Double(sc)
        let shOff = 2 * Double(sc)
        let marg = Wp * 1.2 + sig * 3 + shOff + 2
        var xs: [Double] = [], ys: [Double] = []
        for (u, v) in [(-marg, -marg), (Lp + marg, -marg), (-marg, marg), (Lp + marg, marg)] {
            xs.append(bx + u * ca - v * sa); ys.append(by + u * sa + v * ca)
        }
        let x0 = max(0, Int(xs.min()!)), x1 = min(N, Int(xs.max()!) + 1)
        let y0 = max(0, Int(ys.min()!)), y1 = min(N, Int(ys.max()!) + 1)
        guard x0 < x1, y0 < y1 else { return }
        let aF = Float(a), bF = Float(b), peakF = Float(peak), LF = Float(Lp), WF = Float(Wp)
        let caF = Float(ca), saF = Float(sa), bxF = Float(bx), byF = Float(by)

        @inline(__always) func field(_ X: Float, _ Y: Float) -> (u: Float, vy: Float, hw: Float, dist: Float) {
            let ux = (X - bxF) * caF + (Y - byF) * saF
            let vy = -(X - bxF) * saF + (Y - byF) * caF
            let u = ux / LF
            let uc = min(max(u, 1e-4), 1 - 1e-4)
            var hw = WF * powf(uc, aF) * powf(1 - uc, bF) / peakF
            hw *= 1 + 0.06 * sinf(uc * 3.1)
            return (u, vy, hw, hw - abs(vy))
        }
        let (cream, blush, pink, deep) = pal
        let baseC = c3(242, 236, 190), veinC = c3(236, 190, 210), shC = c3(0, 40, 20)
        let side0 = Float(sin(ang - Double(light)))
        let sigF = Float(sig), shOffF = Float(shOff)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let X = Float(x) + 0.5, Y = Float(y) + 0.5
                let i = y * N + x
                if shadow > 0 && tex.a[i] > 0 {
                    let fs = field(X - shOffF, Y - shOffF)
                    let sv = sm(-2 * sigF, 2 * sigF, fs.dist)
                    let su = sm(-2 * sigF, 2 * sigF, fs.u * LF) * sm(-2 * sigF, 2 * sigF, (1 - fs.u) * LF)
                    let sh = sv * su
                    if sh > 0.001 {
                        tex.rgb[i] *= 1 - shadow * sh
                        tex.rgb[i] = simd_max(tex.rgb[i] - shC * (shadow * 0.25 * sh * tex.a[i]), C3(repeating: 0))
                    }
                }
                let fl = field(X, Y)
                if fl.u <= 0 || fl.u >= 1 { continue }
                let cv = min(max(fl.dist + 0.5, 0), 1)
                if cv <= 0 { continue }
                let s = min(max(abs(fl.vy) / max(fl.hw, 1e-3), 0), 1)
                let uc = min(max(fl.u, 0), 1)
                let pBase: Float = powf(sm(0.12, 1.0, uc + 0.05 * nz.at(X, Y)), 1.25)
                var pp: Float = pBase * (0.78 + 0.22 * s) + 0.18 * s * s * uc
                pp = min(max(pp * pinkness, 0), 1)
                pp += pinkBase * (1 - pp) * sm(0, 0.35, uc)
                var cc = pp < 0.45 ? mixc(cream, blush, pp / 0.45) : mixc(blush, pink, min((pp - 0.45) / 0.55, 1))
                cc = mixc(cc, deep, sm(0.86, 1.0, uc) * 0.5 * pinkness)
                cc = mixc(cc, baseC, sm(0.14, 0, uc) * 0.55)
                let q = fl.vy / max(fl.hw, 1e-3) + 0.025 * nv.at(X, Y)
                var vf = powf(0.5 + 0.5 * cosf(.pi * veinK * q), 6)
                vf *= sm(0.06, 0.35, uc) * (1 - sm(0.85, 1, uc)) * (1 - 0.6 * s)
                cc = mixc(cc, cc * veinC, vf * 0.55)
                var shade = 1 - edgeDark * powf(s, 2.2) + 0.035 * powf(1 - s, 3)
                let side: Float = (fl.vy > 0 ? 1 : (fl.vy < 0 ? -1 : 0)) * side0
                shade = shade * (1 + 0.04 * side * s) + bright
                cc *= shade
                let edge = expf(-max(fl.dist, 0) / (1.1 * sc))
                cc *= 1 - 0.10 * edge
                tex.over(i, clamp01(cc), cv)
            }
        }
    }

    /// Port of stamens_and_pod.
    static func stamensAndPod(_ tex: FLayer, _ rng: inout LRng, _ cx: Double, _ cy: Double, _ rp: Double,
                              n: Int = 90, slen: Double = 0.65, vis: Double = 1) {
        let N = tex.w
        let sc = Double(N) / 512
        let rr0 = Int(rp * 3)
        for y in max(0, Int(cy) - rr0)..<min(N, Int(cy) + rr0) {
            for x in max(0, Int(cx) - rr0)..<min(N, Int(cx) + rr0) {
                let r = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
                let q = (r - rp * 1.1) / (rp * 0.5)
                tex.rgb[y * N + x] *= Float(1 - 0.25 * exp(-q * q))
            }
        }
        var lines: [([V2], Double, Double)] = []
        var anth: [(V2, Double)] = []
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi + rng.r(-0.05, 0.05)
            let l = rp * slen * rng.r(0.75, 1.15)
            let curl = rng.r(-0.25, 0.25)
            let r0 = rp * 0.92
            var pts: [V2] = []
            for k in 0..<6 {
                let s = Double(k) / 5
                pts.append(V2(cx + (r0 + l * s) * cos(a + curl * s * s), cy + (r0 + l * s) * sin(a + curl * s * s)))
            }
            lines.append((pts, 1.1 * sc, 1.1 * sc))
            anth.append((pts[5], a + curl))
        }
        let fil = strokeMask(N, lines)
        tex.overMask(fil, c3(246, 222, 132), Float(0.95 * vis))
        for (p, a) in anth {
            tex.ellipse(p.x, p.y, 2.6 * sc, 1.3 * sc, a, c3(236, 178, 54), 0.95 * vis)
            tex.ellipse(p.x - 0.5 * sc, p.y - 0.5 * sc, 1.2 * sc, 0.6 * sc, a, c3(255, 230, 130), 0.7 * vis)
        }
        let lx = cos(Double(light)), ly = sin(Double(light))
        let R0 = Int(rp + 2)
        for y in max(0, Int(cy) - R0)..<min(N, Int(cy) + R0 + 1) {
            for x in max(0, Int(cx) - R0)..<min(N, Int(cx) + R0 + 1) {
                let X = Double(x) + 0.5, Y = Double(y) + 0.5
                let r = hypot(X - cx, Y - cy)
                let pc = min(max(rp - r + 0.5, 0), 1)
                if pc <= 0 { continue }
                let q = Float(r / rp)
                let lam = Float(((X - cx) * lx + (Y - cy) * ly) / rp)
                var cc = mixc(c3(222, 228, 120), c3(168, 186, 70), sm(0.2, 1.0, q))
                cc *= 1 + 0.08 * min(max(lam, -1), 1)
                cc = mixc(cc, c3(130, 150, 52), sm(0.82, 1.0, q) * 0.6)
                tex.over(y * N + x, clamp01(cc), Float(pc))
            }
        }
        var holes: [(Double, Double)] = [(0, 0)]
        for k in 0..<8 {
            let a = Double(k) * 2 * .pi / 8 + 0.3
            holes.append((cos(a) * 0.58, sin(a) * 0.58))
        }
        for (hx, hy) in holes {
            let x = cx + hx * rp, y = cy + hy * rp
            let hr = rp * 0.12
            tex.circle(x - lx * hr * 0.3, y - ly * hr * 0.3, hr * 1.08, c3(236, 240, 150), 0.5)
            tex.circle(x, y, hr, c3(112, 124, 40), 0.9)
            tex.circle(x + lx * hr * 0.25, y + ly * hr * 0.25, hr * 0.55, c3(84, 96, 30), 0.6)
        }
    }

    static func lotusOpen(N: Int, seed: UInt64, pal: Pal = pinkA) -> CGImage {
        var rng = LRng(seed)
        let tex = FLayer(N, N)
        let S = Double(N), c = S / 2
        let layers: [(Int, Double, Double, Double, Float, Float, Float, Double)] = [
            (10, 0.47, 0.105, 0.02, 1.00, -0.02, 0.16, 0.0),
            (9, 0.39, 0.098, 0.02, 0.90, 0.00, 0.12, 0.33),
            (8, 0.30, 0.086, 0.02, 0.72, 0.03, 0.09, 0.12),
            (6, 0.205, 0.070, 0.02, 0.55, 0.05, 0.06, 0.55)
        ]
        for (cnt, ln, wd, r0, pk, br, ed, rot) in layers {
            for i in rng.permutation(cnt) {
                let a = rot + Double(i) / Double(cnt) * 2 * .pi + rng.r(-0.09, 0.09)
                let L = ln * S * rng.r(0.93, 1.04)
                let W = wd * S * rng.r(0.92, 1.06)
                petal(tex, &rng, c + cos(a) * r0 * S, c + sin(a) * r0 * S, a, L, W, pal,
                      pinkness: pk, bright: br, edgeDark: ed, shadow: 0.26)
            }
        }
        stamensAndPod(tex, &rng, c, c, 0.072 * S)
        return tex.cgImage()
    }

    static func lotusHalf(N: Int, seed: UInt64, pal: Pal = pinkB) -> CGImage {
        var rng = LRng(seed)
        let tex = FLayer(N, N)
        let S = Double(N), c = S / 2
        let outer: [(Int, Double, Double, Float, Float, Float, Double)] = [(8, 0.44, 0.13, 1.0, -0.02, 0.16, 0.0), (7, 0.35, 0.125, 0.9, 0.0, 0.13, 0.4)]
        for (cnt, ln, wd, pk, br, ed, rot) in outer {
            for i in rng.permutation(cnt) {
                let a = rot + Double(i) / Double(cnt) * 2 * .pi + rng.r(-0.08, 0.08)
                petal(tex, &rng, c, c, a, ln * S * rng.r(0.94, 1.03), wd * S, pal,
                      pinkness: pk, bright: br, edgeDark: ed, shadow: 0.28, a: 0.8, b: 0.8)
            }
        }
        stamensAndPod(tex, &rng, c, c, 0.05 * S, n: 60, slen: 0.9)
        for y in 0..<N {
            for x in 0..<N {
                let r = hypot(Double(x) + 0.5 - c, Double(y) + 0.5 - c) / (0.12 * S)
                tex.rgb[y * N + x] *= Float(1 - 0.22 * exp(-r * r))
            }
        }
        let inner: [(Int, Double, Double, Double, Float, Double)] = [(6, 0.27, 0.20, 0.095, 0.95, 0.2), (5, 0.19, 0.135, 0.08, 0.85, 0.75)]
        for (cnt, rb, ln, wd, pk, rot) in inner {
            for i in rng.permutation(cnt) {
                let a = rot + Double(i) / Double(cnt) * 2 * .pi + rng.r(-0.08, 0.08)
                let bx = c + cos(a) * rb * S, by = c + sin(a) * rb * S
                petal(tex, &rng, bx, by, a + .pi + rng.r(-0.12, 0.12), ln * S, wd * S, pal,
                      pinkness: pk, bright: -0.02, edgeDark: 0.14, shadow: 0.34, a: 0.75, b: 0.75, veinK: 11, pinkBase: 0.42)
            }
        }
        return tex.cgImage()
    }

    /// Closed bud seen from above, pointing +x, stalk entering from the left edge.
    static func bud(N: Int, seed: UInt64) -> CGImage {
        var rng = LRng(seed)
        let tex = FLayer(N, N)
        let S = Double(N)
        let bx = 0.14 * S, by = 0.5 * S
        let stalk = strokeMask(N, [([V2(0, 0.53 * S), V2(bx + 0.04 * S, by)], 0.07 * S, 0.07 * S)])
        tex.overMask(stalk, c3(70, 110, 52), 0.9)
        let budPal: Pal = (c3(206, 220, 160), c3(238, 172, 196), c3(226, 96, 144), c3(200, 66, 120))
        petal(tex, &rng, bx, by, 0.0, 0.80 * S, 0.23 * S, budPal, pinkness: 1, bright: -0.03, edgeDark: 0.22, shadow: 0, a: 0.55, b: 1.0, veinK: 9, pinkBase: 0.25)
        petal(tex, &rng, bx + 0.02 * S, by + 0.02 * S, -0.035, 0.775 * S, 0.17 * S, budPal, pinkness: 1, bright: 0, edgeDark: 0.18, shadow: 0.35, a: 0.6, b: 1.0, veinK: 8, pinkBase: 0.25)
        petal(tex, &rng, bx + 0.04 * S, by - 0.025 * S, 0.045, 0.745 * S, 0.13 * S, budPal, pinkness: 1, bright: 0.03, edgeDark: 0.14, shadow: 0.35, a: 0.6, b: 1.0, veinK: 7, pinkBase: 0.25)
        let sgn: Float = sin(Double(light)) < 0 ? 1 : -1
        for y in 0..<N {
            for x in 0..<N {
                let i = y * N + x
                guard tex.a[i] > 0 else { continue }
                let v = Float((Double(y) + 0.5 - by) / (0.23 * S))
                let xn = Float((Double(x) + 0.5) / S)
                tex.rgb[i] *= 1 + 0.10 * min(max(-v, -1), 1) * sgn - 0.12 * powf(min(abs(v), 1), 2)
                let gq = (v + 0.45) / 0.12
                let gloss = expf(-gq * gq) * sm(0.2, 0.45, xn) * (1 - sm(0.65, 0.85, xn))
                tex.rgb[i] += C3(repeating: gloss * 0.16 * tex.a[i])
                tex.rgb[i] = simd_clamp(tex.rgb[i], C3(repeating: 0), C3(repeating: tex.a[i]))
            }
        }
        return tex.cgImage()
    }

    // MARK: - Shadows

    /// Black, blurred copy of an image's alpha with a transparent margin of `margin`
    /// (fraction of the side) so the blur is not clipped. Rendered at `scale` of the
    /// source resolution.
    static func shadowImage(_ img: CGImage, sigmaPx: Double, scale: Double, margin: Double) -> CGImage {
        let w = Double(img.width) * scale, h = Double(img.height) * scale
        let mw = w * margin, mh = h * margin
        let pw = Int(w + 2 * mw), ph = Int(h + 2 * mh)
        let base = Painter.image(pw: pw, ph: ph) { ctx in
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: mw, y: mh, width: w, height: h))
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        }
        return Painter.blurred(base, radius: sigmaPx * scale)
    }
}

// MARK: - Texture pool (generated once per launch, off the main thread)

struct PadTexture {
    let image: CGImage
    let shadow: CGImage       // black blurred alpha, side = (1 + 2*shadowMargin) × pad side
    let shadowMargin: Double
}

struct FlowerTexture {
    let image: CGImage
    let shadow: CGImage
    let shadowMargin: Double
}

final class LilyBank: @unchecked Sendable {
    static let shared = LilyBank()

    /// Size classes: nominal radius in layout units (pt on a 900 pt tall screen).
    static let classRadius: [Double] = [110, 64, 36]
    static let classCount = [8, 9, 7]

    let pads: [[PadTexture]]          // [class][variant]
    let openLotus: [FlowerTexture]
    let halfLotus: [FlowerTexture]
    let buds: [FlowerTexture]
    let buildSeconds: Double

    private init() {
        let t0 = Date()
        var master = LRng(UInt64.random(in: 1...UInt64.max))
        // Pad parameter list (main RNG, deterministic order), then render in parallel.
        var jobs: [(cls: Int, N: Int, nPy: Double, p: PadParams)] = []
        for (cls, rc) in LilyBank.classRadius.enumerated() {
            let lo = [85.0, 48.0, 26.0][cls], hi = [126.0, 85.0, 48.0][cls]
            for _ in 0..<LilyBank.classCount[cls] {
                let rF = master.r(lo, hi)
                let p = PadParams.random(&master, rFinal: rF)
                let N = Int((2 * rc / 0.92 * LilyArt.pxPerUnit).rounded())
                jobs.append((cls, N, 2 * rF * 2 / 0.92, p))
            }
        }
        // A pool of 24 is too small to trust plain random draws (one unlucky launch got
        // four reddish leaves), so assign the mockup's palette mix by quota instead:
        // ≈22% yellow-green, 30% fresh, 23% mint, 20% blue-green, exactly one young
        // reddish leaf (≈4%) and two yellowed old ones (≈7%), shuffled over the classes.
        var kinds: [PadKind] = []
        for (k, n) in [(PadKind.yellowgreen, 5), (.fresh, 7), (.mint, 6), (.blue, 5)] {
            for _ in 0..<n { kinds.append(k) }
        }
        while kinds.count < jobs.count - 1 { kinds.append(.fresh) }
        for i in stride(from: kinds.count - 1, to: 0, by: -1) { kinds.swapAt(i, master.i(0, i + 1)) }
        let youngAt = master.i(LilyBank.classCount[0] / 2, LilyBank.classCount[0] + LilyBank.classCount[1])
        kinds.insert(.young, at: youngAt)
        for i in jobs.indices { jobs[i].p.kind = kinds[i]; jobs[i].p.old = false }
        var olds = 0, guardN = 0
        while olds < 2 && guardN < 100 {
            guardN += 1
            let i = master.i(0, LilyBank.classCount[0] + LilyBank.classCount[1])
            if jobs[i].p.kind != .young && !jobs[i].p.old { jobs[i].p.old = true; olds += 1 }
        }
        let flowerSeeds = (0..<6).map { _ in master.next() }
        let total = jobs.count + 6
        var padOut = [PadTexture?](repeating: nil, count: jobs.count)
        var flOut = [FlowerTexture?](repeating: nil, count: 6)
        let lock = NSLock()
        let shadowSigmaUnits = 3.0
        DispatchQueue.concurrentPerform(iterations: total) { k in
            if k < jobs.count {
                let j = jobs[k]
                let img = LilyArt.pad(N: j.N, nPy: j.nPy, j.p)
                let m = 0.12
                let sh = LilyArt.shadowImage(img, sigmaPx: shadowSigmaUnits * LilyArt.pxPerUnit, scale: 0.5, margin: m)
                let t = PadTexture(image: img, shadow: sh, shadowMargin: m)
                lock.lock(); padOut[k] = t; lock.unlock()
            } else {
                let f = k - jobs.count
                let seed = flowerSeeds[f]
                let img: CGImage
                switch f {
                case 0: img = LilyArt.lotusOpen(N: 512, seed: seed, pal: LilyArt.pinkA)
                case 1: img = LilyArt.lotusOpen(N: 512, seed: seed, pal: LilyArt.pinkB)
                case 2: img = LilyArt.lotusHalf(N: 352, seed: seed, pal: LilyArt.pinkB)
                case 3: img = LilyArt.lotusHalf(N: 352, seed: seed, pal: LilyArt.pinkA)
                default: img = LilyArt.bud(N: 160, seed: seed)
                }
                let m = 0.18
                let sh = LilyArt.shadowImage(img, sigmaPx: 6 * Double(img.width) / [196.0, 196, 132, 132, 60, 60][f], scale: 0.5, margin: m)
                let t = FlowerTexture(image: img, shadow: sh, shadowMargin: m)
                lock.lock(); flOut[f] = t; lock.unlock()
            }
        }
        var byClass: [[PadTexture]] = [[], [], []]
        for (k, j) in jobs.enumerated() { if let t = padOut[k] { byClass[j.cls].append(t) } }
        pads = byClass
        openLotus = [flOut[0]!, flOut[1]!]
        halfLotus = [flOut[2]!, flOut[3]!]
        buds = [flOut[4]!, flOut[5]!]
        buildSeconds = Date().timeIntervalSince(t0)
    }
}

// MARK: - Layout & flattening

struct PadPlacement {
    var p: V2          // scene points, y up
    var r: Double      // leaf radius in points
    var cls: Int
    var variant: Int
    var mirror: Bool
    var rot: Double
}

struct FlowerPlacement {
    enum Kind { case open, half, bud }
    var kind: Kind
    var variant: Int
    var p: V2
    var size: Double   // sprite side in points
    var rot: Double    // radians, CCW
    /// Where the stalk meets the water (points); a faint ring is drawn there.
    var stalkBase: V2
}

struct LilyLayout {
    var pads: [PadPlacement] = []
    var flowers: [FlowerPlacement] = []
    var openCenter = V2(0, 0)
    var openRadii = V2(1, 1)

    /// Port of v3_layout: crowded pads along edges/corners, open water oval in the
    /// middle, a small island; density per area (≈84 + 6 pads at 1600×900 units).
    /// Sorted largest first (drawn first = lowest).
    static func make(width W: Double, height H: Double, ws: Double, density: Double) -> LilyLayout {
        var L = LilyLayout()
        let U = W / ws, V = H / ws                    // layout units
        let oc = V2(0.494 * U, 0.5 * V), orad = V2(0.294 * U, 0.294 * V)
        L.openCenter = oc * ws
        L.openRadii = orad * ws
        func openQ(_ x: Double, _ y: Double) -> Double { hypot((x - oc.x) / orad.x, (y - oc.y) / orad.y) }
        let areaK = (U * V) / (1600 * 900)
        let target = Int((84 * areaK * density).rounded())
        var pads: [(Double, Double, Double)] = []
        var tries = 0
        let minGap = density > 1.15 ? 0.50 - 0.12 * (density - 1.15) : 0.50
        while pads.count < target && tries < 500 * max(target, 1) {
            tries += 1
            let x = rnd(-40, U + 40), y = rnd(-40, V + 40)
            let q = openQ(x, y)
            if q < 1.0 { continue }
            if Double.random(in: 0..<1) > smoothstep(0.98, 1.35, q) * 0.92 + 0.08 { continue }
            let u = Double.random(in: 0..<1)
            var r = 26 + 100 * pow(u, 2.2)
            r *= 0.8 + 0.35 * smoothstep(1.0, 2.0, q)
            r = min(r, (q - 1.0) * 260 + 40)
            if pads.contains(where: { hypot(x - $0.0, y - $0.1) < minGap * (r + $0.2) }) { continue }
            pads.append((x, y, r))
        }
        // island cluster in the open water (y up: 900-470 → 0.478 V)
        let island = V2(0.625 * U, 0.478 * V)
        let isl: [(Double, Double, Double)] = [(0, 0, 54), (62, 28, 40), (-50, -34, 36), (30, -52, 30), (-18, 54, 26), (78, -30, 22)]
        let nIsl = density < 0.6 ? 3 : 6
        for (ox, oy, r) in isl.prefix(nIsl) { pads.append((island.x + ox, island.y + oy, r)) }
        pads.sort { $0.2 > $1.2 }

        for (x, y, r) in pads {
            let cls = r >= 80 ? 0 : (r >= 46 ? 1 : 2)
            L.pads.append(PadPlacement(p: V2(x, y) * ws, r: r * ws, cls: cls,
                                       variant: Int.random(in: 0..<LilyBank.classCount[cls]),
                                       mirror: chance(0.5), rot: rnd(-0.17, 0.17)))
        }

        // Flowers: a lotus flower / bud rises on its own stalk from the root, separate
        // from the leaves — so every flower stands over open WATER, in a gap inside a
        // pile or at the edge of one (or next to the island), never on a pad. Seen from
        // above it may overlap a pad's rim a little (it stands higher), but its centre
        // is clearly over water. Computed from the actual pad layout, so it works for
        // any 荷叶密度 / screen size.
        L.flowers = placeFlowers(pads: pads, U: U, V: V, ws: ws, island: island, areaK: areaK)
        return L
    }

    /// Clearance (units) from `p` to the nearest pad outline (negative = on a pad).
    private static func clearance(_ p: V2, _ pads: [(Double, Double, Double)]) -> Double {
        var m = Double.infinity
        for (x, y, r) in pads {
            let d = hypot(p.x - x, p.y - y) - r * 1.03     // outlines reach ≤ ~1.03 r
            if d < m { m = d }
        }
        return m
    }

    static func placeFlowers(pads: [(Double, Double, Double)], U: Double, V: Double, ws: Double,
                             island: V2, areaK: Double) -> [FlowerPlacement] {
        // (kind, sprite size in units, prefer the island?)
        var wanted: [(FlowerPlacement.Kind, Double, Bool)] = [(.open, 196, false), (.half, 132, false),
                                                              (.bud, 60, true), (.bud, 62, false), (.bud, 58, false)]
        if areaK > 1.45 { wanted.insert((.half, 120, false), at: 2) }
        if areaK > 1.9 { wanted.insert((.open, 176, false), at: 2) }

        // Candidate points over open water.
        var cands: [(p: V2, clr: Double, crowd: Double)] = []
        for _ in 0..<5000 {
            let p = V2(rnd(0.04, 0.96) * U, rnd(0.05, 0.95) * V)
            let c = clearance(p, pads)
            if c < 6 { continue }
            var crowd = 0.0
            for (x, y, r) in pads {
                let d = hypot(p.x - x, p.y - y)
                if d < 230 + r { crowd += 1 - d / (230 + r) }
            }
            cands.append((p, c, crowd))
        }
        var out: [FlowerPlacement] = []
        var taken: [(V2, Double)] = []        // centre, keep-out radius (units)
        for (kind, sz, nearIsland) in wanted {
            let fr = sz / 2
            for relax in [1.0, 0.8, 0.62] {
                // Centre clearly over water: the flower may cover only a sliver of a rim.
                let minClr = max(8, fr * (kind == .bud ? 0.6 : 0.8) * relax)
                var best: (V2, Double)? = nil
                for c in cands where c.clr >= minClr {
                    let spacing = (kind == .bud ? 150.0 : 260.0) * relax
                    if taken.contains(where: { hypot($0.0.x - c.p.x, $0.0.y - c.p.y) < max(spacing, $0.1 + fr) }) { continue }
                    // Prefer gaps in / next to the pad piles: crowded neighbourhood, and only
                    // a little more water than needed (so it nestles against the leaves).
                    var score = c.crowd * 1.0 - max(0, c.clr - minClr - 25) / 30
                    if nearIsland { score += max(0, 1.6 - hypot(c.p.x - island.x, c.p.y - island.y) / 120) * 2.5 }
                    score += rnd(0, 0.6)
                    if best == nil || score > best!.1 { best = (c.p, score) }
                }
                guard let chosen = best else { continue }
                let p = chosen.0
                var rot = rnd(-0.6, 0.6)
                var base = p
                if kind == .bud {
                    // Turn the bud so its stalk enters the water away from the leaves.
                    var bestClr = -Double.infinity
                    for _ in 0..<10 {
                        let a = rnd(-Double.pi, Double.pi)
                        let local = V2(-0.5 * sz, -0.03 * sz).rotated(a)
                        let cl = clearance(p + local, pads)
                        if cl > bestClr { bestClr = cl; rot = a; base = p + local }
                    }
                } else {
                    base = p + V2(0.18, -0.24) * fr           // stalk peeks out under the flower
                }
                out.append(FlowerPlacement(kind: kind, variant: Int.random(in: 0..<2), p: p * ws,
                                           size: sz * ws, rot: rot, stalkBase: base * ws))
                taken.append((p, fr * 0.9 + 30))
                break
            }
        }
        return out
    }

    /// Placement transform: rotate by ±rot, optionally mirror across the light axis
    /// (135° in y-up space) so baked lighting stays consistent.
    static func apply(_ ctx: CGContext, _ pl: PadPlacement) {
        ctx.translateBy(x: CGFloat(pl.p.x), y: CGFloat(pl.p.y))
        ctx.rotate(by: CGFloat(pl.rot))
        if pl.mirror {
            ctx.rotate(by: -.pi / 2)
            ctx.scaleBy(x: 1, y: -1)
        }
    }

    struct Flattened {
        let pads: CGImage           // scene-sized, premultiplied
        let shadow: CGImage         // scene + margin, low-res union alpha (black), blurred
        let shadowMargin: Double    // points on each side
        let seconds: Double
    }

    /// Flattens all pads (largest first) into one image: each pad first casts a short
    /// sharp shadow onto the pads below (sourceAtop), then a faint meniscus ring onto
    /// the water only (destinationOver), then is drawn itself.
    func flatten(width W: Double, height H: Double, ws: Double, pxPerPt: Double) -> Flattened {
        let t0 = Date()
        let bank = LilyBank.shared
        let pw = Int((W * pxPerPt).rounded()), ph = Int((H * pxPerPt).rounded())
        let shortOff = V2(4.5, -6.0) * ws
        let img = Painter.image(pw: pw, ph: ph, scale: pxPerPt) { ctx in
            ctx.interpolationQuality = .high
            for pl in pads {
                let t = bank.pads[pl.cls][pl.variant % bank.pads[pl.cls].count]
                let side = 2 * pl.r / 0.92
                let sside = side * (1 + 2 * t.shadowMargin)
                // 1. short shadow onto lower pads
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(shortOff.x), y: CGFloat(shortOff.y))
                LilyLayout.apply(ctx, pl)
                ctx.setBlendMode(.sourceAtop)
                ctx.setAlpha(0.42)
                ctx.interpolationQuality = .medium
                ctx.draw(t.shadow, in: CGRect(x: -sside / 2, y: -sside / 2, width: sside, height: sside))
                ctx.restoreGState()
                // 2. meniscus / contact ring on the water
                ctx.saveGState()
                LilyLayout.apply(ctx, pl)
                ctx.setBlendMode(.destinationOver)
                ctx.setAlpha(0.22)
                ctx.interpolationQuality = .medium
                ctx.draw(t.shadow, in: CGRect(x: -sside / 2, y: -sside / 2, width: sside, height: sside))
                ctx.restoreGState()
                // 3. the pad
                ctx.saveGState()
                LilyLayout.apply(ctx, pl)
                ctx.draw(t.image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                ctx.restoreGState()
            }
        }
        // Long soft shadow: union of the pads' (already blurred) alpha at low res + blur.
        let margin = 80 * ws
        let sScale = 0.25
        let sw = Int(((W + 2 * margin) * sScale).rounded()), sh = Int(((H + 2 * margin) * sScale).rounded())
        let base = Painter.image(pw: sw, ph: sh, scale: sScale) { ctx in
            ctx.interpolationQuality = .low
            ctx.translateBy(x: CGFloat(margin), y: CGFloat(margin))
            for pl in pads {
                let t = bank.pads[pl.cls][pl.variant % bank.pads[pl.cls].count]
                let sside = 2 * pl.r / 0.92 * (1 + 2 * t.shadowMargin)
                ctx.saveGState()
                LilyLayout.apply(ctx, pl)
                ctx.draw(t.shadow, in: CGRect(x: -sside / 2, y: -sside / 2, width: sside, height: sside))
                ctx.restoreGState()
            }
        }
        let shadow = Painter.blurred(base, radius: 5.2 * ws * sScale)
        return Flattened(pads: img, shadow: shadow, shadowMargin: margin, seconds: Date().timeIntervalSince(t0))
    }
}

// MARK: - Offline preview (CI): `PondGoldfish --render-lily-preview out.png`

enum LilyPreview {
    static func render(to path: String, width W: Double = 1600, height H: Double = 900, pxPerPt: Double = 1) {
        let t0 = Date()
        let bank = LilyBank.shared
        let ws = min(W, H) / 900
        let layout = LilyLayout.make(width: W, height: H, ws: ws, density: 1)
        let flat = layout.flatten(width: W, height: H, ws: ws, pxPerPt: pxPerPt)
        let off = V2(13, -17) * ws
        let img = Painter.image(pw: Int(W * pxPerPt), ph: Int(H * pxPerPt), scale: pxPerPt) { ctx in
            // flat water + a few soft pebbles so shadows read
            ctx.setFillColor(rgba(58, 150, 128))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for _ in 0..<500 {
                Painter.fillEllipse(ctx, center: V2(rnd(0, W), rnd(0, H)), rx: rnd(3, 14), ry: rnd(2, 9), angle: rnd(0, 3), rgba(40, 120, 104, 0.35))
            }
            ctx.saveGState()
            ctx.setAlpha(0.48)
            let m = flat.shadowMargin
            ctx.draw(flat.shadow, in: CGRect(x: -m + off.x, y: -m + off.y, width: W + 2 * m, height: H + 2 * m))
            ctx.restoreGState()
            func tex(_ f: FlowerPlacement) -> FlowerTexture {
                switch f.kind {
                case .open: return bank.openLotus[f.variant]
                case .half: return bank.halfLotus[f.variant]
                case .bud: return bank.buds[f.variant]
                }
            }
            // flower shadows + stalk rings on the water, UNDER the pads
            for f in layout.flowers {
                let t = tex(f)
                let ss = f.size * (1 + 2 * t.shadowMargin)
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(f.p.x + off.x * 0.8), y: CGFloat(f.p.y + off.y * 0.8))
                ctx.rotate(by: CGFloat(f.rot))
                ctx.setAlpha(0.40)
                ctx.draw(t.shadow, in: CGRect(x: -ss / 2, y: -ss / 2, width: ss, height: ss))
                ctx.restoreGState()
                let rr = f.size * (f.kind == .bud ? 0.16 : 0.12)
                ctx.setStrokeColor(rgba(230, 255, 245, 0.30))
                ctx.setLineWidth(CGFloat(1.2 * ws))
                ctx.strokeEllipse(in: CGRect(x: f.stalkBase.x - rr, y: f.stalkBase.y - rr * 0.8, width: 2 * rr, height: 1.6 * rr))
            }
            ctx.draw(flat.pads, in: CGRect(x: 0, y: 0, width: W, height: H))
            for f in layout.flowers {
                let t = tex(f)
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(f.p.x), y: CGFloat(f.p.y))
                ctx.rotate(by: CGFloat(f.rot))
                ctx.draw(t.image, in: CGRect(x: -f.size / 2, y: -f.size / 2, width: f.size, height: f.size))
                ctx.restoreGState()
            }
        }
        let url = URL(fileURLWithPath: path)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        // pool contact sheet next to it
        let cell = 180.0
        let all = bank.pads.flatMap { $0 }
        let cols = 8
        let rows = (all.count + cols - 1) / cols + 1
        let sheet = Painter.image(pw: Int(cell) * cols, ph: Int(cell) * rows) { ctx in
            ctx.setFillColor(rgba(58, 150, 128))
            ctx.fill(CGRect(x: 0, y: 0, width: cell * Double(cols), height: cell * Double(rows)))
            for (i, t) in all.enumerated() {
                let x = Double(i % cols) * cell, y = Double(rows - 1 - i / cols) * cell
                ctx.draw(t.image, in: CGRect(x: x + 4, y: y + 4, width: cell - 8, height: cell - 8))
            }
            let fl = bank.openLotus + bank.halfLotus + bank.buds
            for (i, t) in fl.enumerated() {
                ctx.draw(t.image, in: CGRect(x: Double(i) * cell + 4, y: 4, width: cell - 8, height: cell - 8))
            }
        }
        let url2 = url.deletingPathExtension().appendingPathExtension("pool.png")
        if let dest = CGImageDestinationCreateWithURL(url2 as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, sheet, nil)
            CGImageDestinationFinalize(dest)
        }
        print(String(format: "lily preview: pool %.2fs, flatten %.2fs, total %.2fs, %d pads, %d flowers",
                     bank.buildSeconds, flat.seconds, Date().timeIntervalSince(t0), layout.pads.count, layout.flowers.count))
    }
}
