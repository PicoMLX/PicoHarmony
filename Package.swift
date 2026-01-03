// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Harmony",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    .library(name: "Harmony", targets: ["Harmony"])
  ],
  targets: [
    .binaryTarget(
      name: "harmony_uniffiFFI",
      path: "Binaries/harmony_uniffiFFI.xcframework"
    ),
    .target(
      name: "HarmonyUniFFI",
      dependencies: ["harmony_uniffiFFI"],
      path: "rust/harmony_uniffi/Sources/PicoHarmonyGenerated"
    ),
    .target(
      name: "Harmony",
      dependencies: ["HarmonyUniFFI"],
      path: "Sources/PicoHarmony"
    ),
    .testTarget(
      name: "PicoHarmonyTests",
      dependencies: ["Harmony"],
      path: "Tests/PicoHarmonyTests"
    ),
  ]
)
