// swift-tools-version:5.9
import PackageDescription

// SmartMenuCore holds the homes, scenes and device drivers, with no UI, so it builds and tests anywhere Swift runs.
// The SwiftUI app for iPhone and Mac is in App/ (App/project.yml, made into an Xcode project with XcodeGen).
let package = Package(
    name: "SmartMenuCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "SmartMenuCore", targets: ["SmartMenuCore"])],
    targets: [
        .target(name: "SmartMenuCore"),
        .testTarget(name: "SmartMenuCoreTests", dependencies: ["SmartMenuCore"]),
    ]
)
