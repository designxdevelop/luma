// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Luma",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .executable(name: "Luma", targets: ["Luma"]),
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .library(name: "LumaUI", targets: ["LumaUI", "LumaIntents"])
    ],
    targets: [
        .target(name: "LumaCore"),
        // Shared SwiftUI app for macOS and iOS; each platform supplies a thin entry point.
        .target(name: "LumaUI", dependencies: ["LumaCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        // Siri / Shortcuts actions. Separate because App Intents' @Parameter doesn't compile
        // under LumaUI's default MainActor isolation; shipped inside the LumaUI product.
        .target(name: "LumaIntents", dependencies: ["LumaUI", "LumaCore"]),
        .executableTarget(name: "Luma", dependencies: ["LumaUI"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "LumaCoreTests", dependencies: ["LumaCore"]),
        .testTarget(name: "LumaAppTests", dependencies: ["LumaUI", "LumaCore", "LumaIntents"])
    ]
)
