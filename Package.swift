// swift-tools-version: 6.2
import PackageDescription

let approachable: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "TapSense",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "TapCore", swiftSettings: approachable),
    .target(name: "TapEngine", dependencies: ["TapCore"], swiftSettings: approachable),
    .executableTarget(
      name: "TapSense",
      dependencies: ["TapEngine"],
      swiftSettings: approachable + [.defaultIsolation(MainActor.self)]
    ),
    .executableTarget(name: "tapcli", dependencies: ["TapCore"], swiftSettings: approachable),
    .executableTarget(name: "handbench", dependencies: ["TapCore", "TapEngine"], swiftSettings: approachable),
    .testTarget(name: "TapCoreTests", dependencies: ["TapCore"], swiftSettings: approachable),
  ],
  swiftLanguageModes: [.v6]
)
