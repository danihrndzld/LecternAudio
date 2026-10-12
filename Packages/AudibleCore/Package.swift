// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AudibleCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AudibleCore", targets: ["AudibleCore"])],
    // SHA-256 and RSA signing on Linux too (CryptoKit is Apple-only).
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2")],
    targets: [
        .target(name: "AudibleCore", dependencies: [
            "CLAME",
            "CVorbis",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
        ]),
        // LAME 3.100, LGPL; see Sources/CLAME/README.md.
        .target(
            name: "CLAME",
            exclude: ["COPYING", "LICENSE", "README.md"],
            cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .unsafeFlags(["-w"])],  // upstream code; its warnings are not ours to fix
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        // libogg 1.3.6 and libvorbis 1.3.7, BSD-3; see Sources/COgg/README.md and Sources/CVorbis/README.md.
        .target(name: "COgg", exclude: ["COPYING", "README.md"], cSettings: [.unsafeFlags(["-w"])]),
        .target(
            name: "CVorbis",
            dependencies: ["COgg"],
            exclude: ["COPYING", "README.md"],
            cSettings: [.define("HAVE_ALLOCA_H"), .headerSearchPath("lib"), .unsafeFlags(["-w"])],
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        .testTarget(name: "AudibleCoreTests", dependencies: ["AudibleCore"], resources: [.copy("Fixtures")]),
    ]
)
