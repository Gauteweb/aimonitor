import AppKit

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
}

/// "1.0.2" → [1, 0, 2], so versions compare numerically ("1.10" > "1.9").
private func versionParts(_ s: String) -> [Int] {
    s.split(separator: ".").map { Int($0) ?? 0 }
}

private func isNewer(_ a: String, than b: String) -> Bool {
    let (x, y) = (versionParts(a), versionParts(b))
    for i in 0..<max(x.count, y.count) {
        let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
        if p != q { return p > q }
    }
    return false
}

/// Checks GitHub once a day for a newer release of this app. When one is found,
/// `menuItem` is shown with a link to the release, and an alert is shown once
/// per new version.
///
/// Both apps are released from the same repository, so releases are told apart
/// by their tag prefix: `v1.1` for AI Monitor for Claude and `mistral-vibe-v1.0`
/// for AI Monitor for Mistral Vibe.
@MainActor
final class UpdateChecker: NSObject {
    let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let appName: String
    private let tagPrefix: String
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var releaseURL: URL?
    private var timer: Timer?
    private let alertShownKey = "updateAlertShownVersion"

    init(appName: String, tagPrefix: String) {
        self.appName = appName
        self.tagPrefix = tagPrefix
        super.init()
        menuItem.isHidden = true
        menuItem.target = self
        menuItem.action = #selector(openRelease)
    }

    func start() {
        check()
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        Task {
            guard let (version, url) = try? await fetchLatest(),
                  isNewer(version, than: currentVersion)
            else { return }
            releaseURL = url
            menuItem.title = tr("Ny versjon tilgjengelig: \(version) – åpne GitHub",
                                "New version available: \(version) – open GitHub")
            menuItem.isHidden = false
            if let menu = menuItem.menu { applyMenuColors(menu) }

            let defaults = UserDefaults.standard
            if defaults.string(forKey: alertShownKey) != version {
                defaults.set(version, forKey: alertShownKey)
                showAlert(version: version)
            }
        }
    }

    /// The newest release whose tag starts with `tagPrefix`. Lists all releases
    /// instead of using /releases/latest, since only one app can be "latest".
    private func fetchLatest() async throws -> (String, URL)? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/Gauteweb/aimonitor/releases?per_page=100")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("aimonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases
            .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(tagPrefix) }
            .compactMap { r -> (String, URL)? in
                let version = String(r.tag_name.dropFirst(tagPrefix.count))
                guard version.first?.isNumber == true, let url = URL(string: r.html_url) else { return nil }
                return (version, url)
            }
            .max { isNewer($1.0, than: $0.0) }
    }

    private func showAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = tr("Ny versjon av \(appName)", "New version of \(appName)")
        alert.informativeText = tr(
            "Versjon \(version) er tilgjengelig på GitHub. Du har versjon \(currentVersion).",
            "Version \(version) is available on GitHub. You have version \(currentVersion).")
        alert.addButton(withTitle: tr("Åpne GitHub", "Open GitHub"))
        alert.addButton(withTitle: tr("Senere", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openRelease() }
    }

    @objc private func openRelease() {
        guard let releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }
}
