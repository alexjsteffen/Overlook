// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "OverlookCore", targets: ["OverlookCore"])]
var targets: [Target] = [
    .target(name: "OverlookCore"),
    .testTarget(name: "OverlookCoreTests", dependencies: ["OverlookCore"])
]
#if os(Linux)
products.append(.executable(name: "overlook", targets: ["OverlookGTK"]))
targets += [
    .systemLibrary(name: "CDesktop", pkgConfig: "webkitgtk-6.0", providers: [
        .apt(["libgtk-4-dev", "libwebkitgtk-6.0-dev"])
    ]),
    // Supplies libadwaita compiler/linker flags; its helpers live in CDesktop/adw.h.
    .systemLibrary(name: "CAdwaita", pkgConfig: "libadwaita-1", providers: [.apt(["libadwaita-1-dev"])]),
    .systemLibrary(name: "CGStreamer", pkgConfig: "gstreamer-webrtc-1.0", providers: [.apt(["libgstreamer-plugins-bad1.0-dev"])]),
    .systemLibrary(name: "CGstApp", pkgConfig: "gstreamer-app-1.0", providers: [.apt(["libgstreamer-plugins-base1.0-dev"])]),
    .systemLibrary(name: "CGstVideo", pkgConfig: "gstreamer-video-1.0"),
    .target(name: "CNative", dependencies: ["CDesktop", "CGStreamer", "CGstApp", "CGstVideo"],
            linkerSettings: [.linkedLibrary("gstsdp-1.0")]),
    .executableTarget(name: "OverlookGTK", dependencies: ["CAdwaita", "CDesktop", "CNative", "OverlookCore"])
]
#endif
let package = Package(name: "OverlookLinux", products: products, targets: targets,
                      swiftLanguageModes: [.v5])
