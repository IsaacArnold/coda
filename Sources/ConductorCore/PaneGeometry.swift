import Foundation

/// A split's orientation. `.horizontal` lays panes side-by-side (vertical dividers);
/// `.vertical` stacks panes (horizontal dividers).
public enum SplitAxis: Equatable {
    case horizontal, vertical
}

/// Arrow-key focus directions. Coordinates use a top-left origin (y increases downward),
/// so `.up` is toward smaller y and `.down` toward larger y.
public enum PaneDirection {
    case left, right, up, down
}

/// A pane's on-screen rectangle, top-left origin. Pure value type — the shell converts
/// AppKit frames (bottom-left origin) into this convention before calling `nearestPane`.
public struct PaneRect: Equatable {
    public let id: String
    public let x, y, width, height: Double
    public init(id: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height
    }
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

/// The nearest pane to the focused one in the given direction, by center distance.
/// Returns nil if the focused id isn't in `frames` or nothing lies that way.
public func nearestPane(from focusedID: String, direction: PaneDirection,
                        frames: [PaneRect]) -> String? {
    guard let cur = frames.first(where: { $0.id == focusedID }) else { return nil }
    var best: (id: String, dist: Double)?
    for f in frames where f.id != focusedID {
        let inDirection: Bool
        switch direction {
        case .left:  inDirection = f.centerX < cur.centerX
        case .right: inDirection = f.centerX > cur.centerX
        case .up:    inDirection = f.centerY < cur.centerY
        case .down:  inDirection = f.centerY > cur.centerY
        }
        guard inDirection else { continue }
        let dx = f.centerX - cur.centerX, dy = f.centerY - cur.centerY
        let dist = dx * dx + dy * dy
        if best == nil || dist < best!.dist { best = (f.id, dist) }
    }
    return best?.id
}
