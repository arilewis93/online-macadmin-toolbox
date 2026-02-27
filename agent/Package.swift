// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "AutoConfigAgent",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "AutoConfigAgent", targets: ["AutoConfigAgent"]),
    ],
    targets: [
        .executableTarget(
            name: "AutoConfigAgent",
            path: "Sources/AutoConfigAgent"
        ),
    ]
)
