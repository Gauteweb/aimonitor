import AppKit

enum CPUSampling {
    static let interval: TimeInterval = 2
    static let capacity = 150   // 5 minutes
}

/// CPU usage over time per process group, in percent of one core (as in Activity Monitor).
struct CPUHistory<Group: Hashable> {
    let groups: [Group]
    private var series: [Group: [Double]] = [:]
    private var previous: ProcessUsage<Group>?
    private var previousTime: UInt64 = 0

    init(groups: [Group]) { self.groups = groups }

    subscript(_ group: Group) -> [Double] { series[group] ?? [] }

    /// Adds a sample computed from the CPU time used since the previous one.
    /// Processes that started in between count from zero; ones that exited are left out.
    mutating func add(_ usage: ProcessUsage<Group>) {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previous = usage; previousTime = now }
        guard let previous, now > previousTime else { return }
        let elapsed = Double(now - previousTime)
        for group in groups {
            let before = previous[group].cpuTimes
            let used = usage[group].cpuTimes.reduce(0.0) { sum, entry in
                let start = before[entry.key] ?? 0
                return sum + (entry.value > start ? Double(entry.value - start) : 0)
            }
            var values = series[group] ?? []
            values.append(used / elapsed * 100)
            if values.count > CPUSampling.capacity { values.removeFirst(values.count - CPUSampling.capacity) }
            series[group] = values
        }
    }
}

/// Line graph of CPU usage, shown as a menu item view, with a legend below.
/// `width` is the minimum; the view stretches to the width of the menu.
final class CPUGraphView: NSView, MenuGraphView {
    struct Series {
        let name: String
        let values: [Double]
        let color: NSColor
    }

    var series: [Series] = [] { didSet { needsDisplay = true } }

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
        let step = plot.width / CGFloat(CPUSampling.capacity - 1)
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
