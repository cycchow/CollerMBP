// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CoolerMBP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CoolerShared", targets: ["CoolerShared"]),
        .library(name: "CoolerSMC", targets: ["CoolerSMC"]),
        .executable(name: "CoolerDaemon", targets: ["CoolerDaemon"]),
        .executable(name: "CoolerApp", targets: ["CoolerApp"]),
        .executable(name: "coolermbpctl", targets: ["CoolerCLI"]),
        .executable(name: "coolermbpsmc", targets: ["CoolerSMCTool"])
    ],
    targets: [
        .target(name: "CoolerShared"),
        .target(
            name: "CoolerSMC",
            dependencies: ["CoolerShared"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "CoolerDaemon",
            dependencies: ["CoolerShared", "CoolerSMC"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "CoolerApp",
            dependencies: ["CoolerShared"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CoolerCLI",
            dependencies: ["CoolerShared"]
        ),
        .executableTarget(
            name: "CoolerSMCTool",
            dependencies: ["CoolerShared", "CoolerSMC"]
        ),
        .testTarget(
            name: "CoolerSharedTests",
            dependencies: ["CoolerShared"]
        ),
        .testTarget(
            name: "CoolerSMCTests",
            dependencies: ["CoolerSMC"]
        )
    ]
)
