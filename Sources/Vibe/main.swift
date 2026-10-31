import AppKit
import WebKit

// MARK: - Data

/// An allowance included in the plan, e.g. $10.07 used of $600.
struct Allowance: Codable {
    let used: Double
    let limit: Double

    var percent: Double? { limit > 0 ? used / limit * 100 : nil }
}

struct VibeUsage: Codable {
    let vibeCode: Allowance?
    let api: Allowance?
    let plan: String?
    let currency: String
}

enum FetchError: Error {
    case notLoggedIn
    /// The subscription page loaded, but the figures were not found on it.
    case notFound
}

/// Mistral has no API for the included allowances, so they are read from the
/// admin page that shows them, logged in with the app's own web view session.
let subscriptionURL = URL(string: "https://admin.mistral.ai/subscription")!

/// Reads the allowances from the rendered subscription page, as JSON:
/// `{"state": "ok", "vibe": ["$10.07", "$600"], "api": [...], "plan": "Team"}`,
/// `{"state": "login"}` when the page redirected elsewhere (to the login),
/// or `{"state": "waiting"}` while the figures are not on the page yet.
/// Each allowance is the smallest element that mentions it and holds two amounts:
/// the amount used, then the limit.
let extractScript = #"""
(() => {
  if (location.hostname !== 'admin.mistral.ai' || !location.pathname.startsWith('/subscription'))
    return JSON.stringify({state: 'login'});
  const main = document.querySelector('main');
  if (!main) return JSON.stringify({state: 'waiting'});
  const money = /[$€£]\s?\d[\d.,]*|\d[\d.,]*\s?[$€£]/g;
  const allowance = re => {
    let best = null;
    for (const el of main.querySelectorAll('*')) {
      const t = el.innerText || '';
      if (!re.test(t) || (t.match(money) || []).length < 2) continue;
      if (best === null || t.length < best.length) best = t;
    }
    return best === null ? null : best.match(money).slice(0, 2);
  };
  const vibe = allowance(/Vibe Code/), api = allowance(/\bAPI\b/);
  if (!vibe && !api) return JSON.stringify({state: 'waiting'});
  const plan = (main.innerText.match(/CURRENT PLAN\s*\n\s*(.+)/i) || [])[1] || null;
  return JSON.stringify({state: 'ok', vibe, api, plan});
})()
"""#

/// What is read from the admin pages in one go.
struct PageResult {
    let usage: VibeUsage
    let requests: [DailyRequests]?
}

enum PageState {
    case ok(VibeUsage)
    case login
    case waiting
}

func parsePageState(_ json: String?) -> PageState {
    guard let data = json?.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .waiting }
    switch obj["state"] as? String {
    case "login": return .login
    case "ok": break
    default: return .waiting
    }
    func allowance(_ key: String) -> Allowance? {
        guard let pair = obj[key] as? [String], pair.count == 2,
              let used = parseAmount(pair[0]), let limit = parseAmount(pair[1])
        else { return nil }
        return Allowance(used: used, limit: limit)
    }
    let vibe = allowance("vibe"), api = allowance("api")
    guard vibe != nil || api != nil else { return .waiting }
    let firstAmount = ((obj["vibe"] ?? obj["api"]) as? [String])?.first ?? ""
    let currency = firstAmount.first { "$€£".contains($0) }.map(String.init) ?? "$"
    return .ok(VibeUsage(vibeCode: vibe, api: api, plan: obj["plan"] as? String, currency: currency))
}

/// "$10.07" → 10.07, "$1,200" → 1200, "10,07 €" → 10.07.
func parseAmount(_ s: String) -> Double? {
    var digits = s.filter { "0123456789.,".contains($0) }
    if let comma = digits.lastIndex(of: ","), let dot = digits.lastIndex(of: ".") {
        // Whichever separator comes last is the decimal one.
        digits = comma > dot
            ? digits.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            : digits.replacingOccurrences(of: ",", with: "")
    } else if let comma = digits.lastIndex(of: ",") {
        // Three digits after the only kind of separator means thousands.
        let decimals = digits.distance(from: comma, to: digits.endIndex) - 1
        digits = decimals == 3
            ? digits.replacingOccurrences(of: ",", with: "")
            : digits.replacingOccurrences(of: ",", with: ".")
    }
    return Double(digits)
}

/// API requests on one day, per usage type ("vibe", "chat", …).
struct DailyRequests: Codable {
    let day: Date
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }
}

/// What the usage page's chart shows: API requests per usage type, from the
/// internal endpoint the page itself uses. Runs inside the logged-in page, so
/// the request carries the login cookies. Hourly buckets: `[time, type, calls]`.
let requestsScript = #"""
const input = {json: {start, end, chartMetric: 'apiCalls', granularity: 'day', splitByUsageType: true},
               meta: {values: {start: ['Date'], end: ['Date']}, v: 1}};
