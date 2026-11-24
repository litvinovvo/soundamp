// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SoundAmp",
    platforms: [.macOS("14.2")], // Core Audio process taps need 14.2+
    targets: [
        // Real-time effects in C++: Signalsmith Stretch pitch shifter (MIT, vendored)
        // and a Dattorro plate reverb.
        .target(
            name: "DSPKit",
            path: "Sources/DSPKit",
            exclude: ["vendor/licenses", "vendor/README.txt"],
            cxxSettings: [
                .headerSearchPath("vendor"),
                .define("SIGNALSMITH_USE_ACCELERATE"),
                .unsafeFlags(["-O3"]),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // Pure logic: SoundCloud links, playlist, skins (.wsz), visualizers, DSP. Unit-tested.
        .target(
            name: "SoundAmpCore",
            dependencies: ["DSPKit"],
            path: "Sources/SoundAmpCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        // The macOS app: skinned windows, SoundCloud widget, Core Audio tap.
        .executableTarget(
            name: "SoundAmp",
            dependencies: ["SoundAmpCore"],
            path: "Sources/SoundAmp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "SoundAmpCoreTests",
            dependencies: ["SoundAmpCore"],
            path: "Tests/SoundAmpCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
