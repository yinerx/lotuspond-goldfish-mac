import SwiftUI
import AppKit

/// 设置面板 — dark, semi-transparent rounded panel with Chinese labels.
struct SettingsView: View {
    @ObservedObject var s: PondSettings
    var onToggleMode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "fish.fill")
                    .foregroundStyle(Color.orange)
                Text("池塘金鱼 · 设置")
                    .font(.headline)
                Spacer()
            }
            .padding(.top, 30)

            group("水") {
                ColorPicker("水色", selection: colorBinding($s.waterHex), supportsOpacity: false)
                ColorPicker("深水色", selection: colorBinding($s.deepHex), supportsOpacity: false)
                sliderRow("水面高度", value: $s.waterHeight, range: 0...1, text: percent(s.waterHeight))
                sliderRow("水面透明度", value: $s.waterClarity, range: 0...1, text: percent(s.waterClarity))
            }

            group("光照") {
                Toggle("跟随现实时间", isOn: $s.followRealTime)
                    .toggleStyle(.switch)
                if s.followRealTime {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        let alt = SunModel.currentPosition(latitude: s.latitude).altitude
                        row("太阳高度角") {
                            Text(String(format: "%.0f°（按当前时间计算）", alt))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    sliderRow("太阳高度角", value: $s.sunAltitude, range: -20...90, text: String(format: "%.0f°", s.sunAltitude))
                }
                sliderRow("太阳光强度", value: $s.sunIntensity, range: 0...2, text: String(format: "%.2f", s.sunIntensity))
            }

            group("事件") {
                Toggle("开启花瓣", isOn: $s.petalsEnabled).toggleStyle(.switch)
                Toggle("开启落叶", isOn: $s.leavesEnabled).toggleStyle(.switch)
                Toggle("下雨", isOn: $s.rainEnabled).toggleStyle(.switch)
            }

            group("鱼") {
                sliderRow("鱼的数量", value: $s.fishCount, range: 5...30, step: 1, text: "\(s.fishTarget) 条")
            }

            group("性能") {
                row("帧率") {
                    Picker("", selection: $s.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Toggle("使用电池时降低帧率", isOn: $s.reduceOnBattery).toggleStyle(.switch)
            }

            group("更新") {
                Toggle("自动检查更新", isOn: $s.autoCheckUpdates).toggleStyle(.switch)
                HStack {
                    Text("当前版本 \(AppInfo.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("检查更新…") { UpdateChecker.shared.checkManually() }
                }
            }

            HStack {
                Button("恢复默认") { s.resetToDefaults() }
                Spacer()
                Button(s.wallpaperMode ? "切换到窗口模式" : "切换到桌面壁纸模式") { onToggleMode() }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil, text: String) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: RGB(hex: hex.wrappedValue).nsColor) },
            set: { newValue in hex.wrappedValue = RGB(nsColor: NSColor(newValue)).hex }
        )
    }
}

/// Borderless-looking titled window for the settings panel. The SwiftUI card fills
/// the whole window (including the transparent titlebar), so the traffic-light
/// buttons sit on top of the card's top-left corner.
final class SettingsPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Esc → close.
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Hosts the SwiftUI panel in a transparent, floating, draggable window.
/// Hidden by default; only shown from “设置…” (status item / app menu).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: SettingsPanelWindow?
    private var keyMonitor: Any?
    var onToggleMode: () -> Void = {}

    func show() {
        if window == nil {
            let view = SettingsView(s: PondSettings.shared, onToggleMode: { [weak self] in self?.onToggleMode() })
                .ignoresSafeArea()
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let w = SettingsPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.titled, .closable, .fullSizeContentView],
                                        backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.appearance = NSAppearance(named: .darkAqua)
            w.title = "池塘金鱼设置"
            w.contentView = host
            w.setContentSize(size)
            // Only close makes sense for this fixed-size panel.
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            if let screen = NSScreen.main {
                let vf = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 40, y: vf.maxY - size.height - 40))
            } else {
                w.center()
            }
            w.delegate = self
            window = w
        }
        installKeyMonitor()
        // LSUIElement / accessory app: cooperative NSApp.activate() may not make us
        // active, which leaves the panel non-key (greyed controls, dead traffic lights).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.performClose(nil)
    }

    /// ⌘W and Esc close the panel even when the app has no visible main menu
    /// (accessory mode) and regardless of which SwiftUI control has focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdW = mods == .command && event.charactersIgnoringModifiers?.lowercased() == "w"
            let isEsc = event.keyCode == 53 && mods.isDisjoint(with: [.command, .option, .control])
            guard isCmdW || isEsc else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard let w = self?.window, w.isKeyWindow else { return false }
                w.performClose(nil)
                return true
            }
            return handled ? nil : event
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
