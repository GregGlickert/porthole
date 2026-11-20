// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Porthole",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "porthole", targets: ["porthole"]),
    .executable(name: "PortholeApp", targets: ["PortholeApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", .upToNextMinor(from: "0.12.1")),
  ],
  targets: [
    .target(name: "PortholeCore"),
    .executableTarget(
      name: "porthole",
      dependencies: [
        "PortholeCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .executableTarget(name: "PortholeApp", dependencies: ["PortholeCore"]),
    .testTarget(name: "PortholeCoreTests", dependencies: ["PortholeCore"]),
  ]
)
