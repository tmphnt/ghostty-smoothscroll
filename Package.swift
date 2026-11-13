// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ghostty-smoothscroll",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ghostty-smoothscroll", path: "Sources/ghostty-smoothscroll")
    ]
)
