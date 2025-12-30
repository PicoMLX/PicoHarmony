// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Harmony",
  platforms: [.iOS(.v13)],
  products: [
    .library(name: "Harmony", targets: ["Harmony"])
  ],
  targets: [
    .binaryTarget(
      name: "HarmonyFFI",
      path: "Binaries/HarmonyFFI.xcframework"
    ),
    .target(
      name: "HarmonyUniFFI",
      dependencies: ["HarmonyFFI"],
      path: "SourcesGenerated/HarmonyUniFFI"
    ),
    .target(
      name: "Harmony",
      dependencies: ["HarmonyUniFFI"],
      path: "Sources/Harmony"
    ),
  ]
)
