#!/usr/bin/env python3
"""
池塘金鱼 — lily pad / lotus before-after preview.

LEFT  ("现在")  : faithful port of the current Core Graphics code in
                  Sources/PondGoldfish/PondArt.swift (lilyPad, lotus, duckweed,
                  softDisc shadows, pond floor).
RIGHT ("优化后"): improved per-pixel design, written so it can be ported to Swift
                  (each texture = a pure function of (size, params, seed); every
                  effect is a closed-form field over polar/local coordinates or a
                  few strokes + a blur).

Run:  /workspace/venv-lotus/bin/python lotus_preview.py
Outputs lotus_compare.png, lotus_before.png, lotus_after.png next to this file.

Coordinates: numpy arrays, row = y (down). The "before" port draws in CG's y-up
space and flips at the end, so orientation/notch/highlight match the app.
"""
import math, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter, map_coordinates

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
F32 = np.float32
SS = 2                     # render at 2x, downsample at the end
HALF_W, HALF_H = 800, 900  # final size of each half
RW, RH = HALF_W * SS, HALF_H * SS
LIGHT = math.radians(-135)  # light from the top-left (image coords, y down)

# ---------------------------------------------------------------- helpers
def C(r, g, b):
    return np.array([r, g, b], F32) / 255.0

def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

def mix(a, b, t):
    a, b, t = np.asarray(a, F32), np.asarray(b, F32), np.asarray(t, F32)
    if t.ndim > 0 and (a.shape[-1:] == (3,) or b.shape[-1:] == (3,)) and t.shape[-1:] != (3,):
        t = t[..., None]
    return a * (1 - t) + b * t

def wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi

def vnoise(shape, cell, rng):
    """Smooth value noise in [-1,1] with feature size ~cell px."""
    h, w = shape
    cell = max(cell, 1.0)
    gh, gw = int(h / cell) + 4, int(w / cell) + 4
    g = rng.random((gh, gw)).astype(F32)
    im = Image.fromarray(g, 'F').resize((int(gw * cell), int(gh * cell)), Image.BICUBIC)
    a = np.asarray(im, F32)
    oy, ox = int(cell), int(cell)
    return (a[oy:oy + h, ox:ox + w] - 0.5) * 2

def fbm(shape, cell, rng, octaves=4, gain=0.5):
    s, amp, tot = np.zeros(shape, F32), 1.0, 0.0
    for i in range(octaves):
        s += amp * vnoise(shape, cell / (2 ** i), rng)
        tot += amp
        amp *= gain
    return s / tot

def cubic(p0, p1, p2, p3, n=40):
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2, p3 = map(np.asarray, (p0, p1, p2, p3))
    return ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3

def poly_cov(pts, shape, ss=4):
    h, w = shape
    im = Image.new('L', (w * ss, h * ss), 0)
    ImageDraw.Draw(im).polygon([(float(x) * ss, float(y) * ss) for x, y in pts], fill=255)
    return np.asarray(im.resize((w, h), Image.BOX), F32) / 255.0

def stroke_cov(lines, shape, ss=4, caps=True):
    """lines: list of (polyline Nx2, width) ; returns coverage."""
    h, w = shape
    im = Image.new('L', (w * ss, h * ss), 0)
    d = ImageDraw.Draw(im)
    for pts, width in lines:
        P = [(float(x) * ss, float(y) * ss) for x, y in pts]
        wpx = max(1, int(round(width * ss)))
        d.line(P, fill=255, width=wpx, joint='curve')
        if caps:
            r = width * ss / 2
            for (x, y) in (P[0], P[-1]):
                d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return np.asarray(im.resize((w, h), Image.BOX), F32) / 255.0

def tapered_cov(paths, shape, ss=4):
    """paths: list of (polyline, w0, w1) drawn as a sequence of round-capped segments."""
    h, w = shape
    im = Image.new('L', (w * ss, h * ss), 0)
    d = ImageDraw.Draw(im)
    for pts, w0, w1 in paths:
        n = len(pts)
        for i in range(n - 1):
            t = i / max(1, n - 2)
            wd = (w0 + (w1 - w0) * t) * ss
            (x0, y0), (x1, y1) = pts[i], pts[i + 1]
            d.line([(x0 * ss, y0 * ss), (x1 * ss, y1 * ss)], fill=255, width=max(1, int(round(wd))))
            r = wd / 2
            d.ellipse([x1 * ss - r, y1 * ss - r, x1 * ss + r, y1 * ss + r], fill=255)
    return np.asarray(im.resize((w, h), Image.BOX), F32) / 255.0


class Layer:
    """Premultiplied RGBA float canvas."""
    def __init__(self, h, w, bg=None):
        self.a = np.zeros((h, w, 4), F32)
        if bg is not None:
            self.a[..., :3] = bg
            self.a[..., 3] = 1
        self.h, self.w = h, w

    def over(self, rgb, a, sl=None):
        """Composite color (3,) or (h,w,3) with coverage*alpha `a` (h,w)."""
        tgt = self.a if sl is None else self.a[sl]
        a = np.clip(a, 0, 1)[..., None]
        tgt[..., :3] = rgb * a + tgt[..., :3] * (1 - a)
        tgt[..., 3:] = a + tgt[..., 3:] * (1 - a)

    def over_premul(self, src, y0, x0):
        h, w = src.shape[:2]
        ya, xa = max(0, y0), max(0, x0)
        yb, xb = min(self.h, y0 + h), min(self.w, x0 + w)
        if ya >= yb or xa >= xb:
            return
        s = src[ya - y0:yb - y0, xa - x0:xb - x0]
        t = self.a[ya:yb, xa:xb]
        t[:] = s + t * (1 - s[..., 3:])

    def ellipse(self, cx, cy, rx, ry, ang, rgb, alpha=1.0):
        R = max(rx, ry) + 2
        x0, x1 = int(max(0, cx - R)), int(min(self.w, cx + R + 1))
        y0, y1 = int(max(0, cy - R)), int(min(self.h, cy + R + 1))
        if x0 >= x1 or y0 >= y1:
            return
        yy, xx = np.mgrid[y0:y1, x0:x1].astype(F32) + 0.5
        dx, dy = xx - cx, yy - cy
        ca, sa = math.cos(ang), math.sin(ang)
        lx, ly = dx * ca + dy * sa, -dx * sa + dy * ca
        q = np.sqrt((lx / rx) ** 2 + (ly / ry) ** 2) + 1e-6
        th = np.arctan2(ly, lx)
        reff = rx * ry / np.sqrt((ry * np.cos(th)) ** 2 + (rx * np.sin(th)) ** 2)
        cov = np.clip((1 - q) * reff + 0.5, 0, 1)
        self.over(np.asarray(rgb, F32), cov * alpha, (slice(y0, y1), slice(x0, x1)))

    def circle(self, cx, cy, r, rgb, alpha=1.0):
        self.ellipse(cx, cy, r, r, 0, rgb, alpha)


def rotate_premul(tex, deg):
    if abs(deg) < 1e-3:
        return tex
    ch = [np.asarray(Image.fromarray(np.ascontiguousarray(tex[..., i]), 'F')
                     .rotate(deg, Image.BICUBIC, expand=True), F32) for i in range(4)]
    t = np.stack(ch, -1)
    t[..., 3] = np.clip(t[..., 3], 0, 1)
    t[..., :3] = np.clip(t[..., :3], 0, t[..., 3:])
    return t

def resize_premul(tex, size):
    if tex.shape[0] == size:
        return tex
    ch = [np.asarray(Image.fromarray(np.ascontiguousarray(tex[..., i]), 'F')
                     .resize((size, size), Image.BICUBIC), F32) for i in range(4)]
    t = np.stack(ch, -1)
    t[..., 3] = np.clip(t[..., 3], 0, 1)
    t[..., :3] = np.clip(t[..., :3], 0, t[..., 3:])
    return t

def place(canvas, tex, cx, cy, deg=0.0, alpha=1.0):
    t = rotate_premul(tex, deg) * alpha
    h, w = t.shape[:2]
    y0, x0 = int(round(cy - h / 2)), int(round(cx - w / 2))
    canvas.over_premul(t, y0, x0)
    return t, y0, x0

def stamp_alpha(shape, t, y0, x0, dy=0, dx=0):
    """Rotated sprite alpha pasted into a full-size map at an offset."""
    m = np.zeros(shape, F32)
    h, w = t.shape[:2]
    y0 += dy; x0 += dx
    ya, xa = max(0, y0), max(0, x0)
    yb, xb = min(shape[0], y0 + h), min(shape[1], x0 + w)
    if ya < yb and xa < xb:
        m[ya:yb, xa:xb] = t[ya - y0:yb - y0, xa - x0:xb - x0, 3]
    return m


