// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Spike",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ],
    // Spike is a single-window AppKit app; Swift 5 mode keeps concurrency
    // checks as warnings instead of fighting strict isolation in throwaway code.
    swiftLanguageModes: [.v5]
)