const r = await fetch('/api/local-trpc/usage.timeseries?input=' + encodeURIComponent(JSON.stringify(input)));
if (!r.ok) return null;
const j = await r.json();
return JSON.stringify(j.result.data.json.groups.map(g => [g.timeBucket, g.usageType, g.nbApiCalls]));
"""#

let requestDays = 30

/// API requests per day for the last `requestDays` days, oldest first,
/// or nil if they could not be read.
@MainActor
func readRequests(in webView: WKWebView) async -> [DailyRequests]? {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    guard let start = cal.date(byAdding: .day, value: -(requestDays - 1), to: today) else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let json = try? await webView.callAsyncJavaScript(
              requestsScript, arguments: ["start": iso.string(from: start), "end": iso.string(from: Date())],
              contentWorld: .page) as? String,
          let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Any]]
    else { return nil }

    var days = (0..<requestDays).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        .map { (day: $0, counts: [String: Int]()) }
    for row in rows where row.count == 3 {
        guard let bucket = (row[0] as? String).flatMap(iso.date(from:)),
              let type = row[1] as? String, let calls = row[2] as? Int,
              let i = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: bucket)).day,
              days.indices.contains(i)
        else { continue }
        days[i].counts[type, default: 0] += calls
    }
    return days.map { DailyRequests(day: $0.day, counts: $0.counts) }
}

/// The usage page's names and colours for the usage types.
func usageTypeInfo(_ type: String) -> (name: String, color: NSColor) {
    switch type {
    case "vibe": return ("Vibe Code", .systemOrange)
    case "chat": return ("Vibe Work", .systemPurple)
    case "connectors": return ("Connectors", .systemTeal)
    case "usage": return ("Completion", .systemBlue)
    case "libraries_tokens": return ("Libraries", .systemGreen)
    case "ocr": return ("OCR", .systemPink)
    default: return (type.replacingOccurrences(of: "_", with: " ").capitalized, .systemGray)
    }
}

/// Stacked bars of API requests per day and usage type, with a legend of the
/// totals below. `width` is the minimum; the view stretches to the width of the menu.
final class RequestsGraphView: NSView, MenuGraphView {
    var days: [DailyRequests] = [] {
        didSet {
            types = Dictionary(days.flatMap { $0.counts.map { ($0.key, $0.value) } }, uniquingKeysWith: +)
                .sorted { $0.value > $1.value }.map { (type: $0.key, total: $0.value) }
            needsDisplay = true
        }
    }
    /// Usage types with their totals, largest first.
    private var types: [(type: String, total: Int)] = []

    private let inset: CGFloat = 20
    private let plotHeight: CGFloat = 64
    private let legendLineHeight: CGFloat = 16

    override var isFlipped: Bool { true }

    init(width: CGFloat) {
        // Room for two lines of legend.
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 4 + plotHeight + 5 + 2 * legendLineHeight + 4))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: inset, y: 4, width: bounds.width - 2 * inset, height: plotHeight)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)

        let peak = days.map(\.total).max() ?? 0
        let top = [10.0, 20, 25, 50, 75, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000]
            .first { $0 >= Double(peak) } ?? Double(peak)

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()
        NSAttributedString(string: "\(Int(top))", attributes: [
            .font: smallFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: plot.minX + 4, y: plot.minY + 2))

        // One bar per day, oldest at the left, stacked with the largest type at the bottom.
        guard !days.isEmpty else { return }
        let slot = plot.width / CGFloat(days.count)
        let barWidth = max(slot - 2, 1)
        for (i, day) in days.enumerated() {
            var y = plot.maxY - 1
            for t in types {
                guard let n = day.counts[t.type], n > 0 else { continue }
                let h = CGFloat(Double(n) / top) * (plot.height - 2)
                usageTypeInfo(t.type).color.setFill()
                NSRect(x: plot.minX + CGFloat(i) * slot + (slot - barWidth) / 2, y: y - h, width: barWidth, height: h).fill()
                y -= h
            }
        }

        // Legend with each type's total, wrapped onto a second line when needed.
        var x = plot.minX
        var y = plot.maxY + 5
        for t in types {
            let info = usageTypeInfo(t.type)
            let text = NSAttributedString(string: "\(info.name) \(t.total)", attributes: [
                .font: smallFont, .foregroundColor: NSColor.labelColor,
            ])
            let width = 11 + text.size().width
            if x + width > plot.maxX && x > plot.minX {
                x = plot.minX
                y += legendLineHeight
            }
            info.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 4, width: 7, height: 7)).fill()
            text.draw(at: NSPoint(x: x + 11, y: y))
            x += width + 14
        }
    }
}

/// The plan Vibe saw when it last checked its login, e.g. "Team", from
/// ~/.vibe/whoami_cache.json. Used until the subscription page has been read.
func readVibePlan() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe/whoami_cache.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    // One entry per API key; use the most recent one.
    let entries = json.values.compactMap { $0 as? [String: Any] }
        .sorted { ($0["stored_at_timestamp"] as? Double ?? 0) > ($1["stored_at_timestamp"] as? Double ?? 0) }
    guard let payload = entries.first?["payload"] as? [String: Any],
          let name = payload["plan_name"] as? String, !name.isEmpty
    else { return nil }
    return name.capitalized
}

/// Web views share the app's persistent cookie store, so the login from
/// `LoginWindowController` is used by `SubscriptionPageReader`.
@MainActor
func makeWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    // Some sign-in pages turn away browsers they don't recognise.
    config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
    return WKWebView(frame: .zero, configuration: config)
}

/// Errors from a navigation that was replaced by another one, such as a redirect.
func isInterruption(_ error: Error) -> Bool {
    let e = error as NSError
    return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled)
        || (e.domain == "WebKitErrorDomain" && e.code == 102)
}

/// Loads the subscription page in a hidden web view and reads the figures from it,
/// then the API requests from the same page.
@MainActor
final class SubscriptionPageReader: NSObject, WKNavigationDelegate {
    private var finishedAt: Date?
    private var loadError: Error?

    func read(timeout: TimeInterval = 30) async throws -> PageResult {
        let webView = makeWebView()
        webView.navigationDelegate = self
        finishedAt = nil
        loadError = nil
        // A web view outside a window is suspended by WebKit, and the page never
        // renders its figures. An invisible window off-screen keeps it running.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            window.orderOut(nil)
            window.contentView = nil
        }
        webView.load(URLRequest(url: subscriptionURL))

        let start = Date()
        var state = PageState.waiting
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let loadError { throw loadError }
            guard let finishedAt else { continue }
            state = parsePageState(try? await webView.evaluateJavaScript(extractScript) as? String)
            switch state {
            case .ok(let usage): return PageResult(usage: usage, requests: await readRequests(in: webView))
            // Give client-side redirects a moment before concluding.
            case .login where Date().timeIntervalSince(finishedAt) > 3: throw FetchError.notLoggedIn
            default: continue
            }
        }
        if case .login = state { throw FetchError.notLoggedIn }
        throw FetchError.notFound
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedAt = Date()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !isInterruption(error) { loadError = error }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !isInterruption(error) { loadError = error }
    }
}

/// A window with the Mistral login. It closes by itself once the login has
/// led to the subscription page and its figures could be read.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    var onSuccess: ((PageResult) -> Void)?
    var onClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    func show() {
        if window == nil {
            let webView = makeWebView()
            webView.navigationDelegate = self
            webView.uiDelegate = self
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = tr("Logg inn på Mistral – AI Monitor for Mistral Vibe", "Log in to Mistral – AI Monitor for Mistral Vibe")
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            webView.load(URLRequest(url: subscriptionURL))
            self.window = window
            self.webView = webView
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            // The figures appear shortly after the page has loaded.
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.webView === webView else { return }
                switch parsePageState(try? await webView.evaluateJavaScript(extractScript) as? String) {
                case .ok(let usage):
                    onSuccess?(PageResult(usage: usage, requests: await readRequests(in: webView)))
                    window?.close()
                    return
                case .login: return
                case .waiting: continue
                }
            }
        }
    }

    /// Opens links meant for a new window (e.g. a sign-in popup) in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
        webView = nil
        window = nil
        onClose?()
    }
}

// MARK: - Processes

enum ProcessKind {
    case vibe      // Vibe CLI sessions
    case vscode    // Visual Studio Code and its helpers
    case monitor   // this app
}

/// Memory and CPU time of Vibe processes and of other relevant processes.
func vibeProcessUsage() -> ProcessUsage<ProcessKind> {
    processUsage { p in
        // Vibe runs as python3.13 but sets its process title to "Vibe CLI".
        // It also bundles a helper binary in …/vibe/_bin/.
        if p.path.contains("/vibe/_bin/") { return .vibe }
        if p.name.hasPrefix("python"), p.firstArgument() == "Vibe CLI" { return .vibe }
        if p.path.contains("/Visual Studio Code.app/") { return .vscode }
        if p.isSelf { return .monitor }
        return nil
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let vibeLabel = tr("Vibe Code (inkludert i planen)", "Vibe Code (included in plan)")
    private let apiLabel = tr("API (inkludert i planen)", "API (included in plan)")
    private let planItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let vibeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let vibeAmountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let apiItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let apiAmountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestsGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let requestsGraph = RequestsGraphView(width: 300)
    private let memoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherHeaderItem = NSMenuItem(title: tr("Andre relevante prosesser", "Other relevant processes"), action: nil, keyEquivalent: "")
    private let otherVSCodeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherMonitorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cpuGraph = CPUGraphView(width: 300)
    private var cpuHistory = CPUHistory<ProcessKind>(groups: [.vibe, .vscode])
    private var cpuTimer: Timer?
    private var isMenuOpen = false
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mistralLoginItem = NSMenuItem(title: tr("Logg inn på Mistral…", "Log in to Mistral…"), action: #selector(showLogin), keyEquivalent: "")
    private let mistralLogoutItem = NSMenuItem(title: tr("Logg ut av Mistral", "Log out of Mistral"), action: #selector(logOut), keyEquivalent: "")
    private let updateChecker = UpdateChecker(appName: "AI Monitor for Mistral Vibe", tagPrefix: "mistral-vibe-v")
    private let loginItem = NSMenuItem(title: tr("Start ved innlogging", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")

    private let reader = SubscriptionPageReader()
    private let loginWindow = LoginWindowController()
    private var last: VibeUsage?
    private var requests: [DailyRequests]?
    private var lastUpdated: Date?
    private var lastError: Error?
    private var timer: Timer?
    private var isFetching = false

    // Reading the page means loading a full web page, and the figures change
    // slowly, so it is done every `interval`. Opening the menu or waking the Mac
    // refreshes if the last attempt is older than that; "Refresh now" if it is
    // older than `manualInterval`.
    private let interval: TimeInterval = 600
    private let manualInterval: TimeInterval = 30
    private var lastAttempt = Date.distantPast
    private let cacheKey = "lastUsageJSON"
    private let cacheTimeKey = "lastUsageTime"
    private let requestsCacheKey = "lastRequestsJSON"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        if let button = statusItem.button {
            button.image = appIconMenuBarImage(description: tr("Vibe-bruk", "Vibe usage"))
            button.imagePosition = .imageLeading
            button.title = " …"
        }

        for item in [planItem, vibeItem, vibeAmountItem, apiItem, apiAmountItem, resetItem, requestsItem, memoryItem,
                     otherHeaderItem, otherVSCodeItem, otherMonitorItem, cpuItem, statusLine, nextItem] {
            item.isEnabled = false
        }
        menu.addItem(headerMenuItem(appName: "AI Monitor for Mistral Vibe"))
        menu.addItem(updateChecker.menuItem)
        menu.addItem(planItem)
        menu.addItem(.separator())
        menu.addItem(vibeItem)
        menu.addItem(vibeAmountItem)
        menu.addItem(.separator())
        menu.addItem(apiItem)
        menu.addItem(apiAmountItem)
        menu.addItem(.separator())
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(requestsItem)
        requestsGraphItem.view = requestsGraph
        requestsGraphItem.isEnabled = false
        menu.addItem(requestsGraphItem)
        menu.addItem(.separator())
        menu.addItem(memoryItem)
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
        menu.addItem(NSMenuItem(title: tr("Åpne admin.mistral.ai/subscription", "Open admin.mistral.ai/subscription"), action: #selector(openSubscriptionPage), keyEquivalent: ""))
        menu.addItem(mistralLoginItem)
        menu.addItem(mistralLogoutItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("Avslutt", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu

        loginWindow.onSuccess = { [weak self] result in self?.store(result) }
        loginWindow.onClose = { [weak self] in self?.refresh(manual: true) }

        // Show the last known values right away.
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheKey),
           let usage = try? JSONDecoder().decode(VibeUsage.self, from: data) {
            last = usage
            lastUpdated = defaults.object(forKey: cacheTimeKey) as? Date
        }
        if let data = defaults.data(forKey: requestsCacheKey) {
            requests = try? JSONDecoder().decode([DailyRequests].self, from: data)
        }
        render()
        refresh()
        startCPUSampling()
        updateChecker.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Without an Edit menu, ⌘C/⌘V/⌘A don't work in the login window, since this
    /// app has no menu bar of its own.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(NSMenuItem())   // the application menu
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func applyColors() { applyMenuColors(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        loginItem.state = launchAtLoginState
        updateMemory()
        render()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    @objc private func refreshNow() { refresh(manual: true) }

    @objc private func didWake() { refresh() }

    @objc private func openSubscriptionPage() {
        NSWorkspace.shared.open(subscriptionURL)
    }

    @objc private func showLogin() { loginWindow.show() }

    /// Removes the app's Mistral cookies and the saved figures.
    @objc private func logOut() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        last = nil
        requests = nil
        lastUpdated = nil
        lastError = FetchError.notLoggedIn
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: requestsCacheKey)
        UserDefaults.standard.removeObject(forKey: cacheTimeKey)
        render()
    }

    @objc private func toggleLogin() {
        toggleLaunchAtLogin()
        loginItem.state = launchAtLoginState
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
        cpuHistory.add(vibeProcessUsage())
        let h = cpuHistory
        cpuGraph.series = [
            .init(name: "Vibe CLI", values: h[.vibe], color: .systemOrange),
            .init(name: "VS Code", values: h[.vscode], color: .systemBlue),
        ]
        cpuItem.title = tr("CPU-bruk Vibe: ", "Vibe CPU usage: ") + "\(Int((h[.vibe].last ?? 0).rounded()))%"
            + tr(" (siste 5 min)", " (last 5 min)")
        if isMenuOpen { applyColors() }
    }

    private func updateMemory() {
        let usage = vibeProcessUsage()
        let f = ByteCountFormatter()
        f.countStyle = .memory
        func procs(_ n: Int) -> String {
            n == 1 ? tr("1 prosess", "1 process") : tr("\(n) prosesser", "\(n) processes")
        }
        let vibe = usage[.vibe]
        memoryItem.title = tr("Minnebruk Vibe CLI", "Vibe CLI memory usage") + (vibe.count == 0
            ? ": " + tr("kjører ikke", "not running")
            : " (\(procs(vibe.count))): " + f.string(fromByteCount: Int64(vibe.bytes)))
        let vscode = usage[.vscode]
        otherVSCodeItem.title = "   Visual Studio Code" + (vscode.count == 0
            ? ": " + tr("kjører ikke", "not running")
            : " (\(procs(vscode.count))): " + f.string(fromByteCount: Int64(vscode.bytes)))
        otherMonitorItem.title = "   AI Monitor for Mistral Vibe: " + f.string(fromByteCount: Int64(usage[.monitor].bytes))
    }

    private func scheduleNext() {
        timer?.invalidate()
        let delay = max(lastAttempt.addingTimeInterval(interval).timeIntervalSinceNow, 30)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Reads the subscription page, unless the last attempt was too recent or
    /// the login window is open (it reports the figures itself).
    private func refresh(manual: Bool = false) {
        if isFetching || loginWindow.isOpen { return }
        if Date().timeIntervalSince(lastAttempt) < (manual ? manualInterval : interval) {
            scheduleNext()
            return
        }
        isFetching = true
        lastAttempt = Date()
        render()
        Task {
            defer {
                self.isFetching = false
                self.scheduleNext()
                self.render()
            }
            do {
                self.store(try await self.reader.read())
            } catch {
                self.lastError = error
            }
        }
    }

    private func store(_ result: PageResult) {
        last = result.usage
        lastUpdated = Date()
        lastError = nil
        if let data = try? JSONEncoder().encode(result.usage) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(lastUpdated, forKey: cacheTimeKey)
        }
        // Keep the previous graph if only the requests could not be read.
        if let days = result.requests {
            requests = days
            if let data = try? JSONEncoder().encode(days) {
                UserDefaults.standard.set(data, forKey: requestsCacheKey)
            }
        }
        render()
    }

    private func render() {
        let vibe = last?.vibeCode
        let api = last?.api
        if let button = statusItem.button {
            if let percent = vibe?.percent ?? api?.percent {
                button.attributedTitle = titleString(percent, stale: lastError != nil)
            } else {
                // Without figures, the app still shows its menu with plan, memory and CPU.
                button.attributedTitle = NSAttributedString(string: lastError == nil ? " …" : "")
            }
            button.toolTip = vibeLabel
        }

        planItem.title = tr("Lisens: ", "License: ") + (last?.plan ?? readVibePlan() ?? tr("ukjent", "unknown"))
        let cur = last?.currency ?? "$"
        vibeItem.title = "\(vibeLabel): \(pct(vibe?.percent))"
        vibeAmountItem.title = amountText(vibe, cur)
        apiItem.title = "\(apiLabel): \(pct(api?.percent))"
        apiAmountItem.title = amountText(api, cur)
        apiItem.isHidden = last != nil && api == nil
        apiAmountItem.isHidden = apiItem.isHidden
        resetItem.title = resetText()
        resetItem.isHidden = last == nil
        let total = requests.map { $0.reduce(0) { $0 + $1.total } }
        requestsItem.title = tr("API-kall siste \(requestDays) dager: ", "API requests, last \(requestDays) days: ")
            + (total.map { $0.formatted(.number.locale(appLocale)) } ?? "–")
        requestsGraph.days = requests ?? []
        requestsGraphItem.isHidden = requests == nil
        mistralLogoutItem.isHidden = last == nil && lastError != nil

        if isFetching {
            statusLine.title = tr("Henter…", "Loading…")
        } else if let err = lastError {
            switch err {
            case FetchError.notLoggedIn:
                statusLine.title = tr("Ikke logget inn – velg «Logg inn på Mistral…»",
                                      "Not logged in – choose “Log in to Mistral…”")
            case FetchError.notFound:
                statusLine.title = tr("Fant ikke forbruket på abonnementssiden",
                                      "Usage not found on the subscription page")
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
        let at = clockTime(max(lastAttempt.addingTimeInterval(interval), Date()))
        nextItem.title = tr("Neste oppdatering kl. \(at) · hvert \(Int(interval / 60)). min",
                            "Next update at \(at) · every \(Int(interval / 60)) min")
        applyColors()
    }

    private func titleString(_ percent: Double, stale: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let s = NSMutableAttributedString(string: " ")
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let c = usageColor(percent) { attrs[.foregroundColor] = c }
        s.append(NSAttributedString(string: pct(percent), attributes: attrs))
        if stale {
            s.append(NSAttributedString(string: " ⚠︎", attributes: [.font: font]))
        }
        return s
    }

    private func amountText(_ a: Allowance?, _ cur: String) -> String {
        guard let a else { return tr("   Brukt: –", "   Used: –") }
        return tr("   Brukt \(money(a.used, cur)) av \(money(a.limit, cur))",
                  "   Used \(money(a.used, cur)) of \(money(a.limit, cur))")
    }

    private func money(_ v: Double, _ cur: String) -> String {
        let f = NumberFormatter()
        f.locale = appLocale
        f.numberStyle = .decimal
        f.minimumFractionDigits = v == v.rounded() ? 0 : 2
        f.maximumFractionDigits = 2
        return cur + (f.string(from: NSNumber(value: v)) ?? "\(v)")
    }

    /// The allowances reset on the first day of each calendar month.
    private func resetText() -> String {
        guard let end = Calendar.current.dateInterval(of: .month, for: Date())?.end else { return "" }
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = tr("d. MMMM", "MMMM d")
        return tr("Begge nullstilles ", "Both reset on ") + f.string(from: end)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
