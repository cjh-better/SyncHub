// swift-tools-version:5.5
// Optional: `swift build -c release` (or open in Xcode). The installer uses build_app.sh (plain swiftc),
// which also wraps the binary into SyncHub.app with Info.plist + icon + ad-hoc signature.
import PackageDescription

let package = Package(
    name: "SyncHub",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "SyncHub", path: "Sources/SyncHub")
    ]
)
