// swift-tools-version: 6.0
import PackageDescription

// The poker engine, extracted from the app target so it can be built and tested
// without a simulator. The app's test cycle was ~116s end to end; the same
// assertions run here in a fraction of that, and everything downstream of this
// work is gated on how often the suite can be run.
//
// Nothing in PokerCore may import SwiftUI, UIKit, Combine or Metal. That is the
// point of the boundary: the engine is a pure function from a table state to a
// number, and it stays testable only while that is true.
let package = Package(
    name: "PokerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PokerCore", targets: ["PokerCore"]),
        .library(name: "PokerTestSupport", targets: ["PokerTestSupport"]),
    ],
    targets: [
        .target(
            name: "PokerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Oracles and parsing helpers shared by the package's tests and the app's.
        // Keeping them in one place is what stops the app suite and this one from
        // silently drifting apart.
        .target(
            name: "PokerTestSupport",
            dependencies: ["PokerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PokerCoreTests",
            dependencies: ["PokerCore", "PokerTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
