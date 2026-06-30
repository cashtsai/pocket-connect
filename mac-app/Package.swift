// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketConnect",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PocketConnect", path: "Sources/PocketConnect")
    ]
)
