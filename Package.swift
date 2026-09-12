// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIShell",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AIShellCore", targets: ["AIShellCore"]),
        .executable(name: "AIShell", targets: ["AIShellApp"]),
        .executable(name: "aishell-mcp", targets: ["AIShellMCP"]),
        .executable(name: "aishell-run-supervisor", targets: ["AIShellRunSupervisor"])
    ],
    targets: [
        .target(
            name: "AIShellCore",
            path: "Sources/AIShellCore"
        ),
        .executableTarget(
            name: "AIShellApp",
            dependencies: ["AIShellCore"],
            path: "Sources/AIShellApp"
        ),
        .executableTarget(
            name: "AIShellMCP",
            dependencies: ["AIShellCore"],
            path: "Sources/AIShellMCP"
        ),
        .executableTarget(
            name: "AIShellRunSupervisor",
            dependencies: ["AIShellCore"],
            path: "Sources/AIShellRunSupervisor"
        ),
        .testTarget(
            name: "AIShellCoreTests",
            dependencies: ["AIShellCore"],
            path: "Tests/AIShellCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIShellMCPTests",
            dependencies: ["AIShellMCP"],
            path: "Tests/AIShellMCPTests"
        )
    ]
)
