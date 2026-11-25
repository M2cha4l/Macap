// swift-tools-version: 5.10
// Macap: single-file app plus the vendored RifeMetal package (GPU frame interpolation).
import PackageDescription
let package = Package(
    name: "Macap",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "ThirdParty/RifeMetal")],
    targets: [.executableTarget(name: "Macap",
                                dependencies: [.product(name: "RifeMetal", package: "RifeMetal")],
                                path: ".", sources: ["main.swift"],
                                swiftSettings: [.unsafeFlags(["-swift-version", "5"])])]
)
