// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WordLinks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WordLinks", targets: ["WordLinks"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.5.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(name: "WordLinks", dependencies: [
            "CSQLite", .product(name: "Markdown", package: "swift-markdown")
        ], resources: [
            .copy("Resources/Licensed"),
            .copy("Resources/AppIcons"),
            .copy("Resources/AIServiceLogos"),
            .copy("Resources/Language"),
            .copy("Resources/ThirdPartyNotices")
        ]),
        .testTarget(name: "WordLinksTests", dependencies: ["WordLinks"])
    ],
    swiftLanguageModes: [.v5]
)
