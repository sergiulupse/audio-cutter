// swift-tools-version: 5.10
//
// Audio-Cutter: a minimal native macOS audio cutter.
//
// This file tells Swift how to build the project. There are no external
// dependencies on purpose: everything is built on Apple's own AVFoundation
// and SwiftUI, so the project compiles offline and will not rot when some
// third-party library goes unmaintained.

import PackageDescription

let package = Package(
    name: "AudioCutter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // swift-tools-version above is 5.10, which means this target builds in
        // Swift 5 language mode. That is deliberate: Swift 6's strict
        // concurrency checking would demand a lot of ceremony for an app that
        // does all of its UI work on one thread anyway.
        .executableTarget(
            name: "AudioCutter",
            path: "Sources/AudioCutter"
        )
    ]
)
