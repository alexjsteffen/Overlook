// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "OverlookCore", targets: ["OverlookCore"])
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "OverlookCore"),
    .testTarget(name: "OverlookCoreTests", dependencies: ["OverlookCore"])
]

#if os(Windows)
products.append(.executable(name: "Overlook", targets: ["OverlookWinUI"]))

dependencies += [
    .package(url: "https://github.com/thebrowsercompany/swift-winui", branch: "main"),
    .package(url: "https://github.com/thebrowsercompany/swift-windowsappsdk", branch: "main"),
    .package(url: "https://github.com/thebrowsercompany/swift-uwp", branch: "main"),
    .package(url: "https://github.com/thebrowsercompany/swift-windowsfoundation", branch: "main")
]

targets += [
    .target(
        name: "CNativeWin",
        publicHeadersPath: "include",
        cSettings: [
            .define("UNICODE"),
            .define("_UNICODE"),
            .define("WIN32_LEAN_AND_MEAN"),
            .define("NOMINMAX")
        ],
        linkerSettings: [
            .linkedLibrary("winhttp"),
            .linkedLibrary("crypt32"),
            .linkedLibrary("bcrypt"),
            .linkedLibrary("dxgi"),
            .linkedLibrary("gdiplus"),
            .linkedLibrary("user32"),
            .linkedLibrary("gdi32"),
            .linkedLibrary("advapi32"),
            .linkedLibrary("ole32"),
            .linkedLibrary("shell32")
        ]
    ),
    .executableTarget(
        name: "OverlookWinUI",
        dependencies: [
            "OverlookCore",
            "CNativeWin",
            .product(name: "WinUI", package: "swift-winui"),
            .product(name: "WinAppSDK", package: "swift-windowsappsdk"),
            .product(name: "UWP", package: "swift-uwp"),
            .product(name: "WindowsFoundation", package: "swift-windowsfoundation")
        ],
        swiftSettings: [
            .interoperabilityMode(.Cxx)
        ],
        linkerSettings: [
            .linkedLibrary("user32"),
            .linkedLibrary("advapi32"),
            .linkedLibrary("ole32"),
            .linkedLibrary("shell32")
        ]
    )
]
#endif

let package = Package(
    name: "OverlookWindows",
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