# ================================================================ POND FLOOR
# Port of PondLayout + PondArt.floor (rocks/reeds omitted: none in this crop).
def pond_floor(W, H, ws, seed=7):
    rng = np.random.default_rng(seed)
    rnd = lambda a, b: float(rng.uniform(a, b))
    nrm = lambda: float(rng.normal())
    area, unit = W * H, 260.0 * 260.0 * ws * ws
    deep = [((rnd(.08, .92) * W, rnd(.08, .92) * H), rnd(90, 210) * ws) for _ in range(max(6, int(area / unit * .9)))]
    shallow = [((rnd(0, 1) * W, rnd(0, 1) * H), rnd(70, 190) * ws) for _ in range(max(6, int(area / unit * 1.1)))]
    beds = [((rnd(0, 1) * W, rnd(0, 1) * H), rnd(60, 160) * ws) for _ in range(max(8, int(area / unit * 1.4)))]
    moss = []
    for _ in range(max(10, int(area / unit * 1.2))):
        e = int(rng.integers(0, 4)); p = [rnd(0, 1) * W, rnd(0, 1) * H]
        if e == 0: p[0] = rnd(0, .14) * W
        elif e == 1: p[0] = rnd(.86, 1) * W
        elif e == 2: p[1] = rnd(0, .14) * H
        else: p[1] = rnd(.86, 1) * H
        moss.append((tuple(p), rnd(40, 120) * ws))

    def depth(px, py):
        d = 0.35
        for (c, r) in deep:
            q = math.hypot(px - c[0], py - c[1]) / r; d += .55 * math.exp(-q * q * 1.6)
        for (c, r) in shallow:
            q = math.hypot(px - c[0], py - c[1]) / r; d -= .35 * math.exp(-q * q * 1.8)
        return min(1, max(0, d))

    deepC, midC, flatC = C(20, 96, 90), C(38, 128, 106), C(84, 168, 124)
    jit = lambda c, a: c + rng.uniform(-a, a, 3).astype(F32)
    L = Layer(H, W, bg=midC)

    def scallop(spot, col, alpha):
        (cx, cy), r = spot
        for _ in range(int(10 + r / (9 * ws))):
            L.circle(cx + nrm() * r * .33, cy + nrm() * r * .33, rnd(.22, .5) * r, jit(col, .025), alpha * rnd(.5, 1))
        rim = int(14 + r / (5 * ws))
        for i in range(rim):
            a = i / rim * 2 * math.pi + rnd(-.1, .1); rr = r * rnd(.62, .85)
            L.circle(cx + math.cos(a) * rr, cy + math.sin(a) * rr, r * rnd(.1, .2), jit(col, .025), alpha * rnd(.5, .9))

    for s in deep: scallop(s, deepC, .55)
    for s in shallow: scallop(s, flatC, .46)
    for _ in range(int(area / (95 * ws * ws))):
        px, py = rnd(0, W), rnd(0, H); d = depth(px, py)
        base = mix(midC, deepC, (d - .5) * 2) if d > .5 else mix(flatC, midC, d * 2)
        r = rnd(2.5, 10) * ws
        L.ellipse(px, py, r, r * rnd(.6, 1), rnd(0, 3.14), jit(base, .05), rnd(.10, .28))
    for (c, r) in moss:
        for _ in range(int(10 + r / (6 * ws))):
            rr = rnd(4, 16) * ws
            col = C(36, 100, 58) if rng.random() < .6 else C(92, 140, 66)
            L.ellipse(c[0] + nrm() * r * .45, c[1] + nrm() * r * .45, rr, rr * rnd(.5, 1), rnd(0, 3.14), jit(col, .04), rnd(.1, .25))
    stones = [C(92, 142, 116), C(62, 112, 96), C(122, 160, 126), C(46, 96, 86), C(140, 170, 132), C(104, 128, 108), C(78, 120, 100)]
    for i in range(int(area / (380 * ws * ws))):
        if i % 5 < 3:
            (bx, by), br = beds[int(rng.integers(0, len(beds)))]
            px, py = bx + nrm() * br * .5, by + nrm() * br * .5
        else:
            px, py = rnd(0, W), rnd(0, H)
        u = rng.random(); r = (1.6 + 7.5 * u ** 3.2) * ws
        col = jit(stones[int(rng.integers(0, len(stones)))], .035)
        ang = rnd(0, 3.14); ry = r * rnd(.6, .95)
        L.ellipse(px + .25 * r, py + .3 * r, r * 1.08, ry * 1.08, ang, C(8, 40, 38), .2)
        L.ellipse(px, py, r, ry, ang, col, .6)
        if r > 2.2 * ws:
            L.ellipse(px - .3 * r, py - .32 * r, r * .5, ry * .42, ang, col * 1.18, .3)
    for (c, r) in moss:
        for _ in range(int(r / (1.4 * ws))):
            col = C(30, 82, 48) if rng.random() < .5 else C(118, 156, 72)
            L.circle(c[0] + nrm() * r * .5, c[1] + nrm() * r * .5, rnd(.8, 2.6) * ws, col, rnd(.35, .7))
    # vignette
    yy, xx = np.mgrid[0:H, 0:W].astype(F32)
    q = np.hypot(xx - W / 2, yy - H / 2) / (math.hypot(W, H) * .55)
    L.over(C(0, 20, 22), .30 * smooth(.55, 1, q) if False else .30 * np.clip((q - .55) / .45, 0, 1))
    # low-res depth map for the haze (like PondArt.depthMap)
    dm = np.zeros((H // 16 + 1, W // 16 + 1), F32)
    for j in range(dm.shape[0]):
        for i in range(dm.shape[1]):
            dm[j, i] = depth(i * 16, j * 16)
    dm = np.asarray(Image.fromarray(dm, 'F').resize((W, H), Image.BICUBIC), F32)
    return L, gaussian_filter(dm, 20)

def water_over(L, dmap, seed=3):
    """Water look on top of floor+shadows: deep haze (#1A5952) by depth, a faint
    #71E6C2 glaze and a soft caustic web. Identical for both halves."""
    H, W = L.h, L.w
    rng = np.random.default_rng(seed)
    L.over(C(0x1A, 0x59, 0x52), np.clip(.16 + .42 * dmap, 0, .6))
    L.over(C(0x71, 0xE6, 0xC2), np.full((H, W), .10, F32))
    n1, n2 = fbm((H, W), 220, rng, 3), fbm((H, W), 150, rng, 3)
    web = (1 - np.abs(n1)) ** 10 + (1 - np.abs(n2)) ** 12
    L.a[..., :3] += (web * .05)[..., None] * C(200, 255, 225) * L.a[..., 3:]


# ================================================================ BEFORE (port)
def _cg_space(N):
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + 0.5
    return xx, yy    # draw in y-up "CG" units directly; flipud at the end

def before_lily_pad(N, variant, rng):
    """PondArt.lilyPad(variant:) — 256pt texture scaled to N px."""
    k = N / 256.0; S = 256.0
    rnd = lambda a, b: float(rng.uniform(a, b))
    L = Layer(N, N)
    xx, yy = _cg_space(N)
    c = np.array([S / 2, S / 2]) * k; r = S * .47 * k
    notch = rnd(0, 2 * math.pi); half = .16
    arc = [c + r * np.array([math.cos(a), math.sin(a)])
           for a in np.linspace(notch + half, notch - half + 2 * math.pi, 400)]
    path = [tuple(c)] + [tuple(p) for p in arc]
    clip = poly_cov(path, (N, N))
    pals = [(C(128, 186, 76), C(70, 150, 60), C(44, 112, 50)),
            (C(150, 194, 84), C(88, 160, 66), C(58, 124, 52)),
            (C(118, 172, 80), C(64, 136, 64), C(120, 96, 52))]
    inner, mid, edge = pals[variant % 3]
    t = np.clip(np.hypot(xx - c[0], yy - c[1]) / r, 0, 1)
    g = np.where((t < .6)[..., None], mix(inner, mid, t / .6), mix(mid, edge, (t - .6) / .4))
    L.over(g, clip)
    tmp = Layer(N, N)          # clipped sub-drawing
    for _ in range(70):
        a = rnd(0, 6.28); rr = r * math.sqrt(rnd(0, 1))
        col = inner * 1.08 if rng.random() < .5 else mid * .9
        tmp.ellipse(c[0] + math.cos(a) * rr, c[1] + math.sin(a) * rr, rnd(4, 14) * k, rnd(3, 8) * k, rnd(0, 3.14), np.clip(col, 0, 1), rnd(.1, .25))
    veins = []
    for i in range(22):
        a = notch + half + i / 22 * (2 * math.pi - 2 * half) + .05
        p0 = c + np.array([math.cos(a), math.sin(a)]) * r * .06
        a1 = a + rnd(-.04, .04)
        p1 = c + np.array([math.cos(a1), math.sin(a1)]) * r * .96
        veins.append(([tuple(p0), tuple(p1)], rnd(1.2, 2.2) * k))
    for v in veins:   # each vein stroked separately at alpha .30 (overlaps add up)
        tmp.over(np.clip(inner * 1.15, 0, 1), stroke_cov([v], (N, N)) * .30)
    rim = stroke_cov([(path + [path[0]], 5 * k)], (N, N), caps=False)
    tmp.over(edge * .8, rim * .7)
    # apply clip
    L.a = tmp.a * clip[..., None] + L.a * (1 - tmp.a[..., 3:] * clip[..., None])
    L.ellipse(c[0] - .25 * r, c[1] + .3 * r, r * .28, r * .12, .6, C(255, 255, 240), .12)
    L.circle(c[0], c[1], 3.5 * k, edge, .6)
    L.a = np.flipud(L.a).copy()
    return L.a

def _before_petal(L, c, ang, length, width, base, tip, k):
    N = L.h
    ca, sa = math.cos(ang), math.sin(ang)
    loc = np.concatenate([cubic((0, 0), (length * .35, width * .95), (length * .85, width * .55), (length, 0)),
                          cubic((length, 0), (length * .85, -width * .55), (length * .35, -width * .95), (0, 0))])
    pts = [(c[0] + x * ca - y * sa, c[1] + x * sa + y * ca) for x, y in loc]
    cov = poly_cov(pts, (N, N))
    sh = gaussian_filter(cov, 3 * k)                      # CG shadow blur 6 (device px)
    L.over(C(90, 20, 50), sh * .35)
    xx, yy = _cg_space(N)
    u = np.clip(((xx - c[0]) * ca + (yy - c[1]) * sa) / length, 0, 1)
    m = mix(base, tip, .55)
    g = np.where((u < .55)[..., None], mix(base, m, u / .55), mix(m, tip, (u - .55) / .45))
    L.over(g, cov)
    p0 = (c[0] + length * .1 * ca, c[1] + length * .1 * sa); p1 = (c[0] + length * .9 * ca, c[1] + length * .9 * sa)
    L.over(C(255, 245, 250), stroke_cov([([p0, p1], 1.5 * k)], (N, N), caps=False) * cov * .35)

def before_lotus(N, variant, rng):
    """PondArt.lotus(variant:)"""
    k = N / 256.0; S = 256.0 * k
    rnd = lambda a, b: float(rng.uniform(a, b))
    L = Layer(N, N)
    c = (S / 2, S / 2)
    deep = C(236, 104, 156) if variant % 2 == 0 else C(242, 128, 170)
    pale = C(252, 226, 234)
    layers = [(9, S * .47, S * .17, 0.0), (8, S * .38, S * .15, .35), (6, S * .27, S * .13, .15), (5, S * .17, S * .10, .6)]
    for li, (cnt, ln, wd, rot) in enumerate(layers):
        for i in range(cnt):
            a = rot + i / cnt * 2 * math.pi + rnd(-.08, .08)
            _before_petal(L, c, a, ln * rnd(.92, 1.05), wd, pale, mix(deep, pale, li * .18), k)
    for i in range(26):
        a = i / 26 * 2 * math.pi
        L.circle(c[0] + math.cos(a) * S * .075, c[1] + math.sin(a) * S * .075, 3.2 * k, C(250, 196, 60), .95)
    L.circle(c[0], c[1], S * .06, C(214, 214, 92))
    L.circle(c[0], c[1], S * .045, C(188, 196, 78))
    for i in range(7):
        a = i / 7 * 2 * math.pi
        L.circle(c[0] + math.cos(a) * S * .025, c[1] + math.sin(a) * S * .025, 2 * k, C(130, 140, 50))
    return np.flipud(L.a).copy()

def before_duckweed(N, rng):
    k = N / 64.0; S = 64.0
    rnd = lambda a, b: float(rng.uniform(a, b))
    L = Layer(N, N)
    for _ in range(int(rng.integers(4, 12))):
        px, py = S / 2 + rng.normal() * S * .16, S / 2 + rng.normal() * S * .16
        r = rnd(3.2, 6.5); a = rnd(0, 3.14)
        col = C(132, 196, 74) if rng.random() < .5 else C(98, 168, 62)
        L.ellipse((px + .6) * k, (py - .8) * k, r * k, r * .75 * k, a, C(10, 50, 30), .35)
        L.ellipse(px * k, py * k, r * k, r * .75 * k, a, col)
        L.ellipse((px - .25 * r) * k, (py + .25 * r) * k, r * .45 * k, r * .3 * k, a, C(220, 240, 160), .35)
    return np.flipud(L.a).copy()

def soft_disc(N):
    """PondArt.softDisc — disc r=44/128 blurred 12/128, used black."""
    k = N / 128.0
    L = Layer(N, N); L.circle(N / 2, N / 2, 44 * k, C(0, 0, 0))
    return gaussian_filter(L.a[..., 3], 12 * k)


# ================================================================ AFTER (improved)
def after_lily_pad(N, seed, notch, old=False, droplets=(), tear=None, rot_light=0.0):
    """Improved pad. N px texture, pad radius ~0.47N (same footprint as today).
    notch: direction of the slit (radians, image coords).
    droplets: [(x, y, r)] in units of R relative to the centre.
    tear: (angle, depth in R) for an old pad.
    rot_light: sprite rotation (radians) so baked lighting still comes from top-left."""
    rng = np.random.default_rng(seed)
    R = .47 * N; c = N / 2
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    dx, dy = xx - c, yy - c
    rho = np.hypot(dx, dy) + 1e-4
    th = np.arctan2(dy, dx)
    phi = wrap(th - notch)
    light = LIGHT - rot_light

    # --- outline: wavy irregular edge, V notch, rounded lobe tips
    ph = rng.uniform(0, 2 * np.pi, 6)
    redge = R * (1 + .011 * np.sin(5 * th + ph[0]) + .007 * np.sin(9 * th + ph[1])
                 + .004 * np.sin(17 * th + ph[2]) + .0015 * np.sin(29 * th + ph[3]))
    redge = redge * (1 - .035 * np.exp(-((np.abs(phi) - .2) / .35) ** 2))   # lobes taper into the notch
    half = .13 * (.55 + .45 * np.clip(rho / R, 0, 1)) + .006 * np.sin(phi * 9)
    d_edge = redge - rho
    d_notch = (np.abs(phi) - half) * rho
    kk = .018 * R
    d = -kk * np.logaddexp(-d_edge / kk, -d_notch / kk)      # smooth-min -> rounded tips
    if tear is not None:
        ta, tdep = tear
        tth = ta + .04 * np.sin(rho / R * 30)                               # ragged
        inner = R * (1 - tdep)
        hw = np.clip((rho - inner) / (R - inner), 0, 1) ** 1.4 * .075 * R + .004 * R * np.sin(rho * .7)
        d_tear = np.where(rho > inner, np.abs(wrap(th - tth)) * rho - hw, 1e3)
        d = np.minimum(d, d_tear)
    cov = np.clip(d + .5, 0, 1)

    t = np.clip(rho / redge, 0, 1)
    nlow = fbm((N, N), N / 6, rng, 3)
    nmid = fbm((N, N), N / 22, rng, 4)
    nfine = fbm((N, N), N / 90, rng, 3)
    speck = vnoise((N, N), max(1.5, N / 300), rng)

    # --- base colour: dark green centre -> yellow-green edge
    c0, c1, c2 = C(40, 92, 38), C(70, 134, 48), C(140, 178, 66)
    if old:
        c0, c1, c2 = C(58, 104, 44), C(92, 140, 56), C(150, 168, 70)
    tt = np.clip(t + .06 * nlow, 0, 1)
    col = np.where((tt < .55)[..., None], mix(c0, c1, smooth(0, .55, tt)), mix(c1, c2, smooth(.55, 1.0, tt)))
    # mottled, waxy texture
    bright = 1 + .09 * nmid + .06 * nfine + .035 * speck
    col = col * bright[..., None]
    col = col + (np.stack([.025, .02, -.01]).astype(F32) * nlow[..., None])
    blot = smooth(.25, .7, nmid + .3 * nlow)                                # darker lobes of mottling
    col = col * (1 - .06 * blot)[..., None]

    # --- veins (stroked, then soft)
    nmain = 15
    lo, hi = notch + .24, notch + 2 * np.pi - .24
    angles = np.linspace(lo, hi, nmain)
    spacing = (hi - lo) / (nmain - 1)
    def redge_at(a):
        return R * (1 + .011 * math.sin(5 * a + ph[0]) + .007 * math.sin(9 * a + ph[1]) + .004 * math.sin(17 * a + ph[2]))
    def seg(r0, a0, r1, a1, wob, n=24):
        pts = []
        for i in range(n):
            s = i / (n - 1)
            rr = r0 + (r1 - r0) * s
            aa = a0 + (a1 - a0) * (s * s * (3 - 2 * s)) + wob * math.sin(s * math.pi) * .5
            pts.append((c + rr * math.cos(aa), c + rr * math.sin(aa)))
        return pts
    sc = N / 600.0
    main, second, third, retic = [], [], [], []
    tips = []
    for a in angles:
        a += rng.uniform(-.03, .03)
        f1 = R * rng.uniform(.40, .52); f2 = R * rng.uniform(.70, .80)
        main.append((seg(R * .03, a, f1, a + rng.uniform(-.02, .02), rng.uniform(-.03, .03)), 3.4 * sc, 2.2 * sc))
        for s1 in (-1, 1):
            a1 = a + s1 * spacing * .25 * rng.uniform(.8, 1.1)
            second.append((seg(f1, a, f2, a1, 0), 2.0 * sc, 1.4 * sc))
            for s2 in (-1, 1):
                a2 = a1 + s2 * spacing * .125 * rng.uniform(.7, 1.1)
                re = redge_at(a2) * .975
                third.append((seg(f2, a1, re, a2, 0, 14), 1.3 * sc, .7 * sc))
                tips.append(a2)
    tips = sorted([wrap(x - notch) for x in tips])
    for i in range(len(tips) - 1):
        for _ in range(3):
            rr = R * rng.uniform(.55, .93)
            a0, a1 = tips[i] + notch, tips[i + 1] + notch
            retic.append(([(c + rr * math.cos(a0), c + rr * math.sin(a0)),
                           (c + rr * 1.02 * math.cos((a0 + a1) / 2 + rng.uniform(-.01, .01)), c + rr * 1.02 * math.sin((a0 + a1) / 2)),
                           (c + (rr + rng.uniform(-.04, .04) * R) * math.cos(a1), c + (rr + rng.uniform(-.04, .04) * R) * math.sin(a1))],
                          .8 * sc, .6 * sc))
    v1 = gaussian_filter(tapered_cov(main, (N, N)), .6 * sc)
    v2 = gaussian_filter(tapered_cov(second, (N, N)), .6 * sc)
    v3 = gaussian_filter(tapered_cov(third, (N, N)), .5 * sc)
    v4 = gaussian_filter(tapered_cov(retic, (N, N)), .5 * sc)
    fade = (1 - .45 * smooth(.6, 1.0, t))                 # veins fade toward the rim
    vein = np.clip(.48 * v1 + .36 * v2 + .25 * v3 + .13 * v4, 0, .55) * fade * (1 + .25 * nfine)
    vlight = np.clip(col * 1.22 + C(14, 18, 0), 0, 1)
    col = mix(col, vlight, vein)
    # tiny relief: a soft dark flank on the side away from the light
    sx, sy = -math.cos(light) * 1.2 * sc, -math.sin(light) * 1.2 * sc
    vv = .30 * v1 + .22 * v2 + .14 * v3
    flank = np.clip(np.roll(np.roll(gaussian_filter(vv, 1.0 * sc), int(round(sy)) or 1, 0), int(round(sx)) or 1, 1) - vv, 0, 1)
    col = col * (1 - .35 * flank * fade)[..., None]

    # --- old pad: yellowing edge, brown spots, necrotic tear border
    if old:
        yel = smooth(.80, 1.02, t + .22 * nlow + .08 * nmid)
        col = mix(col, C(188, 164, 74) * (1 + .08 * nfine)[..., None], yel * .85)
        spots = smooth(.40, .70, nmid * .8 + nfine * .5) * smooth(.65, .95, t)
        col = mix(col, C(122, 92, 44), spots * .55)
        if tear is not None:
            border = np.exp(-np.clip(d_tear, 0, None) / (2.5 * sc)) * (rho > inner - .03 * R)
            col = mix(col, C(112, 78, 38), np.clip(border, 0, 1) * .8)

    # --- upturned rim + thin highlight edge
    facing = np.cos(th - light)                    # +1 on the lit (top-left) side
    rimw = .035 * R
    band = 1 - smooth(0, rimw, d)                  # 1 at the edge -> 0 inside
    col = col * (1 + band * (-.10 * facing + .04))[..., None]       # inner face: far side catches light
    col = mix(col, col * 1.1 + C(14, 14, 0), band * .25)            # rim slightly yellower/lighter
    hl = np.exp(-((d - .9 * sc) / (.9 * sc)) ** 2) * (.25 + .55 * np.clip(facing, 0, 1))
    col = mix(col, C(226, 240, 170), np.clip(hl, 0, .8))
    dark_line = np.exp(-((d - 3.2 * sc) / (1.4 * sc)) ** 2) * .10 * np.clip(-facing + .3, 0, 1)
    col = col * (1 - dark_line)[..., None]
    if old:
        col = mix(col, C(120, 90, 42), np.exp(-np.clip(d, 0, None) / (1.6 * sc)) * .5)

    # --- broad waxy sheen + tiny waxy glints
    lx, ly = c + math.cos(light) * R * .35, c + math.sin(light) * R * .35
    sheen = np.exp(-(((xx - lx) / (R * .55)) ** 2 + ((yy - ly) / (R * .40)) ** 2))
    col = col + (sheen * (.06 + .05 * smooth(.2, .8, nmid)))[..., None] * C(210, 240, 220)
    # centre (petiole attachment)
    cdot = np.exp(-(rho / (.03 * R)) ** 2)
    col = col * (1 - .25 * cdot)[..., None]

    # --- droplets
    col = np.clip(col, 0, 1)
    for (ux, uy, ur) in droplets:
        px, py, pr = c + ux * R, c + uy * R, ur * R
        ox, oy = -math.cos(light) * pr * .45, -math.sin(light) * pr * .45
        sh = np.exp(-(((xx - px - ox) ** 2 + (yy - py - oy) ** 2) / (pr * 1.0) ** 2) ** 2)
        col = col * (1 - .26 * sh)[..., None]
        dd = np.hypot(xx - px, yy - py)
        dcov = np.clip(pr - dd + .5, 0, 1)
        q = np.clip(dd / pr, 0, 1)
        # magnified (refracted) leaf under the drop
        sx_ = px + (xx - px) * .55; sy_ = py + (yy - py) * .55
        ref = np.stack([map_coordinates(col[..., i], [sy_ - .5, sx_ - .5], order=1, mode='nearest') for i in range(3)], -1)
        lam = (xx - px) * math.cos(light) + (yy - py) * math.sin(light)          # + toward light
        body = ref * (1.14 + .16 * np.clip(-lam / pr, 0, 1))[..., None]
        body = body * (1 - .22 * smooth(.6, 1, q) * np.clip(.4 + lam / pr, 0, 1.2))[..., None]   # dark rim on lit side
        cau = np.exp(-(((xx - px + math.cos(light) * pr * .45) ** 2 + (yy - py + math.sin(light) * pr * .45) ** 2) / (pr * .35) ** 2))
        body = body + (cau * .30)[..., None] * C(230, 255, 200)
        spx, spy = px + math.cos(light) * pr * .42, py + math.sin(light) * pr * .42
        spec = np.exp(-(((xx - spx) ** 2 + (yy - spy) ** 2) / (pr * .2) ** 2) ** 1.5)
        body = mix(body, C(255, 255, 255), np.clip(spec * .95, 0, 1))
        col = mix(col, np.clip(body, 0, 1), dcov)

    col = np.clip(col, 0, 1)
    out = np.zeros((N, N, 4), F32)
    out[..., :3] = col * cov[..., None]
    out[..., 3] = cov
    return out


# ---------------------------------------------------------------- lotus (after)
PINK_A = (C(253, 248, 236), C(246, 196, 214), C(232, 108, 152), C(214, 80, 132))
PINK_B = (C(253, 249, 240), C(248, 206, 220), C(238, 128, 166), C(222, 98, 146))

def _petal_field(N, bx, by, ang, L, W, a=.9, b=.7):
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    ca, sa = math.cos(ang), math.sin(ang)
    ux = (xx - bx) * ca + (yy - by) * sa
    vy = -(xx - bx) * sa + (yy - by) * ca
    u = ux / L
    uc = np.clip(u, 1e-4, 1 - 1e-4)
    peak = (a / (a + b)) ** a * (b / (a + b)) ** b
    hw = W * (uc ** a) * ((1 - uc) ** b) / peak
    hw = hw * (1 + .06 * np.sin(uc * 3.1))                   # slight asymmetry of profile
    dist = hw - np.abs(vy)
    cov = np.clip(dist + .5, 0, 1) * (u > 0) * (u < 1)
    s = np.clip(np.abs(vy) / np.maximum(hw, 1e-3), 0, 1)
    return cov, u, vy, hw, s, dist

def after_petal(tex, rng, bx, by, ang, L, W, pal, pinkness=1.0, bright=0.0, edge_dark=.12,
                shadow=.30, a=.9, b=.7, light=LIGHT, vein_k=13, pink_base=0.0):
    N = tex.h
    cov, u, vy, hw, s, dist = _petal_field(N, bx, by, ang, L, W, a, b)
    if cov.max() <= 0:
        return cov
    sc = N / 512.0
    # soft shadow of this petal onto what is already painted (between layers)
    if shadow > 0:
        sh = gaussian_filter(cov, 4.5 * sc)
        sh = np.roll(np.roll(sh, int(round(2 * sc)), 0), int(round(2 * sc)), 1)
        tex.a[..., :3] *= (1 - shadow * sh)[..., None] * 1 + 0
        tex.a[..., :3] = np.maximum(tex.a[..., :3] - (shadow * .25 * sh)[..., None] * C(0, 40, 20) * tex.a[..., 3:], 0)
    cream, blush, pink, deep = pal
    uc = np.clip(u, 0, 1)
    nz = vnoise((N, N), 18 * sc, rng)
    p = smooth(.12, 1.0, uc + .05 * nz) ** 1.25 * (.78 + .22 * s) + .18 * s * s * uc
    p = np.clip(p * pinkness, 0, 1)
    p = p + pink_base * (1 - p) * smooth(0, .35, uc)
    col = np.where((p < .45)[..., None], mix(cream, blush, p / .45), mix(blush, pink, (p - .45) / .55))
    col = mix(col, deep, smooth(.86, 1.0, uc) * .5 * pinkness)            # deeper tip
    col = mix(col, C(242, 236, 190), smooth(.14, 0, uc) * .55)             # pale yellow-green base
    # fine longitudinal veins (follow the petal outline)
    q = vy / np.maximum(hw, 1e-3) + .025 * vnoise((N, N), 30 * sc, rng)
    vf = (.5 + .5 * np.cos(np.pi * vein_k * q)) ** 6
    vf = vf * smooth(.06, .35, uc) * (1 - smooth(.85, 1, uc)) * (1 - .6 * s)
    col = mix(col, col * C(236, 190, 210) * 1.0, vf * .55)
    # cupping & light
    shade = 1 - edge_dark * s ** 2.2 + .035 * (1 - s) ** 3
    side = np.sign(vy) * math.sin(ang - light)
    shade = shade * (1 + .04 * side * s) + bright
    col = col * shade[..., None]
    # crisp but soft petal edge (thin darker line) + inner-petal light rim
    edge = np.exp(-np.clip(dist, 0, None) / (1.1 * sc))
    col = col * (1 - .10 * edge)[..., None]
    col = np.clip(col, 0, 1)
    tex.over(col, cov)
    return cov

def stamens_and_pod(tex, rng, c, rp, n=90, slen=.65, light=LIGHT, vis=1.0):
    N = tex.h; sc = N / 512.0
    cx, cy = c
    # dark ring where the pod sits
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    rr = np.hypot(xx - cx, yy - cy)
    tex.a[..., :3] *= (1 - .25 * np.exp(-((rr - rp * 1.1) / (rp * .5)) ** 2))[..., None]
    lines, anth = [], []
    for i in range(n):
        a = i / n * 2 * np.pi + rng.uniform(-.05, .05)
        l = rp * slen * rng.uniform(.75, 1.15)
        curl = rng.uniform(-.25, .25)
        r0 = rp * .92
        pts = [(cx + (r0 + l * s) * math.cos(a + curl * s * s), cy + (r0 + l * s) * math.sin(a + curl * s * s)) for s in np.linspace(0, 1, 6)]
        lines.append((pts, 1.1 * sc))
        anth.append((pts[-1], a + curl))
    fil = stroke_cov(lines, (N, N))
    tex.over(C(246, 222, 132), fil * .95 * vis)
    for (x, y), a in anth:
        tex.ellipse(x, y, 2.6 * sc, 1.3 * sc, a, C(236, 178, 54), .95 * vis)
        tex.ellipse(x - .5 * sc, y - .5 * sc, 1.2 * sc, .6 * sc, a, C(255, 230, 130), .7 * vis)
    # seed pod: flat-topped receptacle
    q = rr / rp
    pcov = np.clip(rp - rr + .5, 0, 1)
    lam = ((xx - cx) * math.cos(light) + (yy - cy) * math.sin(light)) / rp
    pc = mix(C(222, 228, 120), C(168, 186, 70), smooth(.2, 1.0, q))
    pc = pc * (1 + .08 * np.clip(lam, -1, 1))[..., None]
    pc = mix(pc, C(130, 150, 52), smooth(.82, 1.0, q) * .6)
    tex.over(np.clip(pc, 0, 1), pcov)
    holes = [(0, 0)] + [(math.cos(k * 2 * np.pi / 8 + .3) * .58, math.sin(k * 2 * np.pi / 8 + .3) * .58) for k in range(8)]
    for hx, hy in holes:
        x, y = cx + hx * rp, cy + hy * rp
        hr = rp * .12
        tex.circle(x - math.cos(light) * hr * .3, y - math.sin(light) * hr * .3, hr * 1.08, C(236, 240, 150), .5)
        tex.circle(x, y, hr, C(112, 124, 40), .9)
        tex.circle(x + math.cos(light) * hr * .25, y + math.sin(light) * hr * .25, hr * .55, C(84, 96, 30), .6)

def after_lotus_open(N, seed, pal=PINK_A, rot_light=0.0):
    rng = np.random.default_rng(seed)
    tex = Layer(N, N); S = N; c = (N / 2, N / 2)
    light = LIGHT - rot_light
    layers = [  # count, length, half-width, base radius, pinkness, brightness, edge dark, rot
        (10, .47, .105, .02, 1.00, -.02, .16, 0.0),
        (9, .39, .098, .02, .90, .00, .12, .33),
        (8, .30, .086, .02, .72, .03, .09, .12),
        (6, .205, .070, .02, .55, .05, .06, .55),
    ]
    for (cnt, ln, wd, r0, pk, br, ed, rot) in layers:
        order = rng.permutation(cnt)
        for i in order:
            a = rot + i / cnt * 2 * np.pi + rng.uniform(-.09, .09)
            L = ln * S * rng.uniform(.93, 1.04)
            after_petal(tex, rng, c[0] + math.cos(a) * r0 * S, c[1] + math.sin(a) * r0 * S, a, L, wd * S * rng.uniform(.92, 1.06),
                        pal, pk, br, ed, shadow=.26, light=light)
    stamens_and_pod(tex, rng, c, .072 * S, light=light)
    return tex.a

def after_lotus_half(N, seed, pal=PINK_B, rot_light=0.0):
    rng = np.random.default_rng(seed)
    tex = Layer(N, N); S = N; c = (N / 2, N / 2)
    light = LIGHT - rot_light
    for (cnt, ln, wd, pk, br, ed, rot) in [(8, .44, .13, 1.0, -.02, .16, 0.0), (7, .35, .125, .9, 0.0, .13, .4)]:
        for i in rng.permutation(cnt):
            a = rot + i / cnt * 2 * np.pi + rng.uniform(-.08, .08)
            after_petal(tex, rng, c[0], c[1], a, ln * S * rng.uniform(.94, 1.03), wd * S, pal, pk, br, ed, shadow=.28, light=light, a=.8, b=.8)
    # deep cup: centre in shadow, a glimpse of stamens
    stamens_and_pod(tex, rng, c, .05 * S, n=60, slen=.9, light=light)
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    rr = np.hypot(xx - c[0], yy - c[1])
    tex.a[..., :3] *= (1 - .22 * np.exp(-(rr / (.12 * S)) ** 2))[..., None]
    # inner petals curving inward over the cup (base outside, tips toward the centre)
    for (cnt, rb, ln, wd, pk, rot) in [(6, .27, .20, .095, .95, .2), (5, .19, .135, .08, .85, .75)]:
        for i in rng.permutation(cnt):
            a = rot + i / cnt * 2 * np.pi + rng.uniform(-.08, .08)
            bx, by = c[0] + math.cos(a) * rb * S, c[1] + math.sin(a) * rb * S
            after_petal(tex, rng, bx, by, a + np.pi + rng.uniform(-.12, .12), ln * S, wd * S, pal, pk, -.02, .14,
                        shadow=.34, light=light, a=.75, b=.75, vein_k=11, pink_base=.42)
    return tex.a

def after_bud(N, seed, pal=PINK_A, rot_light=0.0):
    """Closed bud seen from above, slightly tilted: overlapping wrapped petals."""
    rng = np.random.default_rng(seed)
    tex = Layer(N, N); S = N
    light = LIGHT - rot_light
    bx, by = .14 * S, .5 * S
    # short stalk disappearing into the water
    tex.over(C(70, 110, 52), stroke_cov([([(0, .53 * S), (bx + .04 * S, by)], .07 * S)], (N, N)) * .9)
    bud_pal = (C(206, 220, 160), C(238, 172, 196), C(226, 96, 144), C(200, 66, 120))
    after_petal(tex, rng, bx, by, 0.0, .80 * S, .23 * S, bud_pal, 1.0, -.03, .22, shadow=0, a=.55, b=1.0, light=light, vein_k=9, pink_base=.25)
    after_petal(tex, rng, bx + .02 * S, by + .02 * S, -.035, .775 * S, .17 * S, bud_pal, 1.0, .0, .18, shadow=.35, a=.6, b=1.0, light=light, vein_k=8, pink_base=.25)
    after_petal(tex, rng, bx + .04 * S, by - .025 * S, .045, .745 * S, .13 * S, bud_pal, 1.0, .03, .14, shadow=.35, a=.6, b=1.0, light=light, vein_k=7, pink_base=.25)
    # cylindrical shading + gloss stripe
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    v = (yy - by) / (.23 * S)
    a = tex.a[..., 3]
    lam = -v * math.sin(light) * -1
    tex.a[..., :3] *= (1 + .10 * np.clip(-v, -1, 1) * (1 if math.sin(light) < 0 else -1) - .12 * np.clip(np.abs(v), 0, 1) ** 2)[..., None]
    gloss = np.exp(-((v + .45) / .12) ** 2) * smooth(.2, .45, xx / S) * (1 - smooth(.65, .85, xx / S))
    tex.a[..., :3] += (gloss * .16 * a)[..., None]
    tex.a[..., :3] = np.clip(tex.a[..., :3], 0, tex.a[..., 3:])
    return tex.a

def after_duckweed(N, seed, rot_light=0.0):
    rng = np.random.default_rng(seed)
    tex = Layer(N, N); S = N
    light = LIGHT - rot_light
    fr = []
    for _ in range(int(rng.integers(6, 11))):
        fr.append((S / 2 + rng.normal() * S * .15, S / 2 + rng.normal() * S * .15, rng.uniform(.05, .095) * S, rng.uniform(0, 3.14)))
    for px, py, r, a in fr:
        tex.ellipse(px + .12 * r, py + .16 * r, r * 1.02, r * .78, a, C(10, 50, 30), .30)
    for px, py, r, a in fr:
        base = C(116, 184, 66) if rng.random() < .5 else C(94, 162, 58)
        tex.ellipse(px, py, r, r * .74, a, base * .82)
        tex.ellipse(px - .06 * r, py - .06 * r, r * .9, r * .64, a, base)
        tex.ellipse(px + math.cos(light) * .3 * r, py + math.sin(light) * .3 * r, r * .42, r * .26, a, C(214, 238, 150), .35)
        tex.ellipse(px, py, r * .08, r * .08, 0, C(60, 110, 40), .5)
    return tex.a


# ================================================================ SCENE
# (positions in final px of an 800x900 half; render uses SS)
PADS = [  # cx, cy, radius, rotation(deg)
    (300, 590, 158, 0.0),
    (575, 330, 108, 0.0),
    (615, 735, 78, 0.0),
]
NOTCH = [math.radians(65), math.radians(200), math.radians(-30)]
LOTUS_OPEN = (318, 572, 232)
LOTUS_HALF = (566, 318, 142)
BUD = (175, 300, 70, -35)
DUCKWEED = [(140, 150, 70), (700, 520, 58), (95, 470, 52), (440, 840, 64), (420, 120, 44)]
SHADOW_OFF = np.array([13, 17])          # final px, same light for both halves


def render_half(after: bool):
    floor, dmap = pond_floor(RW, RH, ws=SS * 2.0, seed=11)
    canvas = floor
    rng = np.random.default_rng(5)
    items = []   # (tex, cx, cy, deg, kind)
    if not after:
        for i, (x, y, r, deg) in enumerate(PADS):
            N = int(round(2 * r * SS / .94))
            items.append((before_lily_pad(N, i, rng), x * SS, y * SS, deg + i * 40, 'pad', r))
        x, y, s = LOTUS_HALF
        items.append((before_lotus(int(s * SS), 1, rng), x * SS, y * SS, 20, 'flower', s / 2))
        x, y, s = LOTUS_OPEN
        items.append((before_lotus(int(s * SS), 0, rng), x * SS, y * SS, 10, 'flower', s / 2))
        x, y, s, deg = BUD
        items.append((before_lotus(int(s * SS * .55), 0, rng), x * SS, y * SS, 0, 'flower', s / 4))
        for (x, y, s) in DUCKWEED:
            items.append((before_duckweed(int(s * SS), rng), x * SS, y * SS, float(rng.uniform(0, 360)), 'weed', s / 2))
    else:
        cfg = [dict(droplets=[(-.66, .30, .05), (.58, .52, .032), (.70, -.20, .022)], old=False),
               dict(droplets=[(.30, .62, .06)], old=False),
               dict(old=True, tear=(math.radians(150), .28))]
        for i, (x, y, r, deg) in enumerate(PADS):
            N = int(round(2 * r * SS / .94))
            items.append((after_lily_pad(N, 100 + i, NOTCH[i], **cfg[i]), x * SS, y * SS, 0, 'pad', r))
        x, y, s = LOTUS_HALF
        items.append((after_lotus_half(int(s * SS), 21), x * SS, y * SS, 20, 'flower', s / 2))
        x, y, s = LOTUS_OPEN
        items.append((after_lotus_open(int(s * SS), 20), x * SS, y * SS, 10, 'flower', s / 2))
        x, y, s, deg = BUD
        items.append((after_bud(int(s * SS), 22), x * SS, y * SS, deg, 'bud', s / 2))
        for j, (x, y, s) in enumerate(DUCKWEED):
            items.append((after_duckweed(int(s * SS), 40 + j), x * SS, y * SS, float(rng.uniform(0, 360)), 'weed', s / 2))

    shape = (RH, RW)
    off = SHADOW_OFF * SS
    # ---- floor shadows (under the haze, like the app's shadowLayer)
    if not after:
        sh = np.zeros(shape, F32)
        for tex, cx, cy, deg, kind, r in items:
            if kind == 'pad': size = 2.3 * r
            elif kind == 'flower': size = 1.1 * 2 * r
            else: size = .9 * 2 * r
            n = int(size * SS)
            d = soft_disc(n)
            y0, x0 = int(round(cy - n / 2 + off[1])), int(round(cx - n / 2 + off[0]))
            sl = stamp_alpha(shape, np.dstack([np.zeros((n, n, 3), F32), d]), y0, x0)
            sh = 1 - (1 - sh) * (1 - .38 * sl)
        canvas.a[..., :3] *= (1 - sh)[..., None]
    else:
        sh = np.zeros(shape, F32)
        for tex, cx, cy, deg, kind, r in items:
            t = rotate_premul(tex, deg)
            h, w = t.shape[:2]
            y0, x0 = int(round(cy - h / 2)), int(round(cx - w / 2))
            k = {'pad': 1.0, 'flower': 1.55, 'bud': 1.9, 'weed': .8}[kind]
            a = {'pad': .50, 'flower': .40, 'bud': .40, 'weed': .40}[kind]
            m = stamp_alpha(shape, t, y0, x0, int(off[1] * k), int(off[0] * k))
            m = gaussian_filter(m, (7 if kind != 'pad' else 6) * SS * k)
            sh = 1 - (1 - sh) * (1 - a * m)
        canvas.a[..., :3] = canvas.a[..., :3] * (1 - sh)[..., None] + (sh * .35)[..., None] * C(4, 34, 36) * 0
        canvas.a[..., :3] *= 1  # (colour of shadow comes from the haze on top)
    water_over(canvas, dmap)

    # ---- surface items
    pad_alpha = np.zeros(shape, F32)
    for tex, cx, cy, deg, kind, r in items:
        t = rotate_premul(tex, deg)
        h, w = t.shape[:2]
        y0, x0 = int(round(cy - h / 2)), int(round(cx - w / 2))
        if after:
            m = stamp_alpha(shape, t, y0, x0)
            if kind == 'pad':
                # meniscus: faint dark ring hugging the pad on the water
                ring = np.clip(gaussian_filter(m, 3 * SS) * 1.6 - m, 0, 1)
                canvas.a[..., :3] *= (1 - .22 * ring)[..., None]
            else:
                # the flower shades the pad it sits on (only where there is a pad)
                k = 0.55 if kind != 'weed' else .25
                cs = stamp_alpha(shape, t, y0, x0, int(off[1] * k), int(off[0] * k))
                cs = gaussian_filter(cs, 5 * SS) * pad_alpha * (1 - m)
                canvas.a[..., :3] *= (1 - .38 * cs)[..., None]
        canvas.over_premul(t, y0, x0)
        if kind == 'pad':
            pad_alpha = np.maximum(pad_alpha, stamp_alpha(shape, t, y0, x0))
    rgb = np.clip(canvas.a[..., :3], 0, 1)
    img = Image.fromarray((rgb * 255 + .5).astype(np.uint8), 'RGB')
    return img.resize((HALF_W, HALF_H), Image.LANCZOS)


def label(img, text):
    font = ImageFont.truetype('/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc', 40, index=2)  # SC
    ov = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    bb = d.textbbox((0, 0), text, font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    x, y = 28, 24
    d.rounded_rectangle([x, y, x + tw + 40, y + th + 30], radius=18, fill=(8, 40, 38, 150))
    d.text((x + 20 - bb[0], y + 15 - bb[1]), text, font=font, fill=(255, 255, 250, 255))
    return Image.alpha_composite(img.convert('RGBA'), ov).convert('RGB')



# ================================================================ V2 (reference-matched)
# Stylised mint/jade pads after the user's reference: faceted panels between
# prominent radial veins (pale line + dark groove), big central droplet, many
# clear droplets, thin pale rim. Plus koi swimming under the pads.

MINT_C0, MINT_C1, MINT_C2 = C(80, 152, 112), C(106, 178, 134), C(132, 198, 154)
GROOVE = C(46, 112, 90)
RIDGE = C(196, 236, 210)
RIM = C(214, 242, 224)


def draw_droplet(col, xx, yy, px, py, pr, light, sc, strength=1.0):
    """In-place droplet on a colour field (bbox only). Clear, slightly lighter inside,
    soft contact shadow, darker rim (strongest on the lit side), bright caustic on the far
    side, white specular + a tiny secondary glint."""
    N = col.shape[0]
    pad = pr * 1.8 + 3
    y0, y1 = int(max(0, py - pad)), int(min(N, py + pad + 1))
    x0, x1 = int(max(0, px - pad)), int(min(N, px + pad + 1))
    if y0 >= y1 or x0 >= x1:
        return
    X, Y = xx[y0:y1, x0:x1], yy[y0:y1, x0:x1]
    sub = col[y0:y1, x0:x1]
    lx, ly = math.cos(light), math.sin(light)
    # contact shadow, offset away from the light
    ox, oy = -lx * pr * .38, -ly * pr * .38
    dsh = np.hypot(X - px - ox, Y - py - oy) / (pr * 1.02)
    sh = 1 - smooth(.75, 1.25, dsh)
    sub *= (1 - .30 * strength * sh)[..., None]
    dd = np.hypot(X - px, Y - py)
    q = dd / pr
    cov = np.clip(pr - dd + .5, 0, 1)
    # refraction: magnified, slightly lighter leaf
    sx_, sy_ = px + (X - px) * .5, py + (Y - py) * .5
    ref = np.stack([map_coordinates(col[..., i], [sy_ - .5, sx_ - .5], order=1, mode='nearest') for i in range(3)], -1)
    lam = ((X - px) * lx + (Y - py) * ly) / pr          # +1 toward the light
    body = ref * 1.10 + C(16, 22, 18) * (.5 + .5 * np.clip(-lam, 0, 1))[..., None]
    # dark rim: thin outline, heavier on the lit side
    rimw = smooth(.68, .97, q) * (1 - smooth(.97, 1.05, q))
    body = mix(body, GROOVE * .8, rimw * (.38 + .32 * np.clip(lam + .2, 0, 1)) * strength)
    # caustic crescent on the side away from the light
    cx_, cy_ = px - lx * pr * .42, py - ly * pr * .42
    cau = np.exp(-(np.hypot(X - cx_, Y - cy_) / (pr * .38)) ** 2) * (q < 1)
    body = body + (cau * .30)[..., None] * C(225, 255, 235)
    # specular
    spx, spy = px + lx * pr * .42, py + ly * pr * .42
    spec = np.exp(-((np.hypot(X - spx, Y - spy) / (pr * .21)) ** 2.4))
    body = mix(body, C(255, 255, 255), np.clip(spec * 1.0, 0, 1))
    g2 = np.exp(-((np.hypot(X - (px - lx * pr * .5), Y - (py - ly * pr * .5)) / (pr * .09)) ** 2))
    body = mix(body, C(250, 255, 250), g2 * .55)
    sub[:] = mix(sub, np.clip(body, 0, 1), cov)


def pad_v2(N, seed, notch, n_drops=12, nveins=16, center_drop=True, light=LIGHT, old=False):
    rng = np.random.default_rng(seed)
    R = .47 * N; c = N / 2
    sc = N / 600.0
    yy, xx = np.mgrid[0:N, 0:N].astype(F32) + .5
    dx, dy = xx - c, yy - c
    rho = np.hypot(dx, dy) + 1e-4
    th = np.arctan2(dy, dx)
    phi = wrap(th - notch)
    # ---- outline (gently wavy, V notch, rounded lobe tips)
    ph = rng.uniform(0, 2 * np.pi, 6)
    def redge_f(a):
        return R * (1 + .012 * np.sin(5 * a + ph[0]) + .007 * np.sin(9 * a + ph[1]) + .0035 * np.sin(16 * a + ph[2]))
    redge = redge_f(th) * (1 - .03 * np.exp(-((np.abs(phi) - .2) / .35) ** 2))
    half = .12 * (.5 + .5 * np.clip(rho / R, 0, 1)) * smooth(.07, .22, rho / R)
    d_edge = redge - rho
    d_notch = (np.abs(phi) - half) * rho
    kk = .02 * R
    d = -kk * np.logaddexp(-d_edge / kk, -d_notch / kk)
    cov = np.clip(d + .5, 0, 1)
    t = np.clip(rho / redge, 0, 1)

    # ---- veins: common gentle swirl so panels and veins stay aligned
    bend = rng.uniform(-.10, .10)
    swirl = bend * (rho / R) ** 1.6
    psi = (th - notch - swirl) % (2 * np.pi)                 # 0..2pi, notch at 0
    lo, hi = .17, 2 * np.pi - .17
    base = np.linspace(lo, hi, nveins)
    gap = (hi - lo) / (nveins - 1)
    va = np.sort(base + rng.uniform(-.18, .18, nveins) * gap)
    edges = np.concatenate([[0.0], va, [2 * np.pi]])
    k = np.clip(np.searchsorted(edges, psi) - 1, 0, len(edges) - 2)
    a0, a1 = edges[k], edges[k + 1]
    f = np.clip((psi - a0) / np.maximum(a1 - a0, 1e-4), 0, 1)
    d_next = (a1 - psi) * rho              # px to the vein on the "groove" side
    d_prev = (psi - a0) * rho              # px to the vein on the "ridge" side
    is_vein_next = (k < len(edges) - 2)    # last sector ends at the notch, not at a vein
    is_vein_prev = (k > 0)

    # ---- base colour: soft radial gradient + light gradient + subtle mottling
    nlow = fbm((N, N), N / 5, rng, 3)
    nmid = fbm((N, N), N / 25, rng, 3)
    col = np.where((t < .6)[..., None], mix(MINT_C0, MINT_C1, smooth(0, .6, t)), mix(MINT_C1, MINT_C2, smooth(.6, 1, t)))
    col = col * (C(255, 255, 255) + rng.uniform(-.035, .035, 3).astype(F32))   # per-pad hue variety
    if old:
        col = mix(col, C(170, 196, 120), smooth(.75, 1.0, t + .2 * nlow) * .55)
    lamb = (dx * math.cos(light) + dy * math.sin(light)) / R
    col = col * (1 + .07 * lamb + .025 * nlow + .02 * nmid)[..., None]
    # faceted panels: each panel gently concave, slightly different tilt
    tilt = rng.uniform(-.035, .035, len(edges))
    mid_a = (a0 + a1) / 2 + notch
    panel = 1 + tilt[k] + .045 * np.cos(mid_a - light) * smooth(.15, .7, t) - .05 * (1 - np.sin(np.pi * f) ** .5)
    crease = np.exp(-d_next / (9 * sc)) * is_vein_next      # shaded flank before each vein
    ridge = np.exp(-d_prev / (7 * sc)) * is_vein_prev       # lit flank after each vein
    centre_fade = smooth(.06, .2, t)
    panel = panel - .10 * crease * centre_fade + .05 * ridge * centre_fade
    col = col * panel[..., None]

    # ---- vein strokes: dark groove + pale ridge line beside it
    def vein_pts(a, r0, r1, n=40):
        out = []
        for i in range(n):
            s_ = i / (n - 1)
            rr = r0 + (r1 - r0) * s_
            aa = notch + a + bend * (rr / R) ** 1.6 + .006 * math.sin(s_ * 9 + a * 3)
            out.append((c + rr * math.cos(aa), c + rr * math.sin(aa), aa))
        return out
    groove, ridge_l = [], []
    r_start = R * (.095 if center_drop else .03)
    for a in va:
        re = float(redge_f(notch + a)) * .975
        pts = vein_pts(a, r_start, re)
        off = 2.3 * sc
        groove.append(([(x, y) for x, y, _ in pts], 3.2 * sc, 1.4 * sc))
        ridge_l.append(([(x - off * math.sin(aa), y + off * math.cos(aa)) for x, y, aa in pts], 2.0 * sc, .9 * sc))
        if rng.random() < .45:     # a few veins fork near the rim, like the reference
            rf = R * rng.uniform(.58, .75)
            da = gap * rng.uniform(.18, .28) * (1 if rng.random() < .5 else -1)
            pts2 = []
            for i in range(16):
                s_ = i / 15
                rr = rf + (re - rf) * s_
                aa = notch + a + bend * (rr / R) ** 1.6 + da * s_ ** 1.3
                pts2.append((c + rr * math.cos(aa), c + rr * math.sin(aa), aa))
            groove.append(([(x, y) for x, y, _ in pts2], 1.8 * sc, 1.0 * sc))
            ridge_l.append(([(x - off * .8 * math.sin(aa), y + off * .8 * math.cos(aa)) for x, y, aa in pts2], 1.3 * sc, .7 * sc))
    g = gaussian_filter(tapered_cov(groove, (N, N)), .7 * sc)
    rl = gaussian_filter(tapered_cov(ridge_l, (N, N)), .8 * sc)
    vf = 1 - .35 * smooth(.85, 1.0, t)
    col = mix(col, RIDGE, rl * .55 * vf)
    col = mix(col, GROOVE, g * .72 * vf)

    # ---- rim: thin pale outline with a faint darker line just inside
    col = col * (1 - .14 * np.exp(-((d - 4.2 * sc) / (1.6 * sc)) ** 2))[..., None]
    col = mix(col, RIM, np.clip(np.exp(-((d - 1.2 * sc) / (1.3 * sc)) ** 2) * (.70 + .25 * np.clip(-lamb, 0, 1)), 0, .95))
    # soft waxy sheen
    lx, ly = c + math.cos(light) * R * .4, c + math.sin(light) * R * .4
    sheen = np.exp(-(((xx - lx) / (R * .6)) ** 2 + ((yy - ly) / (R * .45)) ** 2))
    col = col + (sheen * .05)[..., None] * C(220, 255, 235)
    col = np.clip(col, 0, 1)

    # ---- droplets
    drops = []
    if center_drop:
        drops.append((c, c, R * .095, 1.0))
    tries = 0
    while len(drops) < n_drops + (1 if center_drop else 0) and tries < 3000:
        tries += 1
        u = rng.random()
        pr = R * (.011 + .050 * u ** 2.2)
        if n_drops >= 12 and len(drops) < 3 + (1 if center_drop else 0):
            pr = R * rng.uniform(.06, .08)        # a few big beads on large pads
        rr = R * math.sqrt(rng.uniform(.03, .80)) ; a = rng.uniform(0, 2 * np.pi)
        if abs(wrap(a - notch)) < .35:
            continue
        px, py = c + rr * math.cos(a), c + rr * math.sin(a)
        if rr + pr > R * .9 or any(math.hypot(px - qx, py - qy) < (pr + qr) * 1.5 for qx, qy, qr, _ in drops):
            continue
        drops.append((px, py, pr, 1.0))
    for px, py, pr, st in drops:
        draw_droplet(col, xx, yy, px, py, pr, light, sc, st)

    out = np.zeros((N, N, 4), F32)
    out[..., :3] = np.clip(col, 0, 1) * cov[..., None]
    out[..., 3] = cov
    return out


# ---------------------------------------------------------------- koi (port of FishArt + bend)
def koi(L, pattern, seed, bend=0.0):
    """Koi texture, head pointing +x. L = length in render px. Returns premultiplied RGBA
    on an L x 0.6L canvas and its silhouette (for the floor shadow)."""
    rng = np.random.default_rng(seed)
    W, H = int(L), int(L * .6)
    cy = H / 2
    xp, xn, wmax = .28 * L, .94 * L, .11 * L
    yy, xx = np.mgrid[0:H, 0:W].astype(F32) + .5
    s = (xx - xp) / (xn - xp)
    sc_ = np.clip(s, 0, 1)
    hw = np.where(sc_ < .6, wmax * (.16 + .84 * np.sin(sc_ / .6 * np.pi / 2) ** 1.2),
                  wmax * np.sqrt(np.clip(1 - np.clip((sc_ - .6) / .4, 0, 1) ** 2.2, 0, 1)))
    body = np.clip(hw - np.abs(yy - cy) + .5, 0, 1) * (s >= 0) * (s <= 1)
    spread = rng.uniform(.13, .17) * L
    def q(p0, c_, p1, n=16):
        t = np.linspace(0, 1, n)[:, None]
        return (1 - t) ** 2 * np.array(p0) + 2 * (1 - t) * t * np.array(c_) + t * t * np.array(p1)
    tail_pts = np.concatenate([
        q((xp + .03 * L, cy + .02 * L), (.20 * L, cy + .11 * L), (.05 * L, cy + spread)),
        q((.05 * L, cy + spread), (.07 * L, cy + .05 * L), (.15 * L, cy)),
        q((.15 * L, cy), (.07 * L, cy - .05 * L), (.05 * L, cy - spread)),
        q((.05 * L, cy - spread), (.20 * L, cy - .11 * L), (xp + .03 * L, cy - .02 * L))])
    tail = poly_cov([tuple(p) for p in tail_pts], (H, W))
    white = C(248, 244, 238); red = C(224, 58, 34); orange = C(242, 112, 36); black = C(26, 26, 32)
    basec, finc = white, white
    if pattern == 'hi':
        basec = mix(red, orange, .35); finc = orange * 1.05
    elif pattern == 'orenji':
        basec = orange; finc = np.clip(orange * 1.08, 0, 1)
    tex = Layer(H, W)
    # pectoral fins (under the body)
    fx = xp + (xn - xp) * .70
    for side in (-1, 1):
        fw, fh = .17 * L, .12 * L
        pts = [(fx, cy + side * hw.max() * .6),
               (fx - fw * .35, cy + side * (wmax + fh * .9)),
               (fx - fw * .75, cy + side * (wmax + fh * .7)),
               (fx - fw * .55, cy + side * (wmax * .6))]
        fp = cubic(pts[0], pts[1], pts[2], pts[3], 20)
        fin = poly_cov([tuple(p) for p in fp] + [(fx - fw * .2, cy + side * wmax * .5)], (H, W))
        tex.over(finc, fin * .55)
    # tail with rays
    tex.over(finc, tail * .58)
    rays = stroke_cov([([(xp + .03 * L, cy), (.03 * L, cy + a * spread * 1.1)], .006 * L) for a in np.linspace(-1, 1, 11)], (H, W))
    tex.over(finc * .8, rays * tail * .35)
    # body + pattern
    bl = Layer(H, W, bg=basec)
    def blob(x, y, r, colr):
        for _ in range(int(rng.integers(3, 7))):
            bl.ellipse(x + rng.uniform(-1, 1) * r * .7, y + rng.uniform(-1, 1) * r * .7, r * rng.uniform(.6, 1.1), r * rng.uniform(.5, .9), rng.uniform(0, 3.14), colr)
    if pattern in ('kohaku', 'sanke'):
        cnt = int(rng.integers(2, 5))
        for kk in range(cnt):
            x = xp + (xn - xp) * (.15 + .8 * (kk + rng.uniform(.1, .9)) / cnt)
            blob(x, cy + rng.uniform(-.03, .03) * L, rng.uniform(.05, .08) * L, red)
        if pattern == 'sanke':
            for _ in range(int(rng.integers(3, 8))):
                blob(xp + (xn - xp) * rng.uniform(.05, .85), cy + rng.uniform(-.06, .06) * L, rng.uniform(.018, .035) * L, black)
    else:
        for _ in range(4):
            blob(xp + (xn - xp) * rng.uniform(.1, .9), cy + rng.uniform(-.08, .08) * L, rng.uniform(.03, .05) * L, np.clip(basec * 1.12, 0, 1))
    bl.ellipse(xp + (xn - xp) * .52, cy, (xn - xp) * .36, .022 * L, 0, C(255, 255, 255), .20)
    bcol = bl.a[..., :3]
    edge = np.clip(np.abs(yy - cy) / np.maximum(hw, 1e-3), 0, 1)
    bcol = bcol * (1 - .28 * edge ** 3)[..., None]
    tex.over(bcol, body)
    tex.ellipse(xp + (xn - xp) * .38, cy, (xn - xp) * .22, .008 * L, 0, finc * .9, .45)
    ex = xp + (xn - xp) * .88
    ey = wmax * math.sqrt(max(0, 1 - ((.88 - .6) / .4) ** 2.2)) * .78
    for side in (-1, 1):
        tex.circle(ex, cy + side * ey, .013 * L, C(18, 16, 20), .95)
        tex.circle(ex + .004 * L, cy + side * ey - .004 * L, .004 * L, C(255, 255, 255), .7)
    sil = np.maximum(body, tail * .55)
    # bend the whole fish (C-curve) by shifting rows per column
    if abs(bend) > 1e-4:
        offs = bend * L * ((xx / L - .62) ** 2 - .14)
        warped = [map_coordinates(tex.a[..., i], [yy - .5 - offs, xx - .5], order=1, mode='constant') for i in range(4)]
        tex.a = np.stack(warped, -1)
        sil = map_coordinates(sil, [yy - .5 - offs, xx - .5], order=1, mode='constant')
    return tex.a, sil


# ---------------------------------------------------------------- V2 scene (final px, 1600x900)
V2_W, V2_H = 1600, 900
V2_PADS = [  # cx, cy, r, notch(deg), droplets
    (360, 560, 165, 60, 26), (572, 702, 105, 200, 15), (190, 320, 72, -40, 8),
    (668, 548, 74, 250, 8), (1190, 300, 150, 120, 24), (1345, 432, 95, 10, 13),
    (985, 160, 68, 300, 8), (1290, 770, 118, 220, 17), (1438, 700, 58, 80, 6),
    (850, 850, 80, 160, 10),
]
V2_OPEN = (600, 470, 230)
V2_HALF = (1035, 400, 150)
V2_BUDS = [(1095, 565, 74, 25), (238, 792, 62, -55)]
V2_FISH = [  # cx, cy, length, heading (deg CCW, 0 = right), pattern, bend
    (200, 680, 175, 30, 'kohaku', .10),
    (1362, 222, 150, 180, 'orenji', -.08),
    (800, 360, 165, 20, 'sanke', .06),
    (925, 620, 112, 200, 'hi', -.10),
    (1180, 762, 132, 0, 'kohaku', .07),
    (700, 132, 122, 150, 'orenji', .09),
]
V2_WEED = [(90, 150, 70), (760, 600, 58), (470, 860, 60), (1550, 330, 52), (1110, 60, 50), (680, 250, 46), (1560, 880, 50), (60, 450, 48)]


def render_v2():
    S = SS
    W, H = V2_W * S, V2_H * S
    shape = (H, W)
    floor, dmap = pond_floor(W, H, ws=S * 2.0, seed=11)
    cv = floor
    off = SHADOW_OFF * S
    rng = np.random.default_rng(9)

    # ---- fish shadows on the floor (fish swim ~halfway down -> shorter offset)
    fish = []
    fsh = np.zeros(shape, F32)
    for j, (x, y, Lf, hd, pat, bend) in enumerate(V2_FISH):
        tex, sil = koi(Lf * S, pat, 300 + j, bend)
        silp = np.dstack([np.zeros(sil.shape + (3,), F32), sil])
        ts, y0, x0 = None, 0, 0
        ts = rotate_premul(silp, hd)
        h, w = ts.shape[:2]
        y0, x0 = int(round(y * S - h / 2)), int(round(x * S - w / 2))
        fsh = np.maximum(fsh, stamp_alpha(shape, ts, y0, x0, int(off[1] * .55), int(off[0] * .55)))
        fish.append((tex, x * S, y * S, hd))
    fsh = gaussian_filter(fsh, 6 * S)
    cv.a[..., :3] *= (1 - .40 * fsh)[..., None]
    # ---- water body (deep haze, glaze, caustics) — fish are above the haze, like the app
    water_over(cv, dmap)
    # ---- fish, slightly veiled by the water above them
    veil = mix(C(0x71, 0xE6, 0xC2), C(0x1A, 0x59, 0x52), .55)
    for tex, x, y, hd in fish:
        t = rotate_premul(tex, hd)
        a = t[..., 3:]
        t[..., :3] = t[..., :3] * .82 + veil * .18 * a
        h, w = t.shape[:2]
        cv.over_premul(t, int(round(y - h / 2)), int(round(x - w / 2)))

    # ---- surface items
    items = []
    for i, (x, y, r, nd, ndrop) in enumerate(V2_PADS):
        N = int(round(2 * r * S / .94))
        items.append((pad_v2(N, 500 + i, math.radians(nd), n_drops=ndrop, nveins=int(14 + (r > 100) * 3)), x * S, y * S, 0, 'pad'))
    for j, (x, y, sz) in enumerate(V2_WEED):
        items.append((after_duckweed(int(sz * S), 40 + j), x * S, y * S, float(rng.uniform(0, 360)), 'weed'))
    x, y, sz = V2_HALF
    items.append((after_lotus_half(int(sz * S), 21), x * S, y * S, 20, 'flower'))
    x, y, sz = V2_OPEN
    items.append((after_lotus_open(int(sz * S), 20), x * S, y * S, 10, 'flower'))
    for j, (x, y, sz, deg) in enumerate(V2_BUDS):
        items.append((after_bud(int(sz * S), 22 + j), x * S, y * S, deg, 'bud'))

    # shadows cast by surface items onto everything below (floor + fish), grouped per kind
    groups = {}
    placed = []
    for tex, x, y, deg, kind in items:
        t = rotate_premul(tex, deg)
        h, w = t.shape[:2]
        y0, x0 = int(round(y - h / 2)), int(round(x - w / 2))
        placed.append((t, y0, x0, kind))
        k = {'pad': 1.0, 'flower': 1.55, 'bud': 1.9, 'weed': .8}[kind]
        m = stamp_alpha(shape, t, y0, x0, int(off[1] * k), int(off[0] * k))
        groups[kind] = np.maximum(groups.get(kind, np.zeros(shape, F32)), m)
    sh = np.zeros(shape, F32)
    for kind, m in groups.items():
        k = {'pad': 1.0, 'flower': 1.55, 'bud': 1.9, 'weed': .8}[kind]
        a = {'pad': .48, 'flower': .40, 'bud': .40, 'weed': .40}[kind]
        m = gaussian_filter(m, (6 if kind == 'pad' else 7) * S * k)
        sh = 1 - (1 - sh) * (1 - a * m)
    cv.a[..., :3] *= (1 - sh)[..., None]

    pad_alpha = np.zeros(shape, F32)
    for t, y0, x0, kind in placed:
        m = stamp_alpha(shape, t, y0, x0)
        if kind == 'pad':
            ring = np.clip(gaussian_filter(m, 3 * S) * 1.6 - m, 0, 1)
            cv.a[..., :3] *= (1 - .25 * ring)[..., None]
        elif kind != 'weed':
            cs = stamp_alpha(shape, t, y0, x0, int(off[1] * .55), int(off[0] * .55))
            cs = gaussian_filter(cs, 5 * S) * pad_alpha * (1 - m)
            cv.a[..., :3] *= (1 - .38 * cs)[..., None]
        cv.over_premul(t, y0, x0)
        if kind == 'pad':
            pad_alpha = np.maximum(pad_alpha, m)
    rgb = np.clip(cv.a[..., :3], 0, 1)
    big = Image.fromarray((rgb * 255 + .5).astype(np.uint8), 'RGB')
    img = big.resize((V2_W, V2_H), Image.LANCZOS)
    img.save(os.path.join(OUT_DIR, 'lotus_after_v2.png'))
    # close-up: pad 1 at full 2x resolution
    x, y, r = V2_PADS[0][:3]
    half_c = 400
    cx, cy = int(x * S), int(y * S)
    big.crop((cx - half_c, cy - half_c, cx + half_c, cy + half_c)).save(os.path.join(OUT_DIR, 'lotus_pad_closeup.png'))
    print('v2 ok')


def main_compare():
    before = render_half(False)
    after = render_half(True)
    before.save(os.path.join(OUT_DIR, 'lotus_before.png'))
    after.save(os.path.join(OUT_DIR, 'lotus_after.png'))
    comp = Image.new('RGB', (HALF_W * 2, HALF_H))
    comp.paste(label(before, '现在'), (0, 0))
    comp.paste(label(after, '优化后'), (HALF_W, 0))
    d = ImageDraw.Draw(comp)
    d.rectangle([HALF_W - 2, 0, HALF_W + 1, HALF_H], fill=(240, 250, 245))
    comp.save(os.path.join(OUT_DIR, 'lotus_compare.png'))
    print('ok')


if __name__ == '__main__':
    import sys
    if 'compare' in sys.argv[1:]:
        main_compare()      # v1 before/after comparison
    else:
        render_v2()
