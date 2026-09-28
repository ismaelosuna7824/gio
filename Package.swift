// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gio",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GioCore", targets: ["GioCore"]),
               .library(name: "GioMac", targets: ["GioMac"]),
               .executable(name: "gio-poc", targets: ["GioPOC"]),
               .executable(name: "GioApp", targets: ["GioApp"])],
    targets: [
        .target(name: "GioCore"),
        .target(name: "GioMac", dependencies: ["GioCore"]),
        .executableTarget(name: "GioPOC"),
        .executableTarget(name: "GioApp", dependencies: ["GioCore", "GioMac"]),
        .testTarget(name: "GioCoreTests", dependencies: ["GioCore"]),
        .testTarget(name: "GioMacTests", dependencies: ["GioMac"]),
        .testTarget(name: "GioPOCTests", dependencies: ["GioPOC"])
    ]
)
