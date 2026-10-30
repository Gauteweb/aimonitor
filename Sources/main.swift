import AppKit
import ServiceManagement

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

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
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
    guard let token = try readCredentials()["accessToken"] as? String else { throw FetchError.noCredentials }
    return token
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
func fetchUsage() async throws -> Data {
    let token = try readAccessToken()
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

// MARK: - Language

/// Norwegian if the user's preferred macOS language is Norwegian, else English.
let isNorwegian: Bool = {
    let lang = Locale.preferredLanguages.first?.lowercased() ?? ""
    return ["nb", "no", "nn"].contains { lang.hasPrefix($0) }
}()

let appLocale = Locale(identifier: isNorwegian ? "nb_NO" : "en_US")

func tr(_ no: String, _ en: String) -> String { isNorwegian ? no : en }

// MARK: - Icon

/// Draws a Claude-style spark (uneven rays radiating from the centre) as a
/// template image, so it follows the menu bar's light/dark appearance.
func claudeSparkImage() -> NSImage {
    let size: CGFloat = 18
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let c = NSPoint(x: rect.midX, y: rect.midY)
        // Relative ray lengths, going round the circle; uneven like the logo.
        let lengths: [CGFloat] = [1.0, 0.82, 0.95, 0.78, 1.0, 0.86, 0.92, 0.8, 1.0, 0.84, 0.94, 0.79]
        let maxLen = size / 2 - 1
        let inner: CGFloat = 1.6
        NSColor.black.setStroke()
        for (i, l) in lengths.enumerated() {
            let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi + .pi / 2
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            path.line(to: NSPoint(x: c.x + cos(a) * maxLen * l, y: c.y + sin(a) * maxLen * l))
            path.stroke()
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = tr("Claude-bruk", "Claude usage")
    return img
}

// MARK: - Memory

struct MemoryGroup {
    var count = 0
    var bytes: UInt64 = 0
}

/// Sums the memory footprint (same figure as Activity Monitor's "Memory" column)
/// of the Claude desktop app with its helpers, and of Claude Code CLI processes.
func claudeMemoryUsage() -> (desktop: MemoryGroup, code: MemoryGroup) {
    var desktop = MemoryGroup(), code = MemoryGroup()
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var pathBuf = [CChar](repeating: 0, count: 4096)

    for pid in pids.prefix(max(n, 0)) where pid > 0 {
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
        let path = String(cString: pathBuf)
        // Claude Code's binary is named after its version (…/claude/versions/2.1.x),
        // but the process name is "claude" since it is started via a symlink.
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let isDesktop = path.contains("/Claude.app/")
        let isCode = String(cString: nameBuf) == "claude" || path.contains("/claude/versions/")
        guard isDesktop || isCode else { continue }

        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { continue }
        if isDesktop {
            desktop.count += 1
            desktop.bytes += info.ri_phys_footprint
        } else {
            code.count += 1
            code.bytes += info.ri_phys_footprint
        }
    }
    return (desktop, code)
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
    private let planItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let orgItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let orgKey = "organizationName"
    private let orgTimeKey = "organizationTime"
    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let memoryDesktopItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let memoryCodeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: tr("Start ved innlogging", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")

    private var last: UsageResponse?
    private var lastUpdated: Date?
    private var timer: Timer?
    private var isFetching = false
    /// No requests are sent before this time (set after a 429).
    private var blockedUntil: Date?
    private var backoff: TimeInterval = 0
    private let refreshInterval: TimeInterval = 300
    private let maxBackoff: TimeInterval = 3600
    private let cacheKey = "lastUsageJSON"
    private let cacheTimeKey = "lastUsageTime"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = claudeSparkImage()
            button.imagePosition = .imageLeading
            button.title = " …"
        }

        for item in [planItem, orgItem, sessionItem, sessionResetItem, weeklyItem, weeklyResetItem,
                     memoryItem, memoryDesktopItem, memoryCodeItem, statusLine] {
            item.isEnabled = false
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let headerText = NSMutableAttributedString(
            string: "AI Monitor for Claude",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                         .foregroundColor: NSColor.labelColor])
        headerText.append(NSAttributedString(
            string: "  v. \(version)",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor]))
        header.attributedTitle = headerText
        header.isEnabled = false
        header.tag = headerTag
        menu.addItem(header)
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
        menu.addItem(statusLine)
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

        // Show the last known values right away, and skip the first request if they are recent.
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheKey),
           let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            last = usage
            lastUpdated = defaults.object(forKey: cacheTimeKey) as? Date
            render(error: nil)
        }
        if let t = lastUpdated, Date().timeIntervalSince(t) < refreshInterval {
            scheduleNext(after: refreshInterval - Date().timeIntervalSince(t))
        } else {
            refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private let headerTag = 1

    private let infoInset: CGFloat = 20
    private let infoHeight: CGFloat = 22

    /// Swaps the usual menu colours: information lines (disabled items) are shown
    /// in the normal text colour, and clickable actions in grey.
    /// AppKit always greys out a disabled item's title, so information lines are
    /// drawn as custom label views instead.
    /// Called after every text change, since setting `title` doesn't update the view.
    private func applyColors() {
        let font = NSFont.menuFont(ofSize: 0)
        for item in menu.items where !item.isSeparatorItem {
            if item.isEnabled {
                item.attributedTitle = NSAttributedString(
                    string: item.title, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            } else if item.tag == headerTag, let header = item.attributedTitle {
                setInfoView(item, header)
            } else {
                setInfoView(item, NSAttributedString(
                    string: item.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
        }
    }

    private func setInfoView(_ item: NSMenuItem, _ text: NSAttributedString) {
        let label: NSTextField
        if let existing = item.view?.subviews.first as? NSTextField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            item.view = NSView()
            item.view?.addSubview(label)
        }
        label.attributedStringValue = text
        label.sizeToFit()
        label.frame.origin = NSPoint(x: infoInset, y: (infoHeight - label.frame.height) / 2)
        item.view?.frame = NSRect(x: 0, y: 0, width: label.frame.width + infoInset * 2, height: infoHeight)
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateStatusLine(error: nil)
        updateMemory()
        updatePlan()
        refreshOrganization()
        applyColors()
        // Refresh in the background only if the data is clearly old.
        if let t = lastUpdated, Date().timeIntervalSince(t) < 120 { return }
        refresh()
    }

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

    private func updateMemory() {
        let (desktop, code) = claudeMemoryUsage()
        let f = ByteCountFormatter()
        f.countStyle = .memory
        func procs(_ n: Int) -> String {
            n == 1 ? tr("1 prosess", "1 process") : tr("\(n) prosesser", "\(n) processes")
        }
        memoryItem.title = tr("Minnebruk Claude: ", "Claude memory usage: ") + f.string(fromByteCount: Int64(desktop.bytes + code.bytes))
        memoryDesktopItem.title = "   " + tr("Claude-appen", "Claude app") + " (\(procs(desktop.count))): " + f.string(fromByteCount: Int64(desktop.bytes))
        memoryCodeItem.title = "   Claude Code (\(procs(code.count))): " + f.string(fromByteCount: Int64(code.bytes))
    }

    @objc private func didWake() {
        if let t = lastUpdated, Date().timeIntervalSince(t) < refreshInterval { return }
        refresh()
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
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Kunne ikke endre innloggingsobjekt", "Could not change login item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func refresh() {
        if isFetching { return }
        if let until = blockedUntil, Date() < until {
            updateStatusLine(error: nil)
            return
        }
        isFetching = true
        Task {
            defer { self.isFetching = false }
            do {
                let data = try await fetchUsage()
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                self.last = usage
                self.lastUpdated = Date()
                self.lastError = nil
                self.blockedUntil = nil
                self.backoff = 0
                UserDefaults.standard.set(data, forKey: self.cacheKey)
                UserDefaults.standard.set(self.lastUpdated, forKey: self.cacheTimeKey)
                self.render(error: nil)
                self.scheduleNext(after: self.refreshInterval)
            } catch FetchError.rateLimited(let retryAfter) {
                // Back off: 5, 10, 20, 40, 60 min, or longer if the server asks for it.
                self.backoff = min(max(self.backoff * 2, self.refreshInterval), self.maxBackoff)
                let wait = max(self.backoff, retryAfter ?? 0)
                self.blockedUntil = Date().addingTimeInterval(wait)
                self.lastError = FetchError.rateLimited(retryAfter: retryAfter)
                self.render(error: self.lastError)
                self.scheduleNext(after: wait)
            } catch {
                self.lastError = error
                self.render(error: error)
                self.scheduleNext(after: self.refreshInterval)
            }
        }
    }

    private func render(error: Error?) {
        let session = last?.five_hour?.utilization
        let weekly = last?.seven_day?.utilization

        if let button = statusItem.button {
            if last == nil {
                button.title = error == nil ? " …" : " " + tr("vent litt", "waiting")
                button.attributedTitle = NSAttributedString(string: button.title)
            } else {
                button.attributedTitle = titleString(session: session, weekly: weekly, stale: error != nil)
            }
            button.toolTip = "\(sessionLabel) · \(weeklyLabel)"
        }

        sessionItem.title = "\(sessionLabel): \(pct(session))"
        sessionResetItem.title = resetText(last?.five_hour?.resetDate)
        weeklyItem.title = "\(weeklyLabel): \(pct(weekly))"
        weeklyResetItem.title = resetText(last?.seven_day?.resetDate)
        updateStatusLine(error: error)
    }

    private var lastError: Error?

    private func updateStatusLine(error: Error?) {
        if let err = lastError {
            switch err {
            case FetchError.noCredentials:
                statusLine.title = tr("Fant ikke Claude Code-innlogging (kjør `claude` og logg inn)",
                                      "Claude Code login not found (run `claude` and log in)")
            case FetchError.unauthorized:
                statusLine.title = tr("Token utløpt – åpne Claude Code for å fornye",
                                      "Token expired – open Claude Code to renew it")
            case FetchError.rateLimited:
                let f = DateFormatter()
                f.locale = appLocale
                f.dateFormat = "HH:mm"
                let at = blockedUntil.map { f.string(from: $0) } ?? "–"
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
        applyColors()
    }

    private func titleString(session: Double?, weekly: Double?, stale: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let s = NSMutableAttributedString(string: " ")
        func part(_ v: Double?) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let c = color(for: v) { attrs[.foregroundColor] = c }
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

    private func color(for v: Double?) -> NSColor? {
        guard let v = v?.rounded() else { return nil }
        if v >= 75 { return .systemRed }
        if v >= 50 { return .systemYellow }
        return nil
    }

    private func pct(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
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
