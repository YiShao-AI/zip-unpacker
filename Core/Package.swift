// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnpackCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "UnpackCore", targets: ["UnpackCore"])],
    targets: [
        // 7-Zip 26.05: 7z, RAR 4/5, tar, gz, bz2, xz, zstd, lzma, iso, cab… plus zip methods the
        // built-in reader doesn't have. See Sources/SevenZip/README-Unpacker.md.
        .target(
            name: "SevenZip",
            exclude: ["DOC", "SOURCES.txt", "README-Unpacker.md"],
            cSettings: [
                .define("NDEBUG"), .define("_REENTRANT"), .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"), .define("Z7_EXTERNAL_CODECS"),
            ],
            cxxSettings: [
                .define("NDEBUG"), .define("_REENTRANT"), .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"), .define("Z7_EXTERNAL_CODECS"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(name: "UnpackCore", dependencies: ["SevenZip"]),
        .testTarget(
            name: "UnpackCoreTests",
            dependencies: ["UnpackCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx17
)
