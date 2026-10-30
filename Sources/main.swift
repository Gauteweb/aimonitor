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

/// A monochrome version of the app icon (the letters "AI" with a graph and a
/// light, no background) as a template image, so it follows the menu bar's
/// light/dark appearance.
func appIconMenuBarImage() -> NSImage {
    // Drawn in the 512 px app icon's coordinates (y down), then scaled to fit.
    let height: CGFloat = 18
    let box = NSRect(x: 50, y: 52, width: 414, height: 344)
    let s = height / box.height
    let size = NSSize(width: (box.width * s).rounded(), height: height)
    let img = NSImage(size: size, flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setFillColor(NSColor.black.cgColor)

        func stroke(_ pts: [CGPoint], width: CGFloat, clear: Bool = false) {
            ctx.setBlendMode(clear ? .clear : .normal)
            ctx.setLineWidth(width / s)
            ctx.addLines(between: pts)
            ctx.strokePath()
        }
        let letter: CGFloat = 1.8, line: CGFloat = 1.2, gap: CGFloat = 0.8

        // "A" and "I"
        stroke([CGPoint(x: 128, y: 345), CGPoint(x: 200, y: 108), CGPoint(x: 270, y: 345)], width: letter)
        stroke([CGPoint(x: 160, y: 262), CGPoint(x: 240, y: 262)], width: letter)
        stroke([CGPoint(x: 312, y: 108), CGPoint(x: 352, y: 108), CGPoint(x: 352, y: 345)], width: letter)
        stroke([CGPoint(x: 312, y: 345), CGPoint(x: 392, y: 345)], width: letter)

        // The graph, cut out of the letters with a small gap so it stays readable.
        let graph = [(64, 383), (145, 383), (145, 288), (225, 288), (225, 350), (305, 350),
                     (305, 192), (383, 192), (383, 240), (452, 240)].map { CGPoint(x: $0.0, y: $0.1) }
        stroke(graph, width: line + 2 * gap, clear: true)
        stroke(graph, width: line)

        // The light: a dot with a faint halo, separated from the "I" by a gap.
        let c = CGPoint(x: 400, y: 103)
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: circle(50))
        ctx.setBlendMode(.normal)
        ctx.setAlpha(0.35)
        ctx.fillEllipse(in: circle(46))
        ctx.setAlpha(1)
        ctx.fillEllipse(in: circle(28))
        ctx.endTransparencyLayer()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = tr("Claude-bruk", "Claude usage")
    return img
}

// MARK: - Processes

struct ProcessGroup {
    var count = 0
    var bytes: UInt64 = 0
    /// Total CPU time (user + system) so far, in nanoseconds, per process.
    var cpuTimes: [pid_t: UInt64] = [:]
}

struct ProcessUsage {
    var desktop = ProcessGroup()   // Claude desktop app and its helpers
    var code = ProcessGroup()      // Claude Code CLI sessions
    var vscode = ProcessGroup()    // Visual Studio Code and its helpers
    var monitor = ProcessGroup()   // this app
}

/// `proc_pid_rusage` reports CPU time in Mach time units, which are only
/// nanoseconds on Intel Macs.
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// Sums the memory footprint (same figure as Activity Monitor's "Memory" column)
/// of Claude processes and of other relevant processes, and collects their CPU time.
func processUsage() -> ProcessUsage {
    var usage = ProcessUsage()
    let ownPid = getpid()
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
        let group: WritableKeyPath<ProcessUsage, ProcessGroup>
        if String(cString: nameBuf) == "claude" || path.contains("/claude/versions/") {
            group = \.code
        } else if path.contains("/Claude.app/") {
            group = \.desktop
        } else if path.contains("/Visual Studio Code.app/") {
            group = \.vscode
        } else if pid == ownPid {
            group = \.monitor
        } else {
            continue
        }

        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { continue }
        usage[keyPath: group].count += 1
        usage[keyPath: group].bytes += info.ri_phys_footprint
        let ticks = info.ri_user_time + info.ri_system_time
        usage[keyPath: group].cpuTimes[pid] = ticks * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
    }
    return usage
}

