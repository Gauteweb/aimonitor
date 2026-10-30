import AppKit

/// A monochrome version of the app icon (the letters "AI" with a graph and a
/// light, no background) as a template image, so it follows the menu bar's
/// light/dark appearance.
func appIconMenuBarImage(description: String) -> NSImage {
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
    img.accessibilityDescription = description
    return img
}
