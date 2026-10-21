// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Publisher", platforms: [.macOS(.v14)],
    products: [.executable(name: "ios-publish", targets: ["ios-publish"])],
    targets: [
        .target(name: "PublisherCore"),
        .executableTarget(name: "ios-publish", dependencies: ["PublisherCore"]),
        .testTarget(name: "PublisherCoreTests", dependencies: ["PublisherCore"])
    ], swiftLanguageModes: [.v5]
)