// MARK: - CPU graph

/// CPU usage over time per process group, in percent of one core (as in Activity Monitor).
struct CPUHistory {
    static let sampleInterval: TimeInterval = 2
    static let capacity = 150   // 5 minutes

    var desktop: [Double] = []
    var code: [Double] = []
    var vscode: [Double] = []
    private var previous: ProcessUsage?
    private var previousTime: UInt64 = 0

    /// Adds a sample computed from the CPU time used since the previous one.
    /// Processes that started in between count from zero; ones that exited are left out.
    mutating func add(_ usage: ProcessUsage) {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previous = usage; previousTime = now }
        guard let previous, now > previousTime else { return }
        let elapsed = Double(now - previousTime)
        func percent(_ group: KeyPath<ProcessUsage, ProcessGroup>) -> Double {
            let before = previous[keyPath: group].cpuTimes
            let used = usage[keyPath: group].cpuTimes.reduce(0.0) { sum, entry in
                let start = before[entry.key] ?? 0
                return sum + (entry.value > start ? Double(entry.value - start) : 0)
            }
            return used / elapsed * 100
        }
        func append(_ value: Double, to series: inout [Double]) {
            series.append(value)
            if series.count > Self.capacity { series.removeFirst(series.count - Self.capacity) }
        }
        append(percent(\.desktop), to: &desktop)
        append(percent(\.code), to: &code)
        append(percent(\.vscode), to: &vscode)
    }
}

/// Line graph of `CPUHistory`, shown as a menu item view, with a legend below.
/// `width` is the minimum; the view stretches to the width of the menu.
final class CPUGraphView: NSView {
    var history = CPUHistory() { didSet { needsDisplay = true } }

    private let inset: CGFloat = 20
    private let plotHeight: CGFloat = 64
    private let legendHeight: CGFloat = 22

