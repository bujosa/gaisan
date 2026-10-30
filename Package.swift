// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Gaisan",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "Gaisan"),
    .testTarget(name: "GaisanTests", dependencies: ["Gaisan"]),
  ]
)
