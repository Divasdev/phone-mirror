// swift-tools-version:5.10
// Package.swift tells Swift Package Manager how to build the app.
// There are no third-party dependencies: only Apple frameworks are used.

import PackageDescription

let package = Package(
    name: "PhoneMirror",
    platforms: [
        .macOS(.v14) // MenuBarExtra + SMAppService need macOS 13+, we target 14+
    ],
    targets: [
        .executableTarget(
            name: "PhoneMirror",
            path: "Sources/PhoneMirror"
        ),
        // Checks that run on the Mac without a phone: `swift test`
        .testTarget(
            name: "PhoneMirrorTests",
            dependencies: ["PhoneMirror"],
            path: "Tests/PhoneMirrorTests",
            // Without Xcode, the compiler has to be told where the @Test macro lives.
            swiftSettings: [.unsafeFlags([
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])]
        )
    ]
)
