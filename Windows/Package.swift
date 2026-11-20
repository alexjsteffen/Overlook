// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "OverlookCore", targets: ["OverlookCore"]),
    .executable(name: "Overlook", targets: ["OverlookWinUI"])
]

var targets: [Target] = [
    .target(name: "OverlookCore"),
    .testTarget(name: "OverlookCoreTests", dependencies: ["OverlookCore"]),
    .target(
        name: "CNativeWin",
        publicHeadersPath: "include",
        cSettings: [
            .define("UNICODE", .when(platforms: [.windows])),
            .define("_UNICODE", .when(platforms: [.windows])),
            .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows])),
            .define("NOMINMAX", .when(platforms: [.windows])),
            .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows])),
            .define("COBJMACROS", .when(platforms: [.windows])),
            .define("GST_USE_UNSTABLE_API", .when(platforms: [.windows]))
        ],
        linkerSettings: [
            .linkedLibrary("winhttp", .when(platforms: [.windows])),
            .linkedLibrary("crypt32", .when(platforms: [.windows])),
            .linkedLibrary("bcrypt", .when(platforms: [.windows])),
            .linkedLibrary("dxgi", .when(platforms: [.windows])),
            .linkedLibrary("dwmapi", .when(platforms: [.windows])),
            .linkedLibrary("comctl32", .when(platforms: [.windows])),
            .linkedLibrary("user32", .when(platforms: [.windows])),
            .linkedLibrary("gdi32", .when(platforms: [.windows])),
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows])),
            .linkedLibrary("gstreamer-1.0", .when(platforms: [.windows])),
            .linkedLibrary("gobject-2.0", .when(platforms: [.windows])),
            .linkedLibrary("glib-2.0", .when(platforms: [.windows])),
            .linkedLibrary("gstwebrtc-1.0", .when(platforms: [.windows])),
            .linkedLibrary("gstsdp-1.0", .when(platforms: [.windows])),
            .linkedLibrary("gstapp-1.0", .when(platforms: [.windows])),
            .linkedLibrary("gstvideo-1.0", .when(platforms: [.windows]))
        ]
    ),
    .executableTarget(
        name: "OverlookWinUI",
        dependencies: [
            "OverlookCore",
            "CNativeWin"
        ]
    )
]

let package = Package(
    name: "OverlookWindows",
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
