import AppKit

/// Entry point. A plain AppKit app (no SwiftUI App lifecycle) so we fully control
/// the desktop-level wallpaper windows and the menu-bar status item.
@main
struct PondGoldfishMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
