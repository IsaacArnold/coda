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

    /// Resolve a bundled resource subpath (e.g. `"shell-integration/zsh"`,
    /// `"completion-specs"`) to an on-disk URL, robust to the two runtime layouts.
    ///
    /// The two layouts nest our `Resources/` tree at different depths relative to
    /// `resourceURL`, so a single `appendingPathComponent` can't serve both:
    ///
    /// * **`swift run` / tests** — `Bundle.module.resourceURL` already points *into*
    ///   `Coda_Coda.bundle/Resources`, so the files sit directly at `<resourceURL>/<subpath>`.
    /// * **Distributed `.app`** — `make-app.sh` copies the SwiftPM bundle's *contents* (its
    ///   `Resources/` dir included) flat into `Contents/Resources`, and `Bundle.main.resourceURL`
    ///   is `Contents/Resources`, so the files sit at `<resourceURL>/Resources/<subpath>`.
    ///
    /// Probing both (without the extra `Resources/`, then with) resolves correctly in either,
    /// and returns nil if neither exists — callers treat that as "feature unavailable", never a
    /// crash. (Using raw `resourceURL.appendingPathComponent("Resources/<subpath>")` shipped a
    /// path-doubling bug that broke completions under `swift run`.)
    static func codaBundledResource(_ subpath: String) -> URL? {
        guard let base = codaAssets.resourceURL else { return nil }
        let candidates = [base.appendingPathComponent(subpath),
                          base.appendingPathComponent("Resources/\(subpath)")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
