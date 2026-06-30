import Foundation

extension Bundle {
    /// Bundle that holds Coda's packaged assets (icons, themes, glyph font).
    ///
    /// Two runtime layouts have to work:
    ///
    /// * **Distributed `.app`** — the assets are sealed *flat* under
    ///   `Contents/Resources/{Resources,Themes}` (see `scripts/make-app.sh`).
    ///   They live there, rather than in a nested SwiftPM `*.bundle`, so the app
    ///   code-signs cleanly: a `*.bundle` dir with no `Info.plist` is rejected by
    ///   `codesign`, which blocks Developer-ID signing and notarization. In this
    ///   layout `Bundle.main` (whose `resourceURL` is `Contents/Resources`) is the
    ///   one that can find them.
    ///
    /// * **`swift run` / tests** — there is no `.app`; the SwiftPM-generated
    ///   resource bundle (`Bundle.module`) is the one next to the executable.
    ///
    /// We probe for a known asset in `Bundle.main` to tell the two apart, resolving
    /// once. (Relying on `Bundle.module` alone is what shipped a `.app` that only
    /// ran on the build machine, because its accessor falls back to a hard-coded
    /// absolute build path that does not exist on any other Mac.)
    static let codaAssets: Bundle = {
        if Bundle.main.url(forResource: "Coda", withExtension: "icns",
                           subdirectory: "Resources") != nil {
            return .main
        }
        return .module
    }()
}
