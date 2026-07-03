// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Coda",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(name: "CodaCore"),
        .executableTarget(
            name: "Coda",
            dependencies: [
                "CodaCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            resources: [.copy("Themes"), .copy("Resources")]
        ),
        .executableTarget(
            name: "CodaHook",
            dependencies: ["CodaCore"]
        ),
        .testTarget(name: "CodaCoreTests", dependencies: ["CodaCore"])
    ],
    swiftLanguageModes: [.v5]
)
