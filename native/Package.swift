// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The app (RhemionApp + its bundled rhemion-runtime helper) and its libraries always build. Tests and
// the developer tools are added only when their folders are present, so a checkout without them builds.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func present(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

var products: [Product] = [
    .executable(name: "RhemionApp", targets: ["RhemionApp"]),
    .executable(name: "rhemion-runtime", targets: ["rhemion-runtime"]),
    .library(name: "RhemionCore", targets: ["RhemionCore"]),
    .library(name: "RhemionIPC", targets: ["RhemionIPC"]),
    .library(name: "RhemionAudio", targets: ["RhemionAudio"]),
    .library(name: "RhemionASR", targets: ["RhemionASR"]),
    .library(name: "RhemionDelivery", targets: ["RhemionDelivery"]),
    .library(name: "RhemionStorage", targets: ["RhemionStorage"]),
]

var targets: [Target] = [
    .target(name: "RhemionCore"),
    .target(name: "RhemionIPC"),
    .target(name: "RhemionStorage"),
    .target(name: "RhemionRuntime", dependencies: ["RhemionCore", "RhemionIPC", "RhemionAudio", "RhemionASR", "RhemionStorage"]),
    .target(name: "RhemionAudio"),
    .target(name: "RhemionASR", dependencies: ["RhemionAudio", .product(name: "FluidAudio", package: "FluidAudio")]),
    .target(name: "RhemionDelivery"),
    .executableTarget(name: "rhemion-runtime", dependencies: ["RhemionRuntime", "RhemionCore", "RhemionIPC", "RhemionAudio", "RhemionASR", "RhemionDelivery"]),
    // The menu-bar app. Bundled into Rhemion.app (with rhemion-runtime as its helper) by deploy/build-app.sh.
    .executableTarget(name: "RhemionApp", dependencies: ["RhemionIPC", "RhemionStorage"]),
]

// Developer tools (not part of the app).
if present("Sources/rhemion-history") {
    products.append(.executable(name: "rhemion-history", targets: ["rhemion-history"]))
    targets.append(.executableTarget(name: "rhemion-history", dependencies: ["RhemionRuntime"]))
}
if present("Sources/asr-compare") {
    products.append(.executable(name: "asr-compare", targets: ["asr-compare"]))
    targets.append(.executableTarget(name: "asr-compare", dependencies: ["RhemionASR"]))
}
if present("deploy/rhemion-devices.swift") && present("deploy/rhemion-models.swift") {
    let deployExtras = ["hammerspoon", "notch.swift", "paste.swift", "rhemion", "rhemion-config"]
    products += [.executable(name: "rhemion-devices", targets: ["rhemion-devices"]),
                 .executable(name: "rhemion-models", targets: ["rhemion-models"])]
    targets += [
        .executableTarget(name: "rhemion-devices", dependencies: ["RhemionAudio"], path: "deploy",
                          exclude: deployExtras + ["rhemion-models.swift"], sources: ["rhemion-devices.swift"]),
        .executableTarget(name: "rhemion-models", dependencies: ["RhemionASR", "RhemionCore"], path: "deploy",
                          exclude: deployExtras + ["rhemion-devices.swift"], sources: ["rhemion-models.swift"]),
    ]
}

if present("Tests") {
    targets += [
        .testTarget(name: "RhemionCoreTests", dependencies: ["RhemionCore"]),
        .testTarget(name: "RhemionIPCTests", dependencies: ["RhemionIPC"]),
        .testTarget(name: "RhemionRuntimeTests", dependencies: ["RhemionRuntime", "RhemionCore", "RhemionAudio", "RhemionASR", "RhemionDelivery", "RhemionStorage"]),
        .testTarget(name: "RhemionAudioTests", dependencies: ["RhemionAudio"]),
        .testTarget(name: "RhemionASRTests", dependencies: ["RhemionASR", "RhemionAudio", "RhemionStorage"]),
        .testTarget(name: "RhemionDeliveryTests", dependencies: ["RhemionDelivery"]),
        .testTarget(name: "RhemionStorageTests", dependencies: ["RhemionStorage"]),
        .testTarget(name: "RhemionAppTests", dependencies: ["RhemionApp"]),
    ]
}

let package = Package(
    name: "Rhemion",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: [
        // Apache-2.0 (links cleanly into MIT Rhemion). Pinned to a known-good revision.
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "c7b13a3942e79893f3bd76bfe3b1ed8d03e0bfc7"),
    ],
    targets: targets
)
