// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Chewy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Chewy", targets: ["ChewyApp"]),
        .executable(name: "ChewyCoreChecks", targets: ["ChewyCoreChecks"]),
        .executable(name: "ChewyVisualSnapshot", targets: ["ChewyVisualSnapshot"]),
        .library(name: "ChewyCore", targets: ["ChewyCore"])
    ],
    targets: [
        .target(name: "ChewyCore"),
        .executableTarget(
            name: "ChewyApp",
            dependencies: ["ChewyCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ChewyCoreChecks",
            dependencies: ["ChewyCore"],
            path: "Tests/ChewyCoreChecks"
        ),
        .executableTarget(
            name: "ChewyVisualSnapshot",
            dependencies: ["ChewyCore"],
            path: "Tools/ChewyVisualSnapshot"
        )
    ]
)
