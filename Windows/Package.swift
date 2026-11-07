// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "OverlookCore", targets: ["OverlookCore"])
]

let dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "OverlookCore"),
    .testTarget(name: "OverlookCoreTests", dependencies: ["OverlookCore"])
]

products.append(.executable(name: "Overlook", targets: ["OverlookWinUI"]))

targets += [
    .target(
        name: "CNativeWin",
        publicHeadersPath: "include",
        cSettings: [
            .define("UNICODE", .when(platforms: [.windows])),
            .define("_UNICODE", .when(platforms: [.windows])),
            .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows])),
            .define("NOMINMAX", .when(platforms: [.windows]))
        ],
        linkerSettings: [
            .linkedLibrary("winhttp", .when(platforms: [.windows])),
            .linkedLibrary("crypt32", .when(platforms: [.windows])),
            .linkedLibrary("bcrypt", .when(platforms: [.windows])),
            .linkedLibrary("dxgi", .when(platforms: [.windows])),
            .linkedLibrary("gdiplus", .when(platforms: [.windows])),
            .linkedLibrary("dwmapi", .when(platforms: [.windows])),
            .linkedLibrary("comctl32", .when(platforms: [.windows])),
            .linkedLibrary("user32", .when(platforms: [.windows])),
            .linkedLibrary("gdi32", .when(platforms: [.windows])),
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows]))
        ]
    ),
    .executableTarget(
        name: "OverlookWinUI",
        dependencies: [
            "OverlookCore",
            "CNativeWin"
        ],
        linkerSettings: [
            .linkedLibrary("dwmapi", .when(platforms: [.windows])),
            .linkedLibrary("comctl32", .when(platforms: [.windows])),
            .linkedLibrary("user32", .when(platforms: [.windows])),
            .linkedLibrary("gdi32", .when(platforms: [.windows])),
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows]))
        ]
    )
]

let package = Package(
    name: "OverlookWindows",
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
