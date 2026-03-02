// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "MacAdminToolbox",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "MacAdminToolbox", targets: ["MacAdminToolbox"]),
    ],
    targets: [
        .executableTarget(
            name: "MacAdminToolbox",
            path: "Sources/MacAdminToolbox"
        ),
    ]
)
