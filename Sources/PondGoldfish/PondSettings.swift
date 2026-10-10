import Foundation
import Combine

/// All user-tunable settings. Persisted in UserDefaults; observed by the SwiftUI
/// settings panel and polled every frame by the SpriteKit scenes (reads are cheap).
final class PondSettings: ObservableObject {
    static let shared = PondSettings()

    static let defaultWaterHex = "#71E6C2"
    static let defaultDeepHex = "#1A5952"

    private let ud = UserDefaults.standard

    private enum K {
        static let water = "pond.waterColor"
        static let deep = "pond.deepColor"
        static let waterHeight = "pond.waterHeight"
        static let clarity = "pond.waterClarity"
        static let sunAltitude = "pond.sunAltitude"
        static let followTime = "pond.followRealTime"
        static let sunIntensity = "pond.sunIntensity"
        static let petals = "pond.petals"
        static let leaves = "pond.leaves"
        static let rain = "pond.rain"
        static let fishCount = "pond.fishCount"
        static let fps = "pond.fps"
        static let reduceOnBattery = "pond.reduceOnBattery"
        static let wallpaperMode = "pond.wallpaperMode"
        static let latitude = "pond.latitude"
    }

    private static let defaults: [String: Any] = [
        K.water: defaultWaterHex,
        K.deep: defaultDeepHex,
        K.waterHeight: 0.5,
        K.clarity: 0.75,
        K.sunAltitude: 45.0,
        K.followTime: true,
        K.sunIntensity: 1.0,
        K.petals: true,
        K.leaves: true,
        K.rain: false,
        K.fishCount: 18.0,
        K.fps: 60,
        K.reduceOnBattery: true,
        K.wallpaperMode: false,
        K.latitude: 31.2
    ]

    /// 水色 (hex, e.g. #71E6C2)
    @Published var waterHex: String { didSet { ud.set(waterHex, forKey: K.water) } }
    /// 深水色
    @Published var deepHex: String { didSet { ud.set(deepHex, forKey: K.deep) } }
    /// 水面高度 0...1 (deeper water -> longer shadow offset, more depth tint)
    @Published var waterHeight: Double { didSet { ud.set(waterHeight, forKey: K.waterHeight) } }
    /// 水面透明度 0...1 (1 = crystal clear)
    @Published var waterClarity: Double { didSet { ud.set(waterClarity, forKey: K.clarity) } }
    /// 太阳高度角 (degrees, -20...90), used when followRealTime == false
    @Published var sunAltitude: Double { didSet { ud.set(sunAltitude, forKey: K.sunAltitude) } }
    /// 跟随现实时间
    @Published var followRealTime: Bool { didSet { ud.set(followRealTime, forKey: K.followTime) } }
    /// 太阳光强度 0...2
    @Published var sunIntensity: Double { didSet { ud.set(sunIntensity, forKey: K.sunIntensity) } }
    /// 开启花瓣
    @Published var petalsEnabled: Bool { didSet { ud.set(petalsEnabled, forKey: K.petals) } }
    /// 开启落叶
    @Published var leavesEnabled: Bool { didSet { ud.set(leavesEnabled, forKey: K.leaves) } }
    /// 下雨
    @Published var rainEnabled: Bool { didSet { ud.set(rainEnabled, forKey: K.rain) } }
    /// 鱼的数量 5...30
    @Published var fishCount: Double { didSet { ud.set(fishCount, forKey: K.fishCount) } }
    /// 目标帧率 (30 / 60 / 120)
    @Published var fps: Int { didSet { ud.set(fps, forKey: K.fps) } }
    /// 使用电池 / 低电量模式时降到 30fps
    @Published var reduceOnBattery: Bool { didSet { ud.set(reduceOnBattery, forKey: K.reduceOnBattery) } }
    /// true = 桌面壁纸模式, false = 窗口模式
    @Published var wallpaperMode: Bool { didSet { ud.set(wallpaperMode, forKey: K.wallpaperMode) } }
    /// Latitude used for the sun position (longitude is derived from the time zone).
    @Published var latitude: Double { didSet { ud.set(latitude, forKey: K.latitude) } }

    init() {
        ud.register(defaults: Self.defaults)
        waterHex = ud.string(forKey: K.water) ?? Self.defaultWaterHex
        deepHex = ud.string(forKey: K.deep) ?? Self.defaultDeepHex
        waterHeight = ud.double(forKey: K.waterHeight)
        waterClarity = ud.double(forKey: K.clarity)
        sunAltitude = ud.double(forKey: K.sunAltitude)
        followRealTime = ud.bool(forKey: K.followTime)
        sunIntensity = ud.double(forKey: K.sunIntensity)
        petalsEnabled = ud.bool(forKey: K.petals)
        leavesEnabled = ud.bool(forKey: K.leaves)
        rainEnabled = ud.bool(forKey: K.rain)
        fishCount = ud.double(forKey: K.fishCount)
        let f = ud.integer(forKey: K.fps)
        fps = [30, 60, 120].contains(f) ? f : 60
        reduceOnBattery = ud.bool(forKey: K.reduceOnBattery)
        wallpaperMode = ud.bool(forKey: K.wallpaperMode)
        latitude = ud.double(forKey: K.latitude)
    }

    var waterColor: RGB { RGB(hex: waterHex) }
    var deepColor: RGB { RGB(hex: deepHex) }
    var fishTarget: Int { Int(clampD(fishCount, 5, 30).rounded()) }

    /// 恢复默认 (keeps the current display mode).
    func resetToDefaults() {
        waterHex = Self.defaultWaterHex
        deepHex = Self.defaultDeepHex
        waterHeight = 0.5
        waterClarity = 0.75
        sunAltitude = 45
        followRealTime = true
        sunIntensity = 1
        petalsEnabled = true
        leavesEnabled = true
        rainEnabled = false
        fishCount = 18
        fps = 60
        reduceOnBattery = true
        latitude = 31.2
    }
}
