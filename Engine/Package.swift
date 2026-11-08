// swift-tools-version:6.0
//
// The Libretto engine: the document model and reading and writing every file
// format, with page layout and drawing on Apple platforms. Shared by the Apple
// apps (whose Xcode project compiles this folder directly) and the web app
// (Web/engine, which depends on this package and builds it for WebAssembly).

import PackageDescription

let package = Package(
    name: "LibrettoEngine",
    products: [
        .library(name: "LibrettoEngine", targets: ["LibrettoEngine"]),
    ],
    targets: [
        .target(
            name: "LibrettoEngine",
            path: "LibrettoEngine",
            // Compiled into the Apple framework by Xcode; the web app loads
            // the same strings as JSON instead.
            exclude: ["Localizable.xcstrings"]
        ),
    ]
)
