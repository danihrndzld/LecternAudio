// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AudibleCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AudibleCore", targets: ["AudibleCore"])],
    targets: [
        .target(name: "AudibleCore", dependencies: ["CLAME"]),
        // LAME 3.100, LGPL; see Sources/CLAME/README.md.
        .target(
            name: "CLAME",
            exclude: ["COPYING", "LICENSE", "README.md"],
            cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .unsafeFlags(["-w"])],  // upstream code; its warnings are not ours to fix
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        .testTarget(name: "AudibleCoreTests", dependencies: ["AudibleCore"], resources: [.copy("Fixtures")]),
    ]
)
