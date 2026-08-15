// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FamilyHub",
    // macOS is listed alongside iOS so that the domain and store layers can be
    // built and tested from the command line — including in CI — without
    // booting a simulator. The shipping product targets iOS and iPadOS.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FamilyHubCore", targets: ["FamilyHubCore"]),
        .library(name: "FamilyHubStore", targets: ["FamilyHubStore"]),
    ],
    targets: [
        // Pure domain layer. Foundation only — no SwiftData, no SwiftUI.
        .target(
            name: "FamilyHubCore",
            swiftSettings: .strict
        ),
        // Storage contracts plus an in-memory implementation used by tests,
        // SwiftUI previews, and the onboarding demo household.
        .target(
            name: "FamilyHubStore",
            dependencies: ["FamilyHubCore"],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "FamilyHubCoreTests",
            dependencies: ["FamilyHubCore"],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "FamilyHubStoreTests",
            dependencies: ["FamilyHubStore", "FamilyHubCore"],
            swiftSettings: .strict
        ),
    ],
    swiftLanguageModes: [.v6]
)

extension [SwiftSetting] {
    /// Swift 6 language mode already enforces strict concurrency checking for
    /// every target. `ExistentialAny` is added on top so that boxed protocol
    /// types are always spelled `any Protocol` — the cost of dynamic dispatch
    /// stays visible at the call site instead of hiding in a type annotation.
    static var strict: [SwiftSetting] {
        [
            .enableUpcomingFeature("ExistentialAny"),
        ]
    }
}
