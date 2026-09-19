// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UserBox", platforms: [.macOS(.v13)],
    products: [
        .library(name: "UserBoxCore", targets: ["UserBoxCore"]),
        .executable(name: "UserBox", targets: ["UserBox"]),
        .executable(name: "UserBoxSession", targets: ["UserBoxSession"]),
        .executable(name: "userboxctl", targets: ["UserBoxCLI"])
    ],
    targets: [
        .target(name: "CUserBox", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Security", .when(platforms: [.macOS])),
                                 .linkedFramework("ApplicationServices", .when(platforms: [.macOS]))]),
        .target(name: "UserBoxCore", dependencies: ["CUserBox"]),
        .target(name: "UserBoxMac", dependencies: ["UserBoxCore", "CUserBox"]),
        .executableTarget(name: "UserBox", dependencies: ["UserBoxMac"]),
        .executableTarget(name: "UserBoxSession", dependencies: ["UserBoxMac"]),
        .executableTarget(name: "UserBoxCLI", dependencies: ["UserBoxCore"]),
        .testTarget(name: "UserBoxCoreTests", dependencies: ["UserBoxCore", "CUserBox"])
    ]
)
