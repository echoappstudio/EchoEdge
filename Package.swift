// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoEdge",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EchoEdgeCore", targets: ["EchoEdgeCore"]),
        .executable(name: "EchoEdgeApp", targets: ["EchoEdgeApp"])
    ],
    dependencies: [
        // Automatic updates. Pinned exactly; the packaged app embeds this framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "EchoEdgeCore"),
        .executableTarget(
            name: "EchoEdgeApp",
            dependencies: [
                "EchoEdgeCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                // The packaged app keeps Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "EchoEdgeTests", dependencies: ["EchoEdgeCore"])
    ]
)
