// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WorkPager", platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkPager", targets: ["WorkPager"])],
    targets: [
        .target(name: "WorkPagerCore"),
        .executableTarget(name: "WorkPager", dependencies: ["WorkPagerCore"]),
        .testTarget(name: "WorkPagerCoreTests", dependencies: ["WorkPagerCore"])
    ], swiftLanguageModes: [.v5]
)
