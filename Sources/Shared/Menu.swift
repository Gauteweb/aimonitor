import AppKit
import ServiceManagement

let headerTag = 1

/// A menu item view that draws itself, which `applyMenuColors` leaves alone.
protocol MenuGraphView: NSView {}

/// The first menu item: the app's name in bold, followed by its version.
func headerMenuItem(appName: String) -> NSMenuItem {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let headerText = NSMutableAttributedString(
        string: appName,
        attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                     .foregroundColor: NSColor.labelColor])
    headerText.append(NSAttributedString(
        string: "  v. \(version)",
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                     .foregroundColor: NSColor.labelColor]))
    header.attributedTitle = headerText
    header.isEnabled = false
    header.tag = headerTag
    return header
}

private let infoInset: CGFloat = 20
private let infoHeight: CGFloat = 22

/// Swaps the usual menu colours: information lines (disabled items) are shown
/// in the normal text colour, and clickable actions in grey.
/// AppKit always greys out a disabled item's title, so information lines are
/// drawn as custom label views instead.
/// Called after every text change, since setting `title` doesn't update the view.
@MainActor
func applyMenuColors(_ menu: NSMenu) {
    let font = NSFont.menuFont(ofSize: 0)
    for item in menu.items where !item.isSeparatorItem && !(item.view is MenuGraphView) {
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

@MainActor
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

// MARK: - Launch at login

var launchAtLoginState: NSControl.StateValue {
    SMAppService.mainApp.status == .enabled ? .on : .off
}

@MainActor
func toggleLaunchAtLogin() {
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
}

// MARK: - Formatting

func clockTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = appLocale
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

func pct(_ v: Double?) -> String {
    guard let v else { return "–" }
    return "\(Int(v.rounded()))%"
}

/// Yellow from 50% and red from 75%.
func usageColor(_ v: Double?) -> NSColor? {
    guard let v = v?.rounded() else { return nil }
    if v >= 75 { return .systemRed }
    if v >= 50 { return .systemYellow }
    return nil
}
