// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "UserBox", platforms: [.macOS(.v14)],
    products: [.executable(name: "userbox", targets: ["UserBox"]), .library(name: "UserBoxCore", targets: ["UserBoxCore"])],
    targets: [.target(name: "UserBoxCore"), .executableTarget(name: "UserBox", dependencies: ["UserBoxCore"]),
              .testTarget(name: "UserBoxCoreTests", dependencies: ["UserBoxCore"])])
