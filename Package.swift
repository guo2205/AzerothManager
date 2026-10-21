// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AzerothManager", platforms: [.macOS(.v14)], products: [.library(name: "ManagerCore", targets: ["ManagerCore"])], targets: [.target(name: "ZipInflate", linkerSettings: [.linkedLibrary("z")]), .target(name: "ManagerCore", dependencies: ["ZipInflate"]), .testTarget(name: "ManagerCoreTests", dependencies: ["ManagerCore"], resources: [.copy("Fixtures")])])
