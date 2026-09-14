// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexFuelGauge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CodexFuelGauge", targets: ["CodexFuelGauge"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexFuelGauge",
            path: "Sources/CodexFuelGauge"
        ),
        .testTarget(
            name: "CodexFuelGaugeTests",
            dependencies: ["CodexFuelGauge"],
            path: "Tests/CodexFuelGaugeTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-load-plugin-library", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
