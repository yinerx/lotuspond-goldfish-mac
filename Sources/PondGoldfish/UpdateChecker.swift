import AppKit
import Foundation

/// App version info. The single source of truth is `CFBundleShortVersionString`
/// written by build_app.sh; `swift run` has no bundle, so fall back to a constant.
enum AppInfo {
    static let fallbackVersion = "0.0.2"

    static var version: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v
        }
        return fallbackVersion
    }
}

/// Semantic-ish version: numeric dot components, optional leading v/V,
/// pre-release / build suffixes ("-beta", "+build") ignored for ordering.
struct SemVer: Comparable, CustomStringConvertible {
    let parts: [Int]
    let raw: String

    init(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        raw = s
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        parts = core.split(separator: ".").map { comp in
            Int(comp.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    var description: String { raw }

    static func < (a: SemVer, b: SemVer) -> Bool {
        let n = max(a.parts.count, b.parts.count, 3)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

/// 检查更新：GitHub Releases `latest` → compare with the running version → NSAlert.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/yinerx/lotuspond-goldfish-mac/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/yinerx/lotuspond-goldfish-mac/releases")!
    private let ud = UserDefaults.standard
    private enum K {
        static let lastCheck = "pond.update.lastCheck"
        static let skipped = "pond.update.skippedVersion"
    }
    private var isChecking = false

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private enum CheckError: LocalizedError {
        case http(Int)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(let code): return "服务器返回了错误（HTTP \(code)）。"
            case .badResponse: return "服务器返回的数据无法识别。"
            }
        }
    }

    /// Quiet check at launch: at most once per day, only if enabled, no alert unless newer.
    func checkAtLaunchIfNeeded() {
        guard PondSettings.shared.autoCheckUpdates else { return }
        if let last = ud.object(forKey: K.lastCheck) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        Task { await check(manual: false) }
    }

    /// 菜单「检查更新…」
    func checkManually() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let release: Release?
        do {
            release = try await fetchLatest()
            ud.set(Date(), forKey: K.lastCheck)
        } catch {
            if manual { showError(error) }
            return
        }

        let current = SemVer(AppInfo.version)
        guard let release, release.draft != true, release.prerelease != true else {
            if manual { showUpToDate(current) }
            return
        }
        let latest = SemVer(release.tag_name)
        guard current < latest else {
            if manual { showUpToDate(current) }
            return
        }
        // A quiet check respects “跳过这个版本”; a manual check always shows it.
        if !manual, ud.string(forKey: K.skipped) == latest.description { return }
        showUpdate(release, latest: latest, current: current)
    }

    /// Returns nil when the repo has no published release (404).
    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("PondGoldfish/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CheckError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw CheckError.badResponse
        }
    }

    // MARK: - Alerts

    private func showUpdate(_ release: Release, latest: SemVer, current: SemVer) {
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        if notes.count > limit { notes = String(notes.prefix(limit)) + "…" }
        if notes.isEmpty { notes = "（没有更新说明）" }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(latest)"
        alert.informativeText = "当前版本：\(current)\n\n更新内容：\n\(notes)"
        alert.addButton(withTitle: "下载新版本")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过这个版本")

        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            let target = dmg.flatMap { URL(string: $0.browser_download_url) }
                ?? URL(string: release.html_url)
                ?? releasesPage
            NSWorkspace.shared.open(target)
        case .alertThirdButtonReturn:
            ud.set(latest.description, forKey: K.skipped)
        default:
            break
        }
    }

    private func showUpToDate(_ current: SemVer) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已经是最新版本（\(current)）"
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = "无法连接到 GitHub，请检查网络后再试。\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }
}
