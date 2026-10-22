// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Taskboard",
  platforms: [.macOS("26.0")],
  targets: [
    // Shared by the app and the MCP server: the board file, its model and locking.
    .target(name: "TaskboardCore"),
    .executableTarget(name: "Taskboard", dependencies: ["TaskboardCore"]),
    .executableTarget(name: "taskboard-mcp", dependencies: ["TaskboardCore"]),
    .testTarget(name: "TaskboardCoreTests", dependencies: ["TaskboardCore"]),
  ],
  swiftLanguageModes: [.v5]
)
