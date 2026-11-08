// swift-tools-version:6.0
//
// The Libretto engine for the web: the shared engine package (../../../Engine)
// built for WebAssembly behind a small C interface, plus the tool that turns
// string catalogues into the JSON the web app loads. Built by Web/build.sh.
//
// Requires the swift.org toolchain and its matching Swift SDK for WebAssembly
// (see Web/README.md).

import PackageDescription

let package = Package(
    name: "LibrettoWeb",
    // The strings tool runs on the Mac doing the build.
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LibrettoWasm", targets: ["LibrettoWasm"]),
        .executable(name: "strings-tool", targets: ["StringsTool"]),
    ],
    dependencies: [
        .package(path: "../../../Engine"),
    ],
    targets: [
        .executableTarget(
            name: "LibrettoWasm",
            dependencies: [
                .product(name: "LibrettoEngine", package: "Engine"),
            ],
            linkerSettings: [
                // A reactor: no main entry point, just the exported functions.
                .unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"]),
                // Reading a deeply nested document recurses; give it room.
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=8388608"]),
            ]
        ),
        .executableTarget(name: "StringsTool"),
    ]
)
