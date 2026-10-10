import AppKit
import Foundation

/// App version info. The single source of truth is `CFBundleShortVersionString`
/// written by build_app.sh; `swift run` has no bundle, so fall back to a constant.
enum AppInfo {
    static let fallbackVersion = "0.0.3"

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
///
/// Primary source is the REST API (gives release notes + asset list). The API is
/// rate-limited to 60 unauthenticated requests/hour per IP, which shared / proxy IPs
/// hit easily (HTTP 403/429), so on any API failure we fall back to the plain web
/// page `github.com/<repo>/releases/latest`, which redirects to `/releases/tag/<tag>`.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let repo = "yinerx/lotuspond-goldfish-mac"
    private let apiURL = URL(string: "https://api.github.com/repos/\(UpdateChecker.repo)/releases/latest")!
    private let webLatestURL = URL(string: "https://github.com/\(UpdateChecker.repo)/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/\(UpdateChecker.repo)/releases")!
    private let ud = UserDefaults.standard
    private enum K {
        static let lastCheck = "pond.update.lastCheck"
        static let skipped = "pond.update.skippedVersion"
    }
    private var isChecking = false

    private var userAgent: String { "LotusPondGoldfish/\(AppInfo.version) (macOS)" }

    /// What we need to show the update alert, from either source.
    private struct ReleaseInfo {
        let tag: String
        let notes: String?          // nil = not available (web fallback)
        let pageURL: URL
        let dmgURL: URL?
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private enum CheckError: LocalizedError {
        case rateLimited(reset: Date?)
        case http(Int)
        case badResponse
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .rateLimited(let reset):
                if let reset {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "zh_CN")
                    f.dateFormat = Calendar.current.isDateInToday(reset) ? "HH:mm" : "M月d日 HH:mm"
                    return "GitHub 暂时限制了访问次数，请稍后再试（大约 \(f.string(from: reset)) 后恢复）。"
                }
                return "GitHub 暂时限制了访问次数，请稍后再试。"
            case .http(let code): return "GitHub 返回了错误（HTTP \(code)）。"
            case .badResponse: return "GitHub 返回的数据无法识别。"
            case .network(let e): return "无法连接到 GitHub，请检查网络后再试。\n（\(e.localizedDescription)）"
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

        let release: ReleaseInfo?
        do {
            release = try await fetchLatest()
            ud.set(Date(), forKey: K.lastCheck)
        } catch {
            if manual { showError(error) }
            return
        }

        let current = SemVer(AppInfo.version)
        guard let release else {
            if manual { showUpToDate(current) }
            return
        }
        let latest = SemVer(release.tag)
        guard current < latest else {
            if manual { showUpToDate(current) }
            return
        }
        // A quiet check respects “跳过这个版本”; a manual check always shows it.
        if !manual, ud.string(forKey: K.skipped) == latest.description { return }
        showUpdate(release, latest: latest, current: current)
    }

    /// API first, web page as fallback. Returns nil when there is no published release.
    /// If both fail, the API error is reported (it is the more informative one,
    /// e.g. rate limit + reset time) unless it was a plain network error.
    private func fetchLatest() async throws -> ReleaseInfo? {
        let apiError: CheckError
        do {
            return try await fetchFromAPI()
        } catch let e as CheckError {
            apiError = e
        } catch {
            apiError = .network(error)
        }
        do {
            return try await fetchFromWeb()
        } catch {
            if case .network = apiError, let webErr = error as? CheckError { throw webErr }
            throw apiError
        }
    }

    private func request(_ url: URL, method: String = "GET", api: Bool = false) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if api {
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return req
    }

    private func load(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CheckError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw CheckError.badResponse }
        return (data, http)
    }

    private func fetchFromAPI() async throws -> ReleaseInfo? {
        let (data, http) = try await load(request(apiURL, api: true))
        if http.statusCode == 404 { return nil }
        if http.statusCode == 403 || http.statusCode == 429 {
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            let bodyText = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            if remaining == "0" || retryAfter != nil || http.statusCode == 429 || bodyText.contains("rate limit") {
                var reset: Date?
                if let r = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) {
                    reset = Date(timeIntervalSince1970: r)
                } else if let retryAfter {
                    reset = Date().addingTimeInterval(retryAfter)
                }
                throw CheckError.rateLimited(reset: reset)
            }
        }
        guard (200..<300).contains(http.statusCode) else { throw CheckError.http(http.statusCode) }
        guard let r = try? JSONDecoder().decode(APIRelease.self, from: data) else { throw CheckError.badResponse }
        if r.draft == true || r.prerelease == true { return nil }
        let dmg = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return ReleaseInfo(tag: r.tag_name,
                           notes: r.body ?? "",
                           pageURL: URL(string: r.html_url) ?? releasesPage,
                           dmgURL: dmg.flatMap { URL(string: $0.browser_download_url) })
    }

    /// `github.com/<repo>/releases/latest` 302 → `/releases/tag/<tag>` (URLSession follows it).
    /// With no releases it ends on `/releases`, which we treat as up to date.
    private func fetchFromWeb() async throws -> ReleaseInfo? {
        let (_, http) = try await load(request(webLatestURL, method: "HEAD"))
        if http.statusCode == 404 { return nil }
        guard (200..<400).contains(http.statusCode) else { throw CheckError.http(http.statusCode) }
        let finalURL = http.url ?? webLatestURL
        let comps = finalURL.pathComponents          // ["/", owner, repo, "releases", "tag", "<tag>"]
        guard let i = comps.firstIndex(of: "tag"), i + 1 < comps.count,
              i >= 1, comps[i - 1] == "releases" else {
            if comps.last == "releases" { return nil }
            throw CheckError.badResponse
        }
        let tag = comps[i + 1]
        let version = SemVer(tag).raw
        let enc = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let page = URL(string: "https://github.com/\(Self.repo)/releases/tag/\(enc)") ?? releasesPage
        // Same naming as .github/workflows/release.yml.
        let dmg = URL(string: "https://github.com/\(Self.repo)/releases/download/\(enc)/LotusPondGoldfish-\(version).dmg")
        return ReleaseInfo(tag: tag, notes: nil, pageURL: page, dmgURL: dmg)
    }

    // MARK: - Alerts

    private func showUpdate(_ release: ReleaseInfo, latest: SemVer, current: SemVer) {
        var notes: String
        if let body = release.notes {
            notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = 600
            if notes.count > limit { notes = String(notes.prefix(limit)) + "…" }
            if notes.isEmpty { notes = "（没有更新说明）" }
        } else {
            notes = "（暂时无法获取更新说明，请在发布页查看：\(release.pageURL.absoluteString)）"
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 \(latest)"
        alert.informativeText = "当前版本：\(current)\n\n更新内容：\n\(notes)"
        alert.addButton(withTitle: "下载新版本")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过这个版本")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = (error as? CheckError)?.errorDescription
            ?? "无法连接到 GitHub，请检查网络后再试。\n（\(error.localizedDescription)）"
        alert.informativeText += "\n\n也可以直接打开发布页查看最新版本。"
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
