import AppKit

/// The Claude logo mark for the Launch-Claude toolbar button.
///
/// Prefers a bundled image asset named "ClaudeMark" (drop in the official artwork
/// to use it); otherwise draws a terracotta sunburst approximating the Claude mark.
func claudeMarkImage(diameter: CGFloat = 17) -> NSImage {
    if let asset = NSImage(named: "ClaudeMark") {
        asset.size = NSSize(width: diameter, height: diameter)
        return asset
    }

    let size = NSSize(width: diameter, height: diameter)
    let image = NSImage(size: size)
    image.lockFocus()

    // Anthropic "clay" terracotta (#D97757).
    NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).set()

    let center = NSPoint(x: diameter / 2, y: diameter / 2)
    let rays = 12
    let inner = diameter * 0.07
    let outerLong = diameter * 0.46
    let outerShort = diameter * 0.34

    let path = NSBezierPath()
    path.lineWidth = max(1.2, diameter * 0.085)
    path.lineCapStyle = .round
    for i in 0..<rays {
        let angle = (CGFloat(i) / CGFloat(rays)) * 2 * .pi
        let outer = (i % 2 == 0) ? outerLong : outerShort
        path.move(to: NSPoint(x: center.x + cos(angle) * inner,
                              y: center.y + sin(angle) * inner))
        path.line(to: NSPoint(x: center.x + cos(angle) * outer,
                              y: center.y + sin(angle) * outer))
    }
    path.stroke()

    image.unlockFocus()
    return image
}
