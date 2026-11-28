import AppKit

// MARK: - Data

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    var resetDate: Date? {
        guard let s = resets_at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// A weekly limit that applies to a single model (e.g. Fable), from the `limits` list.
struct ScopedLimit {
    let name: String
    let window: UsageWindow
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    /// Model-specific weekly limits, as on claude.ai/settings/usage.
    let weeklyScoped: [ScopedLimit]

    private enum CodingKeys: String, CodingKey { case five_hour, seven_day, limits }

    private struct Limit: Decodable {
        struct Named: Decodable { let display_name: String? }
        struct Scope: Decodable { let model: Named? }
        let kind: String?
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }

    /// Decodes each element on its own, so one unexpected entry doesn't hide the rest.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = try? c.decodeIfPresent(UsageWindow.self, forKey: .five_hour)
        seven_day = try? c.decodeIfPresent(UsageWindow.self, forKey: .seven_day)
        let limits = (try? c.decodeIfPresent([Lossy<Limit>].self, forKey: .limits)) ?? nil
        weeklyScoped = (limits ?? []).compactMap(\.value).compactMap { l in
            guard l.kind == "weekly_scoped",
                  let name = l.scope?.model?.display_name, !name.isEmpty else { return nil }
            return ScopedLimit(name: name, window: UsageWindow(utilization: l.percent, resets_at: l.resets_at))
        }
    }
}

enum FetchError: Error {
    case noCredentials
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
}

/// Reads the OAuth credentials that Claude Code stores in the login keychain.
/// Uses /usr/bin/security so the keychain item's existing access rules apply
/// (no new "allow access" prompt each time the app is rebuilt).
func readCredentials() throws -> [String: Any] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw FetchError.noCredentials }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let oauth = json["claudeAiOauth"] as? [String: Any]
    else { throw FetchError.noCredentials }
    return oauth
}

func readAccessToken() throws -> String {
    try readToken().value
}

