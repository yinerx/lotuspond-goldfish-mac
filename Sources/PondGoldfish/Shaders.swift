import SpriteKit

/// SpriteKit fragment shaders (GLSL-ES style; SpriteKit translates them to Metal).
/// Custom uniforms are attached through `SKShader.uniforms` and are declared by
/// SpriteKit automatically, so they are *not* re-declared in the sources below.
enum Shaders {

    // MARK: Pond floor: refraction wobble + water tint + animated caustic web.
    //  u_t        float  animation time
    //  u_tint     vec3   water colour relative to the default (1,1,1 = as painted)
    //  u_caustic  float  caustic intensity (follows sun altitude / intensity / clarity)
    //  u_scale    vec2   caustic pattern frequency across the sprite (x, y)
    //  u_wobble   float  refraction wobble amount in uv units
    static let floorSource = """
    float causticLayer(vec2 p, float t) {
        vec2 i = p;
        float c = 1.0;
        float inten = 0.005;
        for (int n = 0; n < 3; n++) {
            float tt = t * (1.0 - (3.5 / float(n + 1)));
            i = p + vec2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
            c += 1.0 / length(vec2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
        }
        c /= 3.0;
        c = 1.17 - pow(abs(c), 1.4);
        return pow(abs(c), 8.0);
    }

    void main() {
        vec2 uv = v_tex_coord;
        float t = u_t;
        vec2 w = vec2(sin(uv.y * 31.0 + t * 1.3) + sin(uv.x * 17.0 - t * 0.7),
                      cos(uv.x * 27.0 + t * 1.1) + cos(uv.y * 13.0 + t * 0.9)) * u_wobble;
        vec4 base = texture2D(u_texture, uv + w);

        // Two non-tiling layers of the classic water-caustic iteration (after Dave Hoskins),
        // at different scales / phases so no repetition is visible on large screens.
        float tau = 6.28318530718;
        vec2 p1 = uv * u_scale * tau - 250.0;
        vec2 p2 = (uv * u_scale * 1.41 + vec2(0.37, 0.61)) * tau - 250.0;
        float caus = (causticLayer(p1, t) + causticLayer(p2, t * 0.83 + 7.0)) * 0.9;
        caus = clamp(caus, 0.0, 1.6);

        vec3 col = base.rgb * u_tint;
        // Light only reaches lit floor: darker texels (shadows / crevices) get less caustic.
        float lum = dot(col, vec3(0.3, 0.59, 0.11));
        float k = u_caustic * (0.55 + 0.6 * lum);
        col = col * (1.0 - 0.12 * u_caustic) + col * caus * 0.85 * k
              + vec3(0.80, 1.0, 0.88) * caus * caus * 0.10 * k;
        gl_FragColor = vec4(col, 1.0);
    }
    """

    // MARK: Depth haze: deep-water colour layered over the floor (below the fish).
    //  u_t      float
    //  u_deep   vec3   深水色
    //  u_haze   float  overall strength (from 水面透明度 / 水面高度)
    static let hazeSource = """
    void main() {
        vec2 uv = v_tex_coord;
        vec2 drift = vec2(sin(u_t * 0.05 + uv.y * 3.0), cos(u_t * 0.04 + uv.x * 2.0)) * 0.006;
        float d = texture2D(u_texture, uv + drift).r;
        float a = clamp(u_haze * (0.30 + 0.90 * d), 0.0, 0.92);
        gl_FragColor = vec4(u_deep * a, a);
    }
    """

    // MARK: Surface sparkle (additive), drawn above the fish.
    //  u_t, u_scale (vec2), u_glint (float)
    static let glintSource = """
    void main() {
        vec2 uv = v_tex_coord * u_scale;
        float t = u_t;
        float a = sin(uv.x * 6.1 + t * 0.9 + sin(uv.y * 4.3 - t * 0.6) * 1.9);
        float b = sin(uv.y * 5.7 - t * 0.8 + sin(uv.x * 3.9 + t * 0.5) * 2.3);
        float c = sin((uv.x * 2.7 - uv.y * 3.1) * 2.0 + t * 0.7);
        float s = pow(max(a * b * c, 0.0), 14.0);
        float broad = 0.5 + 0.5 * sin(uv.x * 0.9 + uv.y * 0.7 + t * 0.15);
        float v = s * u_glint * (0.35 + 0.65 * broad) * 0.9;
        gl_FragColor = vec4(v, v, v * 0.95, 1.0);
    }
    """

    static func makeFloor() -> SKShader {
        let s = SKShader(source: floorSource)
        s.uniforms = [
            SKUniform(name: "u_t", float: 0),
            SKUniform(name: "u_tint", vectorFloat3: SIMD3<Float>(1, 1, 1)),
            SKUniform(name: "u_caustic", float: 1),
            SKUniform(name: "u_scale", vectorFloat2: SIMD2<Float>(4, 3)),
            SKUniform(name: "u_wobble", float: 0.0012)
        ]
        return s
    }

    static func makeHaze() -> SKShader {
        let s = SKShader(source: hazeSource)
        s.uniforms = [
            SKUniform(name: "u_t", float: 0),
            SKUniform(name: "u_deep", vectorFloat3: SIMD3<Float>(0.1, 0.35, 0.32)),
            SKUniform(name: "u_haze", float: 0.2)
        ]
        return s
    }

    static func makeGlint() -> SKShader {
        let s = SKShader(source: glintSource)
        s.uniforms = [
            SKUniform(name: "u_t", float: 0),
            SKUniform(name: "u_scale", vectorFloat2: SIMD2<Float>(6, 4)),
            SKUniform(name: "u_glint", float: 0.5)
        ]
        return s
    }
}

extension SKShader {
    func setFloat(_ name: String, _ v: Double) {
        uniformNamed(name)?.floatValue = Float(v)
    }
    func setVec2(_ name: String, _ v: SIMD2<Float>) {
        uniformNamed(name)?.vectorFloat2Value = v
    }
    func setVec3(_ name: String, _ v: SIMD3<Float>) {
        uniformNamed(name)?.vectorFloat3Value = v
    }
}
