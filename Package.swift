// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadingToolDaily",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ReadingToolDaily", targets: ["ReadingToolDaily"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.5.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(name: "ReadingToolDaily", dependencies: [
            "CSQLite", .product(name: "Markdown", package: "swift-markdown")
        ], resources: [
            .copy("Resources/Licensed"),
            .copy("Resources/AppIcons"),
            .copy("Resources/AIServiceLogos"),
            .copy("Resources/Language"),
            .copy("Resources/ThirdPartyNotices")
        ]),
        .testTarget(name: "ReadingToolDailyTests", dependencies: ["ReadingToolDaily"])
    ],
    swiftLanguageModes: [.v5]
)
