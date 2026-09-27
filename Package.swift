// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gio",
    products: [.library(name: "GioCore", targets: ["GioCore"])],
    targets: [
        .target(name: "GioCore"),
        .testTarget(name: "GioCoreTests", dependencies: ["GioCore"])
    ]
)
