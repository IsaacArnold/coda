import AppKit
import CodaCore

/// Drives the shared `NSColorPanel` for pinning a custom (off-theme) identity
/// colour. Live: each pick fires `apply`, so the pinned colour updates as the
/// user drags. A singleton so it outlives the menu that opened it.
final class PinColorPanel: NSObject {
    static let shared = PinColorPanel()
    private var apply: ((RGB) -> Void)?

    /// Open the panel seeded with `initial`; call `apply` with each chosen colour.
    func begin(initial: NSColor?, apply: @escaping (RGB) -> Void) {
        self.apply = apply
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        if let initial { panel.color = initial }
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let srgb = sender.color.usingColorSpace(.sRGB) else { return }
        apply?(RGB(r: Double(srgb.redComponent),
                   g: Double(srgb.greenComponent),
                   b: Double(srgb.blueComponent)))
    }
}

/// Builds the reusable "Set Color ▸ (swatches…) / Remove Color" submenu used by the
/// sidebar (repo + worktree rows) and the surface tab bar. The `setColor` selector
/// receives an item whose `representedObject` is `["id": targetID, "hex": hex]`; the
/// `removeColor` selector receives an item whose `representedObject` is `targetID`.
enum ColorMenu {
    /// A small rounded filled square for a color menu item.
    static func swatchImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }

    /// A top-level "Set Color" item whose submenu is the active theme's hue
    /// swatches, a "Custom…" pin, and "Remove Color".
    ///
    /// A hue swatch's `representedObject` is `["id": targetID, "value": serialized]`
    /// where `serialized` is an `IdentityColorValue.hue` (it follows the theme).
    /// "Custom…" and "Remove Color" carry the bare `targetID`.
    static func makeSetColorItem(targetID: String, theme: TerminalTheme, target: AnyObject,
                                 setColor: Selector, customColor: Selector,
                                 removeColor: Selector) -> NSMenuItem {
        let colorItem = NSMenuItem(title: "Set Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for hue in IdentityHue.allCases {
            let swatch = NSMenuItem(title: hue.rawValue.capitalized, action: setColor, keyEquivalent: "")
            swatch.target = target
            swatch.representedObject = ["id": targetID, "value": IdentityColorValue.hue(hue).serialized]
            swatch.image = swatchImage(theme.color(for: hue).nsColor)
            colorMenu.addItem(swatch)
        }
        colorMenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: customColor, keyEquivalent: "")
        custom.target = target
        custom.representedObject = targetID
        colorMenu.addItem(custom)
        let remove = NSMenuItem(title: "Remove Color", action: removeColor, keyEquivalent: "")
        remove.target = target
        remove.representedObject = targetID
        colorMenu.addItem(remove)
        colorItem.submenu = colorMenu
        return colorItem
    }
}
