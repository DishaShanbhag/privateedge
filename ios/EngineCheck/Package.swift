// swift-tools-version:5.9
// Runs the iPhone app's LlamaEngine (same source file, via a symlink) on the Mac with the macOS
// slice of the llama.cpp b12387 xcframework, over the dev set, and compares every raw output with
// the committed Mac (Python) runs. Checks the phone's prompt, decoding and grammar path before a
// phone is involved.
//   cd ios/EngineCheck && swift run -c release engine-check C1
import PackageDescription

let package = Package(
    name: "EngineCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../CalendarCore")],
    targets: [
        .binaryTarget(name: "llama", path: "../vendor/b12387/build-apple/llama.xcframework"),
        .executableTarget(name: "engine-check", dependencies: ["llama", "CalendarCore"]),
    ]
)
