// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIShell",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AIShellCore", targets: ["AIShellCore"]),
        .executable(name: "aishell-mcp", targets: ["AIShellMCP"])
    ],
    targets: [
        .target(name: "AIShellCore"),
        .executableTarget(name: "AIShellMCP", dependencies: ["AIShellCore"]),
        .testTarget(name: "AIShellCoreTests", dependencies: ["AIShellCore"]),
        .testTarget(name: "AIShellMCPTests", dependencies: ["AIShellMCP"])
    ]
)
