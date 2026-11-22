// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchBarCockpit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TouchBarCockpit", targets: ["TouchBarCockpit"])
    ],
    targets: [
        .target(
            name: "CPrivateAPIs",
            path: "Sources/CPrivateAPIs",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "TouchBarCockpit",
            dependencies: ["CPrivateAPIs"],
            path: "Sources/TouchBarCockpit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
