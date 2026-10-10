import Foundation

/// Everything the scene needs to light the pond for one moment.
struct LightState {
    /// Multiply-blended over the whole scene (white = neutral daylight).
    var ambient = RGB(1, 1, 1)
    /// Caustic strength on the pond floor (0 = none).
    var caustic: Double = 1
    /// Sun glint / sparkle on the surface.
    var glint: Double = 0.5
    /// Opacity of drop shadows on the floor.
    var shadowAlpha: Double = 0.34
    /// Shadow displacement per point of height above the floor (direction away from the sun).
    var shadowDir = V2(0.55, -0.6)
    /// 0 = night, 1 = full day.
    var day: Double = 1
    var altitude: Double = 45

    mutating func approach(_ t: LightState, _ k: Double) {
        ambient = RGB.mix(ambient, t.ambient, k)
        caustic = lerp(caustic, t.caustic, k)
        glint = lerp(glint, t.glint, k)
        shadowAlpha = lerp(shadowAlpha, t.shadowAlpha, k)
        shadowDir = shadowDir + (t.shadowDir - shadowDir) * k
        day = lerp(day, t.day, k)
        altitude = lerp(altitude, t.altitude, k)
    }
}

enum SunModel {
    /// NOAA "general solar position" approximation. Good to ~0.5°.
    /// - Returns: altitude above the horizon and azimuth (clockwise from north), both in degrees.
    static func solarPosition(date: Date, latitude: Double, longitude: Double) -> (altitude: Double, azimuth: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hourUTC = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600

        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (hourUTC - 12) / 24)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                               - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let trueSolarMinutes = hourUTC * 60 + eqTime + 4 * longitude
        let hourAngle = (trueSolarMinutes / 4 - 180) * Double.pi / 180
        let lat = latitude * Double.pi / 180

        let cosZenith = clampD(sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(hourAngle), -1, 1)
        let zenith = acos(cosZenith)
        let altitude = 90 - zenith * 180 / Double.pi

        // Azimuth measured clockwise from north.
        let az = atan2(sin(hourAngle), cos(hourAngle) * sin(lat) - tan(decl) * cos(lat))
        var azimuth = az * 180 / Double.pi + 180
        azimuth = fmod(azimuth + 360, 360)
        return (altitude, azimuth)
    }

    /// Longitude estimate from the current time zone (no location permission needed).
    static func estimatedLongitude(for date: Date = Date()) -> Double {
        let tz = TimeZone.current
        let standard = Double(tz.secondsFromGMT(for: date)) - tz.daylightSavingTimeOffset(for: date)
        return standard / 240.0   // seconds / 3600 * 15
    }

    static func currentPosition(latitude: Double) -> (altitude: Double, azimuth: Double) {
        let now = Date()
        return solarPosition(date: now, latitude: latitude, longitude: estimatedLongitude(for: now))
    }

    /// Converts a sun position into scene lighting.
    static func lighting(altitude a: Double, azimuth: Double, intensity: Double, rain: Bool) -> LightState {
        var L = LightState()
        L.altitude = a
        let day = smoothstep(-8, 12, a)
        // Warm "golden hour" bell around the horizon.
        let warm = a > -12 ? exp(-pow((a - 3) / 8, 2)) : 0
        let night = RGB(0.20, 0.31, 0.44)
        let dusk = RGB(1.0, 0.72, 0.50)
        var amb = RGB.mix(night, RGB(1, 1, 1), day)
        amb = RGB(amb.r * lerp(1, dusk.r, warm * 0.85),
                  amb.g * lerp(1, dusk.g, warm * 0.85),
                  amb.b * lerp(1, dusk.b, warm * 0.85))
        let i = clampD(intensity, 0, 2)
        amb = amb.scaled(lerp(1, 0.80 + 0.20 * i, day))
        if rain { amb = amb.scaled(0.84) }
        L.ambient = amb
        L.day = day

        L.caustic = i * smoothstep(-2, 28, a) * (rain ? 0.35 : 1)
        L.glint = i * smoothstep(2, 40, a) * (rain ? 0.0 : 0.55) + warm * 0.25 * i * (rain ? 0 : 1)
        // Shadows: crisp & lighter at noon, deeper (but softer) at night.
        L.shadowAlpha = lerp(0.48, 0.32, day) * (rain ? 0.8 : 1) * (0.75 + 0.25 * min(i, 1))

        if a > 0 {
            let azr = azimuth * Double.pi / 180
            let sunOnScreen = V2(sin(azr), cos(azr))          // screen up = north
            let length = clampD(1 / tan(max(a, 7) * Double.pi / 180), 0.3, 2.6)
            L.shadowDir = sunOnScreen * (-length)
        } else {
            // Moon / sky light: short, soft, down-right.
            L.shadowDir = V2(0.30, -0.42)
        }
        return L
    }
}
