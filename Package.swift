// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gio",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GioCore", targets: ["GioCore"]),
               .library(name: "GioMac", targets: ["GioMac"]),
               .library(name: "GioMacOS", targets: ["GioMacOS"]),
               .library(name: "GioUI", targets: ["GioUI"]),
               .library(name: "GioSession", targets: ["GioSession"]),
               .executable(name: "gio-poc", targets: ["GioPOC"]),
               .executable(name: "GioApp", targets: ["GioApp"])],
    targets: [
        .target(name: "GioCore"),
        .target(name: "GioMac", dependencies: ["GioCore"]),
        .target(name: "GioMacOS", dependencies: ["GioCore"]),
        .target(name: "GioUI", dependencies: ["GioCore", "GioMacOS"], resources: [.process("Resources")]),
        .target(name: "GioSession", dependencies: ["GioCore", "GioMacOS"]),
        .executableTarget(name: "GioPOC", dependencies: ["GioMacOS"]),
        .executableTarget(name: "GioCLI", dependencies: ["GioCore"]),
        .executableTarget(name: "GioDesktop", dependencies: ["GioCore", "GioMacOS", "GioUI", "GioSession"]),
        .executableTarget(name: "GioApp", dependencies: ["GioCore", "GioMac"]),
        .testTarget(name: "GioCoreTests", dependencies: ["GioCore"]),
        .testTarget(name: "GioMacTests", dependencies: ["GioMac"]),
        .testTarget(name: "GioMacOSTests", dependencies: ["GioMacOS"]),
        .testTarget(name: "GioUITests", dependencies: ["GioUI"]),
        .testTarget(name: "GioSessionTests", dependencies: ["GioSession"]),
        .testTarget(name: "GioPOCTests", dependencies: ["GioPOC"])
    ]
)
