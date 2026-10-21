// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Beeline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Beeline", path: "Sources/Beeline"),
        .testTarget(name: "BeelineTests", dependencies: ["Beeline"], path: "Tests/BeelineTests")
    ]
)