/// The access token and, if Claude Code stored it, when it expires.
func readToken() throws -> (value: String, expiresAt: Date?) {
    let creds = try readCredentials()
    guard let token = creds["accessToken"] as? String else { throw FetchError.noCredentials }
    // expiresAt is milliseconds since 1970.
    let expires = (creds["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    return (token, expires)
}

/// Human-readable plan, e.g. "Team · Max 5x", from the keychain credentials.
func readPlanDescription() -> String? {
    guard let creds = try? readCredentials(),
          let type = creds["subscriptionType"] as? String, !type.isEmpty
    else { return nil }
    let names = ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]
    var plan = names[type.lowercased()] ?? type.capitalized
    // rateLimitTier looks like "default_claude_max_5x"; show the multiplier if present.
    if let tier = creds["rateLimitTier"] as? String,
       let m = tier.range(of: #"\d+x$"#, options: .regularExpression) {
        let mult = String(tier[m])
        plan += plan == "Max" ? " \(mult)" : " · Max \(mult)"
    }
    return plan
}

/// Fetches the organisation name from the profile endpoint.
func fetchOrganizationName() async throws -> String? {
    let token = try readAccessToken()
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("ai-monitor-for-claude/0.9", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw FetchError.http(code) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let org = json?["organization"] as? [String: Any]
    return org?["name"] as? String
}

/// Returns the raw JSON so the caller can cache it between launches.
func fetchUsage(token: String) async throws -> Data {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("ai-monitor-for-claude/0.9", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 { throw FetchError.unauthorized }
    if code == 429 {
        let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        throw FetchError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
    }
    guard code == 200 else { throw FetchError.http(code) }
    return data
}

// MARK: - Processes

enum ProcessKind {
    case desktop   // Claude desktop app and its helpers
    case code      // Claude Code CLI sessions
    case vscode    // Visual Studio Code and its helpers
    case monitor   // this app
}

/// Memory and CPU time of Claude processes and of other relevant processes.
func claudeProcessUsage() -> ProcessUsage<ProcessKind> {
    processUsage { p in
        // Claude Code's binary is named after its version (…/claude/versions/2.1.x),
        // but the process name is "claude" since it is started via a symlink.
        if p.name == "claude" || p.path.contains("/claude/versions/") { return .code }
        if p.path.contains("/Claude.app/") { return .desktop }
        if p.path.contains("/Visual Studio Code.app/") { return .vscode }
        if p.isSelf { return .monitor }
        return nil
    }
}

/// A running Claude Code session and the project folder it was started in.
struct CodeSession {
    let folder: String
    let started: Date?
    let bytes: UInt64?
}

/// Running Claude Code sessions, oldest first. Helper processes that are not a
/// session, such as the Chrome extension's native host, are left out.
func claudeCodeSessions() -> [CodeSession] {
    runningProcesses()
        .filter { $0.name == "claude" || $0.path.contains("/claude/versions/") }
        .filter { !$0.arguments().contains("--chrome-native-host") }
        .compactMap { p in
            guard let folder = p.workingDirectory() else { return nil }
            return CodeSession(folder: folder, started: p.startTime(), bytes: p.memoryFootprint())
        }
        .sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
}

struct GitCommit {
    let subject: String
    let date: Date
}

/// The git to run, or nil if none is installed. /usr/bin/git is only a stub that
/// asks to install the developer tools when they are missing, so it is used only
/// when `xcode-select` points at an installed toolchain.
let gitPath: String? = {
    let fm = FileManager.default
    for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
        return path
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    p.arguments = ["-p"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let dir = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.terminationStatus == 0, fm.isExecutableFile(atPath: dir + "/usr/bin/git") else { return nil }
    return "/usr/bin/git"
}()

/// True if `folder` is inside a git repository (a `.git` in it or a parent folder).
func isInGitRepository(_ folder: String) -> Bool {
    var url = URL(fileURLWithPath: folder)
    while true {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { return false }
        url = parent
    }
}

/// The latest commit on the current branch of the repository `folder` is in.
func lastCommit(in folder: String) -> GitCommit? {
    guard let git = gitPath, isInGitRepository(folder) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: git)
    p.arguments = ["-C", folder, "log", "-1", "--format=%ct%x00%s"]
    // Only reading, so don't take the index lock a running git might need.
    p.environment = ["GIT_OPTIONAL_LOCKS": "0", "HOME": NSHomeDirectory()]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let parts = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\0", maxSplits: 1)
    guard parts.count == 2, let time = TimeInterval(parts[0]) else { return nil }
    return GitCommit(subject: String(parts[1]), date: Date(timeIntervalSince1970: time))
}

/// "aimonitor" for ~/Code/aimonitor, and "~" for the home folder itself.
func projectName(_ folder: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if folder == home { return "~" }
    return (folder as NSString).lastPathComponent
}

/// How long ago `start` was, e.g. "2 t 5 min" / "2 hr, 5 min".
func runningTime(since start: Date) -> String {
    let f = DateComponentsFormatter()
    var cal = Calendar.current
    cal.locale = appLocale
    f.calendar = cal
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    f.allowedUnits = [.day, .hour, .minute]
    return f.string(from: max(Date().timeIntervalSince(start), 60)) ?? ""
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sessionLabel = tr("Gjeldende økt", "Current session")
    private let weeklyLabel = tr("Ukegrense (alle modeller)", "Weekly limit (all models)")
    private let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sessionResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weeklyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let weeklyResetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Two items (usage and reset time) per model-specific weekly limit, below the weekly limit.
    private var scopedItems: [NSMenuItem] = []
    private let planItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let orgItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let orgKey = "organizationName"
    private let orgTimeKey = "organizationTime"
    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let memoryDesktopItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let memoryCodeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sessionsHeaderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// One item per running Claude Code session, below `sessionsHeaderItem`.
    private var sessionItems: [NSMenuItem] = []
    private let otherHeaderItem = NSMenuItem(title: tr("Andre relevante prosesser", "Other relevant processes"), action: nil, keyEquivalent: "")
    private let otherVSCodeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherMonitorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraph = CPUGraphView(width: 300)
    private var cpuHistory = CPUHistory<ProcessKind>(groups: [.desktop, .code, .vscode])
    private var cpuTimer: Timer?
    private var isMenuOpen = false
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateChecker = UpdateChecker(appName: "AI Monitor for Claude", tagPrefix: "v")
    private let loginItem = NSMenuItem(title: tr("Start ved innlogging", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")

    private var last: UsageResponse?
    private var lastUpdated: Date?
    private var timer: Timer?
    private var isFetching = false

    // Rate limiting. The usage endpoint's limit is unknown and shared with Claude Code,
    // so requests are never sent more often than `minInterval`. Each 429 doubles the
    // interval (up to `maxInterval`); after `successesBeforeDecrease` successful
    // requests in a row it is halved again, but never below `minInterval`.
    // Both the interval and the time of the next allowed request survive restarts.
    private let minInterval: TimeInterval = 600
    private let maxInterval: TimeInterval = 3600
    private let successesBeforeDecrease = 6
    private var interval: TimeInterval = 600
    /// After launch and wake, Claude Code and the network are starting up too, so the
    /// first request waits this long instead of competing with them.
    private let startupDelay: TimeInterval = 90
    /// A 429 only marks the figures as stale (⚠︎) once they are older than this.
    private let staleAfter: TimeInterval = 3600
    private var successStreak = 0
    /// No request is sent before this time.
    private var nextAllowedAt = Date.distantPast
    private let intervalKey = "refreshInterval"
    private let nextAllowedKey = "nextRequestTime"
    private let cacheKey = "lastUsageJSON"
    private let cacheTimeKey = "lastUsageTime"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = appIconMenuBarImage(description: tr("Claude-bruk", "Claude usage"))
            button.imagePosition = .imageLeading
            button.title = " …"
        }

        for item in [planItem, orgItem, sessionItem, sessionResetItem, weeklyItem, weeklyResetItem,
                     memoryItem, memoryDesktopItem, memoryCodeItem, sessionsHeaderItem,
                     otherHeaderItem, otherVSCodeItem, otherMonitorItem, cpuItem, statusLine, nextItem] {
            item.isEnabled = false
        }
        let header = headerMenuItem(appName: "AI Monitor for Claude")
        menu.addItem(header)
        menu.addItem(updateChecker.menuItem)
        menu.addItem(planItem)
        menu.addItem(orgItem)
        updatePlan()
        refreshOrganization()
        menu.addItem(.separator())
        menu.addItem(sessionItem)
        menu.addItem(sessionResetItem)
        menu.addItem(.separator())
        menu.addItem(weeklyItem)
        menu.addItem(weeklyResetItem)
        menu.addItem(.separator())
        menu.addItem(memoryItem)
        menu.addItem(memoryDesktopItem)
        menu.addItem(memoryCodeItem)
        menu.addItem(.separator())
        menu.addItem(sessionsHeaderItem)
        updateSessions()
        menu.addItem(.separator())
        menu.addItem(otherHeaderItem)
        menu.addItem(otherVSCodeItem)
        menu.addItem(otherMonitorItem)
        menu.addItem(.separator())
        menu.addItem(cpuItem)
        cpuGraphItem.view = cpuGraph
        cpuGraphItem.isEnabled = false
        menu.addItem(cpuGraphItem)
        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(nextItem)
        menu.addItem(NSMenuItem(title: tr("Oppdater nå", "Refresh now"), action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: tr("Åpne claude.ai/settings/usage", "Open claude.ai/settings/usage"), action: #selector(openUsagePage), keyEquivalent: ""))
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Avslutt", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu

        // Show the last known values right away. refresh() skips the request if the
        // previous one was less than `interval` ago.
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheKey),
           let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            last = usage
            lastUpdated = defaults.object(forKey: cacheTimeKey) as? Date
            render(error: nil)
        }
        let saved = defaults.double(forKey: intervalKey)
        interval = min(max(saved, minInterval), maxInterval)
        nextAllowedAt = defaults.object(forKey: nextAllowedKey) as? Date ?? .distantPast
        postponeForStartup()
        refresh()
        startCPUSampling()
        updateChecker.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func applyColors() { applyMenuColors(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        loginItem.state = launchAtLoginState
        updateStatusLine(error: nil)
        updateMemory()
        updateSessions()
        updatePlan()
        refreshOrganization()
        applyColors()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    @objc private func refreshNow() { refresh() }

    private func updatePlan() {
        planItem.title = tr("Lisens: ", "License: ") + (readPlanDescription() ?? tr("ukjent", "unknown"))
        let org = UserDefaults.standard.string(forKey: orgKey)
        orgItem.title = tr("Organisasjon: ", "Organization: ") + (org ?? "–")
        orgItem.isHidden = org == nil
    }

    /// The organisation name rarely changes, so it is cached and fetched at most once a day.
    private func refreshOrganization() {
        let defaults = UserDefaults.standard
        if let t = defaults.object(forKey: orgTimeKey) as? Date,
           Date().timeIntervalSince(t) < 24 * 3600 { return }
        Task {
            guard let name = try? await fetchOrganizationName() else { return }
            defaults.set(name, forKey: self.orgKey)
            defaults.set(Date(), forKey: self.orgTimeKey)
            self.updatePlan()
            self.applyColors()
        }
    }

    /// Samples CPU usage continuously, so the graph has history when the menu opens.
    /// The timer also runs while the menu is open, which keeps the graph live.
    private func startCPUSampling() {
        sampleCPU()
        let timer = Timer(timeInterval: CPUSampling.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCPU() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    private func sampleCPU() {
        cpuHistory.add(claudeProcessUsage())
        let h = cpuHistory
        cpuGraph.series = [
            .init(name: tr("Claude-appen", "Claude app"), values: h[.desktop], color: .systemOrange),
            .init(name: "Claude Code", values: h[.code], color: .systemPurple),
            .init(name: "VS Code", values: h[.vscode], color: .systemBlue),
        ]
        let total = (h[.desktop].last ?? 0) + (h[.code].last ?? 0)
        cpuItem.title = tr("CPU-bruk Claude: ", "Claude CPU usage: ") + "\(Int(total.rounded()))%"
            + tr(" (siste 5 min)", " (last 5 min)")
        if isMenuOpen { applyColors() }
    }

    private func updateMemory() {
        let usage = claudeProcessUsage()
        let (desktop, code) = (usage[.desktop], usage[.code])
        let f = ByteCountFormatter()
        f.countStyle = .memory
        func procs(_ n: Int) -> String {
            n == 1 ? tr("1 prosess", "1 process") : tr("\(n) prosesser", "\(n) processes")
        }
        memoryItem.title = tr("Minnebruk Claude: ", "Claude memory usage: ") + f.string(fromByteCount: Int64(desktop.bytes + code.bytes))
        memoryDesktopItem.title = "   " + tr("Claude-appen", "Claude app") + " (\(procs(desktop.count))): " + f.string(fromByteCount: Int64(desktop.bytes))
        memoryCodeItem.title = "   Claude Code (\(procs(code.count))): " + f.string(fromByteCount: Int64(code.bytes))
        let vscode = usage[.vscode]
        otherVSCodeItem.title = "   Visual Studio Code" + (vscode.count == 0
            ? ": " + tr("kjører ikke", "not running")
            : " (\(procs(vscode.count))): " + f.string(fromByteCount: Int64(vscode.bytes)))
        otherMonitorItem.title = "   AI Monitor for Claude: " + f.string(fromByteCount: Int64(usage[.monitor].bytes))
    }

    /// Lists each running Claude Code session with its project folder, running time and memory.
    private func updateSessions() {
        let sessions = claudeCodeSessions()
        sessionsHeaderItem.title = tr("Claude Code-økter", "Claude Code sessions") + ": \(sessions.count)"
        for item in sessionItems { menu.removeItem(item) }
        sessionItems = []
        let f = ByteCountFormatter()
        f.countStyle = .memory
        let relative = RelativeDateTimeFormatter()
        relative.locale = appLocale
        // One git call per folder, even if several sessions run in the same project.
        var commits: [String: GitCommit?] = [:]
        for s in sessions where !commits.keys.contains(s.folder) {
            commits.updateValue(lastCommit(in: s.folder), forKey: s.folder)
        }
        var index = menu.index(of: sessionsHeaderItem) + 1
        for s in sessions {
            var parts = [projectName(s.folder)]
            if let started = s.started { parts.append(runningTime(since: started)) }
            if let bytes = s.bytes { parts.append(f.string(fromByteCount: Int64(bytes))) }
            var titles = ["   " + parts.joined(separator: " · ")]
            if let commit = commits[s.folder] ?? nil {
                var subject = commit.subject
                if subject.count > 60 { subject = subject.prefix(59) + "…" }
                titles.append("      " + subject + " · " + relative.localizedString(for: commit.date, relativeTo: Date()))
            }
            for title in titles {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.insertItem(item, at: index)
                index += 1
                sessionItems.append(item)
            }
        }
    }

    @objc private func didWake() {
        postponeForStartup()
        refresh()
    }

    /// Makes sure no request is sent until `startupDelay` has passed.
    private func postponeForStartup() {
        let earliest = Date().addingTimeInterval(startupDelay)
        if nextAllowedAt < earliest { setNextAllowed(earliest) }
    }

    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 30), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleLogin() {
        toggleLaunchAtLogin()
        loginItem.state = launchAtLoginState
    }

    /// Fetches usage unless the previous request was too recent; in that case it
    /// just makes sure a request is scheduled for when it is allowed.
    private func refresh() {
        if isFetching { return }
        let now = Date()

        // Reading the keychain is local and free, so it is done before the rate limit
        // check. A missing or rejected token is checked again every `tokenCheckInterval`,
        // and a new token (Claude Code renewed it, e.g. after an update) is tried at once.
        let token: String
        do {
            let t = try readToken()
            token = t.value
            if let exp = t.expiresAt, exp <= now {
                rejectedToken = token
            }
        } catch {
            lastError = FetchError.noCredentials
            render(error: lastError)
            scheduleNext(after: tokenCheckInterval)
            return
        }
        if token == rejectedToken {
            lastError = FetchError.unauthorized
            render(error: lastError)
            scheduleNext(after: tokenCheckInterval)
            return
        }
        let isNewToken = rejectedToken != nil || lastErrorIsCredentials
        rejectedToken = nil

        if now < nextAllowedAt && !isNewToken {
            scheduleNext(after: nextAllowedAt.timeIntervalSince(now))
            updateStatusLine(error: nil)
            return
        }
        isFetching = true
        // Reserve the slot before sending, so nothing else can fire meanwhile.
        setNextAllowed(now.addingTimeInterval(interval))
        Task {
            defer { self.isFetching = false }
            do {
                let data = try await fetchUsage(token: token)
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                self.last = usage
                self.lastUpdated = Date()
                self.lastError = nil
                UserDefaults.standard.set(data, forKey: self.cacheKey)
                UserDefaults.standard.set(self.lastUpdated, forKey: self.cacheTimeKey)
                self.successStreak += 1
                if self.successStreak >= self.successesBeforeDecrease && self.interval > self.minInterval {
                    self.setInterval(self.interval / 2)
                    self.successStreak = 0
                }
                self.render(error: nil)
            } catch FetchError.rateLimited(let retryAfter) {
                // 10 → 20 → 40 → 60 min, or longer if the server asks for it.
                self.successStreak = 0
                self.setInterval(self.interval * 2)
                self.setNextAllowed(now.addingTimeInterval(max(self.interval, retryAfter ?? 0)))
                self.lastError = FetchError.rateLimited(retryAfter: retryAfter)
                self.render(error: self.lastError)
            } catch FetchError.unauthorized {
                // Wait for Claude Code to store a new token instead of the full interval.
                self.rejectedToken = token
                self.lastError = FetchError.unauthorized
                self.render(error: self.lastError)
                self.scheduleNext(after: self.tokenCheckInterval)
                return
            } catch {
                self.lastError = error
                self.render(error: error)
            }
            self.scheduleNext(after: self.nextAllowedAt.timeIntervalSinceNow)
        }
    }

    private func setInterval(_ value: TimeInterval) {
        interval = min(max(value, minInterval), maxInterval)
        UserDefaults.standard.set(interval, forKey: intervalKey)
    }

    private func setNextAllowed(_ date: Date) {
        nextAllowedAt = date
        UserDefaults.standard.set(date, forKey: nextAllowedKey)
    }

    private func render(error: Error?) {
        let session = last?.five_hour?.utilization
        let weekly = last?.seven_day?.utilization

        if let button = statusItem.button {
            if last == nil {
                button.title = error == nil ? " …" : " " + tr("vent litt", "waiting")
                button.attributedTitle = NSAttributedString(string: button.title)
            } else {
                button.attributedTitle = titleString(session: session, weekly: weekly, stale: isStale(error))
            }
            button.toolTip = "\(sessionLabel) · \(weeklyLabel)"
        }

        sessionItem.title = "\(sessionLabel): \(pct(session))"
        sessionResetItem.title = resetText(last?.five_hour?.resetDate)
        weeklyItem.title = "\(weeklyLabel): \(pct(weekly))"
        weeklyResetItem.title = resetText(last?.seven_day?.resetDate)
        renderScopedLimits()
        updateStatusLine(error: error)
    }

    /// Shows each model-specific weekly limit (e.g. Fable) right after the weekly limit.
    private func renderScopedLimits() {
        for item in scopedItems { menu.removeItem(item) }
        scopedItems = []
        var index = menu.index(of: weeklyResetItem) + 1
        for limit in last?.weeklyScoped ?? [] {
            let usage = NSMenuItem(title: tr("Ukegrense (\(limit.name))", "Weekly limit (\(limit.name))")
                                   + ": \(pct(limit.window.utilization))", action: nil, keyEquivalent: "")
            let reset = NSMenuItem(title: resetText(limit.window.resetDate), action: nil, keyEquivalent: "")
            for item in [usage, reset] {
                item.isEnabled = false
                menu.insertItem(item, at: index)
                index += 1
                scopedItems.append(item)
            }
        }
    }

    private var lastError: Error?
    /// The token the API rejected (or that had expired). It is not sent again; the
    /// keychain is checked every `tokenCheckInterval` until Claude Code stores a new one.
    private var rejectedToken: String?
    private let tokenCheckInterval: TimeInterval = 30

    private var lastErrorIsCredentials: Bool {
        if case FetchError.noCredentials? = lastError as? FetchError { return true }
        return false
    }

    /// A 429 alone is not worth a warning while the cached figures are recent;
    /// the menu still says it is rate limited. Other errors always show ⚠︎.
    private func isStale(_ error: Error?) -> Bool {
        guard let error else { return false }
        if case FetchError.rateLimited = error, let t = lastUpdated,
           Date().timeIntervalSince(t) < staleAfter { return false }
        return true
    }

    private func updateStatusLine(error: Error?) {
        if let err = lastError {
            switch err {
            case FetchError.noCredentials:
                statusLine.title = tr("Fant ikke Claude Code-innlogging (kjør `claude` og logg inn)",
                                      "Claude Code login not found (run `claude` and log in)")
            case FetchError.unauthorized:
                statusLine.title = tr("Token utløpt – åpne Claude Code for å fornye (oppdateres automatisk)",
                                      "Token expired – open Claude Code to renew it (updates automatically)")
            case FetchError.rateLimited:
                let at = clockTime(nextAllowedAt)
                statusLine.title = tr("For mange forespørsler (HTTP 429) – prøver igjen kl. \(at)",
                                      "Too many requests (HTTP 429) – retrying at \(at)")
            case FetchError.http(let c):
                statusLine.title = tr("Feil fra API (HTTP \(c))", "API error (HTTP \(c))")
            default:
                statusLine.title = tr("Nettverksfeil: ", "Network error: ") + err.localizedDescription
            }
        } else if let t = lastUpdated {
            let f = RelativeDateTimeFormatter()
            f.locale = appLocale
            statusLine.title = tr("Oppdatert ", "Updated ") + f.localizedString(for: t, relativeTo: Date())
        } else {
            statusLine.title = tr("Henter…", "Loading…")
        }
        let minutes = Int(interval / 60)
        let at = clockTime(max(nextAllowedAt, Date()))
        nextItem.title = tr("Neste oppdatering kl. \(at) · hvert \(minutes). min",
                            "Next update at \(at) · every \(minutes) min")
        applyColors()
    }

    private func titleString(session: Double?, weekly: Double?, stale: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let s = NSMutableAttributedString(string: " ")
        func part(_ v: Double?) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let c = usageColor(v) { attrs[.foregroundColor] = c }
            return NSAttributedString(string: pct(v), attributes: attrs)
        }
        s.append(part(session))
        s.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(part(weekly))
        if stale {
            s.append(NSAttributedString(string: " ⚠︎", attributes: [.font: font]))
        }
        return s
    }

    private func resetText(_ d: Date?) -> String {
        guard let d else { return tr("   Nullstilles: ukjent", "   Resets: unknown") }
        let f = DateFormatter()
        f.locale = appLocale
        let cal = Calendar.current
        f.dateFormat = cal.isDateInToday(d) ? tr("'i dag kl.' HH:mm", "'today at' HH:mm")
            : cal.isDateInTomorrow(d) ? tr("'i morgen kl.' HH:mm", "'tomorrow at' HH:mm")
            : tr("EEEE d. MMM 'kl.' HH:mm", "EEEE d MMM 'at' HH:mm")
        return tr("   Nullstilles ", "   Resets ") + f.string(from: d)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
