import AppKit
import CodaCore

/// One selectable app icon: a stable `id` (used as the persisted preference and the swatch's
/// identity), a human `displayName`, and the loaded `image`.
struct AppIcon {
    let id: String
    let displayName: String
    let image: NSImage
}

/// The curated set of app icons the user can choose from in Settings.
///
/// "Default" is synthesised from `Resources/Coda.icns` (which must stay put — the `.app`-layout
/// probe in `ResourceBundle` depends on it) so it always appears first even though it lives
/// outside `Icons/`. Every other entry is discovered by scanning the bundled `Resources/Icons`
/// folder for `.icns` files, so curating the gallery is just adding/removing files there.
enum AppIconCatalog {
    static let defaultID = "Default"

    /// Default first, then each `Icons/*.icns` sorted by filename. Entries whose image fails to
    /// load are skipped (a corrupt/removed file never crashes the picker).
    static func all() -> [AppIcon] {
        var icons: [AppIcon] = []
        if let def = defaultImage() {
            icons.append(AppIcon(id: defaultID, displayName: defaultID, image: def))
        }
        if let dir = Bundle.codaBundledResource("Icons"),
           let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
            for url in urls.filter({ $0.pathExtension == "icns" })
                            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let image = NSImage(contentsOf: url) else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                icons.append(AppIcon(id: id, displayName: id, image: image))
            }
        }
        return icons
    }

    /// The image for a chosen id. nil/unknown/"Default" → the default icon. Falling back keeps a
    /// stale preference (a curated icon removed after being selected) from leaving a blank icon.
    static func image(forID id: String?) -> NSImage? {
        guard let id, id != defaultID else { return defaultImage() }
        return all().first { $0.id == id }?.image ?? defaultImage()
    }

    /// `Resources/Coda.icns`, the shipped default, via the same bundle accessor the dock icon
    /// used before this feature existed.
    private static func defaultImage() -> NSImage? {
        guard let url = Bundle.codaAssets.url(forResource: "Coda", withExtension: "icns",
                                              subdirectory: "Resources") else { return nil }
        return NSImage(contentsOf: url)
    }
}
