// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SideBrief",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BriefCore", targets: ["BriefCore"]),
        .executable(name: "SideBrief", targets: ["SideBrief"])
    ],
    targets: [
        .target(name: "BriefCore"),
        .executableTarget(name: "SideBrief", dependencies: ["BriefCore"]),
        .testTarget(name: "BriefCoreTests", dependencies: ["BriefCore"])
    ],
    swiftLanguageVersions: [.v5]
)