    override var isFlipped: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 4 + plotHeight + legendHeight + 2))
        // Menus widen item views with a flexible width to the menu's width.
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    private var series: [(name: String, values: [Double], color: NSColor)] {
        [(tr("Claude-appen", "Claude app"), history.desktop, .systemOrange),
         ("Claude Code", history.code, .systemPurple),
         ("VS Code", history.vscode, .systemBlue)]
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: inset, y: 4, width: bounds.width - 2 * inset, height: plotHeight)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)

        // Scale to the highest value shown, rounded up to a readable step.
        let peak = series.flatMap(\.values).max() ?? 0
        let top = [5.0, 10, 25, 50, 100, 200, 400, 800, 1600].first { $0 >= peak } ?? peak

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: plot.minX, y: plot.midY))
        grid.line(to: NSPoint(x: plot.maxX, y: plot.midY))
        grid.lineWidth = 0.5
        grid.setLineDash([2, 2], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        grid.stroke()
        NSAttributedString(string: "\(Int(top))%", attributes: [
            .font: smallFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: plot.minX + 4, y: plot.minY + 2))

        // Newest sample at the right edge.
        let step = plot.width / CGFloat(CPUHistory.capacity - 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).addClip()
        for s in series where s.values.count > 1 {
            let path = NSBezierPath()
            for (i, v) in s.values.enumerated() {
                let x = plot.maxX - CGFloat(s.values.count - 1 - i) * step
                let y = plot.maxY - 1 - CGFloat(v / top) * (plot.height - 2)
                i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            s.color.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Legend with the latest value of each series.
        var x = plot.minX
        let y = plot.maxY + 5
        for s in series {
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 4, width: 7, height: 7)).fill()
            x += 11
            let latest = s.values.last.map { "\(Int($0.rounded()))%" } ?? "–"
            let text = NSAttributedString(string: "\(s.name) \(latest)", attributes: [
                .font: smallFont, .foregroundColor: NSColor.labelColor,
            ])
            text.draw(at: NSPoint(x: x, y: y))
            x += text.size().width + 14
        }
    }
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
    private let otherHeaderItem = NSMenuItem(title: tr("Andre relevante prosesser", "Other relevant processes"), action: nil, keyEquivalent: "")
    private let otherVSCodeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherMonitorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraph = CPUGraphView(width: 300)
    private var cpuTimer: Timer?
    private var isMenuOpen = false
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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
    private let minInterval: TimeInterval = 300
    private let maxInterval: TimeInterval = 3600
    private let successesBeforeDecrease = 6
    private var interval: TimeInterval = 300
    private var successStreak = 0
    /// No request is sent before this time.
    private var nextAllowedAt = Date.distantPast
    private let intervalKey = "refreshInterval"
    private let nextAllowedKey = "nextRequestTime"
    private let cacheKey = "lastUsageJSON"
    private let cacheTimeKey = "lastUsageTime"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = appIconMenuBarImage()
            button.imagePosition = .imageLeading
            button.title = " …"
        }

        for item in [planItem, orgItem, sessionItem, sessionResetItem, weeklyItem, weeklyResetItem,
                     memoryItem, memoryDesktopItem, memoryCodeItem,
                     otherHeaderItem, otherVSCodeItem, otherMonitorItem, cpuItem, statusLine, nextItem] {
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
        refresh()
        startCPUSampling()
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
        for item in menu.items where !item.isSeparatorItem && item !== cpuGraphItem {
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
        isMenuOpen = true
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateStatusLine(error: nil)
        updateMemory()
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
        let timer = Timer(timeInterval: CPUHistory.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCPU() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    private func sampleCPU() {
        cpuGraph.history.add(processUsage())
        let h = cpuGraph.history
        let total = (h.desktop.last ?? 0) + (h.code.last ?? 0)
        cpuItem.title = tr("CPU-bruk Claude: ", "Claude CPU usage: ") + "\(Int(total.rounded()))%"
            + tr(" (siste 5 min)", " (last 5 min)")
        if isMenuOpen { applyColors() }
    }

    private func updateMemory() {
        let usage = processUsage()
        let (desktop, code) = (usage.desktop, usage.code)
        let f = ByteCountFormatter()
        f.countStyle = .memory
        func procs(_ n: Int) -> String {
            n == 1 ? tr("1 prosess", "1 process") : tr("\(n) prosesser", "\(n) processes")
        }
        memoryItem.title = tr("Minnebruk Claude: ", "Claude memory usage: ") + f.string(fromByteCount: Int64(desktop.bytes + code.bytes))
        memoryDesktopItem.title = "   " + tr("Claude-appen", "Claude app") + " (\(procs(desktop.count))): " + f.string(fromByteCount: Int64(desktop.bytes))
        memoryCodeItem.title = "   Claude Code (\(procs(code.count))): " + f.string(fromByteCount: Int64(code.bytes))
        let vscode = usage.vscode
        otherVSCodeItem.title = "   Visual Studio Code" + (vscode.count == 0
            ? ": " + tr("kjører ikke", "not running")
            : " (\(procs(vscode.count))): " + f.string(fromByteCount: Int64(vscode.bytes)))
        otherMonitorItem.title = "   AI Monitor for Claude: " + f.string(fromByteCount: Int64(usage.monitor.bytes))
    }

    @objc private func didWake() { refresh() }

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

    /// Fetches usage unless the previous request was too recent; in that case it
    /// just makes sure a request is scheduled for when it is allowed.
    private func refresh() {
        if isFetching { return }
        let now = Date()
        if now < nextAllowedAt {
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
                let data = try await fetchUsage()
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
                // 5 → 10 → 20 → 40 → 60 min, or longer if the server asks for it.
                self.successStreak = 0
                self.setInterval(self.interval * 2)
                self.setNextAllowed(now.addingTimeInterval(max(self.interval, retryAfter ?? 0)))
                self.lastError = FetchError.rateLimited(retryAfter: retryAfter)
                self.render(error: self.lastError)
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

    private func clockTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "HH:mm"
        return f.string(from: date)
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
