import AppKit
import IOKit.ps

/// Menu-bar app: status item (SF Symbol `fish.fill`), mode switching, settings,
/// pause/resume, and power awareness (lock screen, sleep, battery).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let pond = PondWindowManager()
    private let settingsWindow = SettingsWindowController()
    private let settings = PondSettings.shared

    private var userPaused = false
    private var screenLocked = false
    private var screensAsleep = false
    private var onBattery = false
    private var lastWallpaperMode = false
    private var timer: Timer?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        setupStatusItem()
        settingsWindow.onToggleMode = { [weak self] in self?.toggleMode() }

        lastWallpaperMode = settings.wallpaperMode
        pond.apply(wallpaper: settings.wallpaperMode)
        applyActivationPolicy()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenDidLock(_:)), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenDidUnlock(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        timer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(periodic(_:)), userInfo: nil, repeats: true)
        periodic(nil)

        // First launch: show the settings once so the user discovers the panel.
        if !UserDefaults.standard.bool(forKey: "pond.didLaunchBefore") {
            UserDefaults.standard.set(true, forKey: "pond.didLaunchBefore")
            settingsWindow.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !settings.wallpaperMode { pond.showWindow() } else { settingsWindow.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "池塘金鱼")
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let modeItem = appMenu.addItem(withTitle: "切换模式", action: #selector(toggleModeAction(_:)), keyEquivalent: "m")
        modeItem.keyEquivalentModifierMask = [.command, .shift]
        modeItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出池塘金鱼", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "池塘金鱼") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "🐟"
        }
        item.button?.toolTip = "池塘金鱼"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuildStatusMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = settings.wallpaperMode ? "桌面壁纸" : "窗口"
        let target = settings.wallpaperMode ? "窗口模式" : "桌面壁纸模式"

        let header = NSMenuItem(title: "池塘金鱼 · 当前：\(current)模式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(menu, "切换模式（→ \(target)）", #selector(toggleModeAction(_:)))
        if !settings.wallpaperMode {
            add(menu, "显示池塘窗口", #selector(showPondWindow(_:)))
        }
        add(menu, "设置…", #selector(openSettings(_:)), key: ",")
        add(menu, userPaused ? "继续动画" : "暂停动画", #selector(togglePause(_:)))
        menu.addItem(.separator())
        add(menu, "落下一片叶子", #selector(dropLeaf(_:)))
        add(menu, "落下一片花瓣", #selector(dropPetal(_:)))
        let rain = add(menu, "下雨", #selector(toggleRain(_:)))
        rain.state = settings.rainEnabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "退出", #selector(quit(_:)), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func toggleModeAction(_ sender: Any?) { toggleMode() }

    func toggleMode() {
        settings.wallpaperMode.toggle()
        lastWallpaperMode = settings.wallpaperMode
        pond.apply(wallpaper: settings.wallpaperMode)
        applyActivationPolicy()
        applyRendering()
    }

    @objc private func showPondWindow(_ sender: Any?) { pond.showWindow() }
    @objc private func openSettings(_ sender: Any?) { settingsWindow.show() }

    @objc private func togglePause(_ sender: Any?) {
        userPaused.toggle()
        applyRendering()
    }

    @objc private func dropLeaf(_ sender: Any?) { pond.scenes.randomElement()?.dropLeaf() }
    @objc private func dropPetal(_ sender: Any?) { pond.scenes.randomElement()?.dropPetal() }
    @objc private func toggleRain(_ sender: Any?) { settings.rainEnabled.toggle() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func applyActivationPolicy() {
        // Wallpaper mode: menu-bar only (no Dock icon). Window mode: a regular app.
        _ = NSApp.setActivationPolicy(settings.wallpaperMode ? .accessory : .regular)
        if !settings.wallpaperMode { NSApp.activate() }
    }

    // MARK: - Power / lock awareness

    @objc private func screenDidLock(_ n: Notification) { screenLocked = true; applyRendering() }
    @objc private func screenDidUnlock(_ n: Notification) { screenLocked = false; applyRendering() }
    @objc private func screensDidSleep(_ n: Notification) { screensAsleep = true; applyRendering() }
    @objc private func screensDidWake(_ n: Notification) { screensAsleep = false; applyRendering() }

    @objc private func screenParametersChanged(_ n: Notification) {
        if settings.wallpaperMode { pond.apply(wallpaper: true); applyRendering() }
    }

    @objc private func periodic(_ t: Timer?) {
        onBattery = Self.isOnBatteryPower()
        // The settings panel can also switch modes; pick that up here.
        if settings.wallpaperMode != lastWallpaperMode {
            lastWallpaperMode = settings.wallpaperMode
            pond.apply(wallpaper: settings.wallpaperMode)
            applyActivationPolicy()
        }
        applyRendering()
    }

    private func applyRendering() {
        var fps = settings.fps
        if settings.reduceOnBattery && (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled) {
            fps = min(fps, 30)
        }
        pond.setFPS(fps)
        pond.setPaused(userPaused || screenLocked || screensAsleep)
    }

    static func isOnBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"   // kIOPSBatteryPowerValue
    }
}
