import AppKit
import ConductorCore

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

    /// A top-level "Set Color" item whose submenu is the palette swatches + "Remove Color".
    static func makeSetColorItem(targetID: String, target: AnyObject,
                                 setColor: Selector, removeColor: Selector) -> NSMenuItem {
        let colorItem = NSMenuItem(title: "Set Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for hex in IdentityPalette.colors {
            let swatch = NSMenuItem(title: hex, action: setColor, keyEquivalent: "")
            swatch.target = target
            swatch.representedObject = ["id": targetID, "hex": hex]
            if let color = NSColor(hex: hex) { swatch.image = swatchImage(color) }
            colorMenu.addItem(swatch)
        }
        colorMenu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Color", action: removeColor, keyEquivalent: "")
        remove.target = target
        remove.representedObject = targetID
        colorMenu.addItem(remove)
        colorItem.submenu = colorMenu
        return colorItem
    }
}
