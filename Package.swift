// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Conductor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(name: "ConductorCore"),
        .executableTarget(
            name: "Conductor",
            dependencies: [
                "ConductorCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            resources: [.copy("Themes")]
        ),
        .testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore"])
    ],
    swiftLanguageModes: [.v5]
)
