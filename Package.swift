// swift-tools-version:5.9
// 池塘金鱼 · Pond Goldfish — a native macOS animated pond wallpaper.
// 双击此文件即可用 Xcode 打开；或在终端执行 `swift run` / `./build_app.sh`。
import PackageDescription

let package = Package(
    name: "PondGoldfish",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PondGoldfish", targets: ["PondGoldfish"])
    ],
    targets: [
        .executableTarget(
            name: "PondGoldfish",
            path: "Sources/PondGoldfish",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SpriteKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreImage"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
