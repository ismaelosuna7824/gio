// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gio",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GioCore", targets: ["GioCore"]),
               .library(name: "GioMac", targets: ["GioMac"]),
               .library(name: "GioMacOS", targets: ["GioMacOS"]),
               .executable(name: "gio-poc", targets: ["GioPOC"]),
               .executable(name: "GioApp", targets: ["GioApp"])],
    targets: [
        .target(name: "GioCore"),
        .target(name: "GioMac", dependencies: ["GioCore"]),
        .target(name: "GioMacOS", dependencies: ["GioCore"]),
        .executableTarget(name: "GioPOC", dependencies: ["GioMacOS"]),
        .executableTarget(name: "GioLab", dependencies: ["GioCore", "GioMacOS"]),
        .executableTarget(name: "GioApp", dependencies: ["GioCore", "GioMac"]),
        .testTarget(name: "GioCoreTests", dependencies: ["GioCore"]),
        .testTarget(name: "GioMacTests", dependencies: ["GioMac"]),
        .testTarget(name: "GioMacOSTests", dependencies: ["GioMacOS"]),
        .testTarget(name: "GioPOCTests", dependencies: ["GioPOC"])
    ]
)
