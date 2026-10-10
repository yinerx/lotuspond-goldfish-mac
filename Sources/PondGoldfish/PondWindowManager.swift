import AppKit
import SpriteKit

/// Owns the pond windows: one borderless desktop-level window per screen in
/// 桌面壁纸模式, or one normal resizable window in 窗口模式.
@MainActor
final class PondWindowManager: NSObject, NSWindowDelegate {
    private(set) var windows: [NSWindow] = []
    private var views: [SKView] = []
    private(set) var isWallpaper = false
    private var globalPaused = false
    private var fps = 60

    var scenes: [PondScene] { views.compactMap { $0.scene as? PondScene } }
    var mainWindow: NSWindow? { isWallpaper ? nil : windows.first }

    func apply(wallpaper: Bool) {
        tearDown()
        isWallpaper = wallpaper
        if wallpaper {
            for screen in NSScreen.screens { makeWallpaperWindow(on: screen) }
        } else {
            makeNormalWindow()
        }
        refreshPauseState()
    }

    func showWindow() {
        guard !isWallpaper, let w = windows.first else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setPaused(_ paused: Bool) {
        globalPaused = paused
        refreshPauseState()
    }

    func setFPS(_ value: Int) {
        guard value != fps else { return }
        fps = value
        for v in views { v.preferredFramesPerSecond = value }
    }

    // MARK: - Window construction

    private func makeView(size: CGSize, interactive: Bool) -> SKView {
        let v = SKView(frame: NSRect(origin: .zero, size: size))
        v.autoresizingMask = [.width, .height]
        v.ignoresSiblingOrder = true
        v.shouldCullNonVisibleNodes = true
        v.preferredFramesPerSecond = fps
        v.allowsTransparency = false
        let scene = PondScene(size: size)
        scene.interactive = interactive
        scene.scaleMode = .resizeFill
        v.presentScene(scene)
        views.append(v)
        return v
    }

    private func makeWallpaperWindow(on screen: NSScreen) {
        let frame = screen.frame
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.canHide = false
        w.title = "池塘金鱼壁纸"
        w.contentView = makeView(size: frame.size, interactive: false)
        observe(w)
        w.orderFront(nil)
        windows.append(w)
    }

    private func makeNormalWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "池塘金鱼"
        w.minSize = NSSize(width: 480, height: 320)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("PondGoldfishWindow")
        let size = w.contentView?.bounds.size ?? rect.size
        w.contentView = makeView(size: size, interactive: true)
        observe(w)
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        NSApp.activate()
    }

    private func observe(_ w: NSWindow) {
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: w)
    }

    private func tearDown() {
        for w in windows {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: w)
            w.delegate = nil
            w.orderOut(nil)
        }
        for v in views {
            v.isPaused = true
            v.presentScene(nil)
        }
        for w in windows {
            w.contentView = nil
            w.close()
        }
        views.removeAll()
        windows.removeAll()
    }

    // MARK: - Pausing (global pause, lock screen, fully hidden windows)

    @objc private func occlusionChanged(_ note: Notification) {
        refreshPauseState()
    }

    private func refreshPauseState() {
        for (i, v) in views.enumerated() {
            // Occlusion is only trusted for the normal window. Desktop-level windows sit under
            // Finder's (transparent) desktop-icon window, and we never want a false "hidden"
            // to freeze the wallpaper.
            var visible = true
            if !isWallpaper, i < windows.count {
                visible = windows[i].occlusionState.contains(.visible)
            }
            v.isPaused = globalPaused || !visible
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the pond window just hides it; the app lives in the menu bar.
        sender.orderOut(nil)
        return false
    }
}
