// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceControl",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoiceControlCore", targets: ["VoiceControlCore"]),
        .library(name: "VoiceControlMac", targets: ["VoiceControlMac"]),
        .executable(name: "VoiceControl", targets: ["VoiceControlApp"])
    ],
    targets: [
        .target(name: "VoiceControlCore"),
        .target(name: "VoiceControlMac", dependencies: ["VoiceControlCore"]),
        .executableTarget(name: "VoiceControlApp", dependencies: ["VoiceControlCore", "VoiceControlMac"]),
        .testTarget(name: "VoiceControlCoreTests", dependencies: ["VoiceControlCore"])
    ]
)
