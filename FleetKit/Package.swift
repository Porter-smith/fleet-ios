// swift-tools-version:5.9
// FleetKit: the app's Foundation-only core (API models, the HTTP + SSE client,
// the transcript builder and the composer's controls), kept apart from SwiftUI
// so `swift test` runs it on a Mac without a simulator.
import PackageDescription

let package = Package(
    name: "FleetKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FleetKit", targets: ["FleetKit"])],
    targets: [
        .target(name: "FleetKit", resources: [.copy("Demo")]),
        .testTarget(name: "FleetKitTests", dependencies: ["FleetKit"]),
    ]
)
