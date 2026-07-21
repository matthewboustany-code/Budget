// swift-tools-version:6.1
import PackageDescription

// Shared between the iOS app (Budget) and the Vapor backend (Server).
// Every target here must build on Linux: no UIKit/SwiftUI/GRDB imports,
// and no external dependencies.
let package = Package(
    name: "BudgetCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BudgetModels", targets: ["BudgetModels"]),
        .library(name: "BudgetKit", targets: ["BudgetKit"]),
    ],
    targets: [
        // Wire-format domain types + API DTOs. Zero dependencies.
        .target(name: "BudgetModels"),
        // Pure calculation logic used identically by app and server.
        .target(name: "BudgetKit", dependencies: ["BudgetModels"]),
        .testTarget(name: "BudgetModelsTests", dependencies: ["BudgetModels"]),
        .testTarget(name: "BudgetKitTests", dependencies: ["BudgetKit"]),
    ]
)
