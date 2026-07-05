// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketConnect",
    platforms: [.macOS(.v13)],
    targets: [
        // Testable core: CloudKit discovery layer (device registry + pairing
        // invite handling) with a mockable database abstraction.
        .target(name: "PocketConnectKit", path: "Sources/PocketConnectKit"),
        .executableTarget(
            name: "PocketConnect",
            dependencies: ["PocketConnectKit"],
            path: "Sources/PocketConnect"),
        .testTarget(
            name: "PocketConnectKitTests",
            dependencies: ["PocketConnectKit"],
            path: "Tests/PocketConnectKitTests"),
    ]
)
