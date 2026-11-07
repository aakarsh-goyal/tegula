// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tegula",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Tegula", path: "Sources/Tegula")
    ]
)
