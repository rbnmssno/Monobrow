// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Monobrow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Monobrow", path: "Sources/Monobrow")
    ]
)
