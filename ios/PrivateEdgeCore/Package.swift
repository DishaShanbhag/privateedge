// swift-tools-version:5.9
// Core on-device pipeline shared by the iOS app and a macOS command-line replay tool (pe-replay).
// The macOS tool exists so the Swift code can be checked against the Python harness on the Mac
// (same prompts, tokens and outputs) before it runs on the phone.
import PackageDescription

let package = Package(
    name: "PrivateEdgeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PrivateEdgeCore", targets: ["PrivateEdgeCore"]),
        .executable(name: "pe-replay", targets: ["pe-replay"]),
    ],
    targets: [
        // Download with ios/fetch_llama.sh (llama.cpp b12387, same commit as the Mac harness).
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        .target(name: "PrivateEdgeCore", dependencies: ["llama"]),
        .executableTarget(name: "pe-replay", dependencies: ["PrivateEdgeCore"]),
        .testTarget(name: "PrivateEdgeCoreTests", dependencies: ["PrivateEdgeCore"]),
    ]
)
