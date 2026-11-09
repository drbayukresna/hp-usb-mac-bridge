// swift-tools-version:5.9
//
// hp-usb-mac-bridge — macOS support for USB-only HP printers (HP Smart Tank 500 series and relatives)
// Copyright (C) 2026 hp-usb-mac-bridge contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "hp-usb-mac-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hpbridge", targets: ["hpbridge"]),
        .executable(name: "HPBridge", targets: ["HPBridgeApp"]),
        .library(name: "HPUSBBridge", targets: ["HPUSBBridge"]),
    ],
    targets: [
        .target(
            name: "HPUSBBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(name: "hpbridge", dependencies: ["HPUSBBridge"]),
        // The macOS app. Localizations and the icon live in AppBundle/ and are
        // copied into HP Bridge.app by scripts/build-app.sh.
        .executableTarget(
            name: "HPBridgeApp",
            dependencies: ["HPUSBBridge"],
            path: "Sources/HPBridgeApp",
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "HPUSBBridgeTests",
            dependencies: ["HPUSBBridge"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
