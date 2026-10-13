// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeckTabs",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeckTabs",
            dependencies: ["SwiftTerm"],
            path: "Sources/DeckTabs",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
