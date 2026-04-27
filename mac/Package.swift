// swift-tools-version: 5.10
// Builds the MiniEreader executable. The `scripts/build-app.sh` wraps it in a .app bundle.
// The MiniEreader.xcodeproj built by xcodegen is the canonical build path once Xcode is installed.
import PackageDescription

let package = Package(
    name: "MiniEreader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiniEreader", targets: ["MiniEreader"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "MiniEreader",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "MiniEreader",
            exclude: ["Info.plist", "MiniEreader.entitlements"]
        )
    ]
)
