import AppKit

/// Entry point. A plain AppKit app (no SwiftUI App lifecycle) so we fully control
/// the desktop-level wallpaper windows and the menu-bar status item.
@main
struct PondGoldfishMain {
    @MainActor
    static func main() {
        // Offline render of the lily pads (used by CI to check the art without a display):
        //   PondGoldfish --render-lily-preview out.png [width height pxPerPt]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-lily-preview") {
            let rest = Array(args.dropFirst(i + 1))
            let path = rest.first ?? "lily_preview.png"
            let w = rest.count > 1 ? Double(rest[1]) ?? 1600 : 1600
            let h = rest.count > 2 ? Double(rest[2]) ?? 900 : 900
            let s = rest.count > 3 ? Double(rest[3]) ?? 1 : 1
            LilyPreview.render(to: path, width: w, height: h, pxPerPt: s)
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
