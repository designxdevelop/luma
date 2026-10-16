// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Luma", targets: ["Luma"]), .library(name: "LumaCore", targets: ["LumaCore"])],
    targets: [
        .target(name: "LumaCore"),
        .executableTarget(name: "Luma", dependencies: ["LumaCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"]),
        .testTarget(name: "LumaAppTests", dependencies: ["Luma", "LumaCore"])
    ]
)
