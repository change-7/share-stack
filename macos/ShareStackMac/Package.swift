// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ShareStackMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ShareStackMac", targets: ["ShareStackMac"])],
    targets: [.executableTarget(name: "ShareStackMac")]
)
