// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "USBConnection",
    platforms: [.macOS(.v15)],
    products: [.library(name: "USBConnection", targets: ["USBConnection"])],
    targets: [
        .target(
            name: "USBConnection",
            swiftSettings: [
                // Enable compile-time logging flag by default in Debug builds.
                // Downstream packages can override by defining/omitting USBCONNECTION_LOGGING.
                .define("USBCONNECTION_LOGGING", .when(configuration: .debug))
            ]
        )
    ]
)
