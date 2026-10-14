// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Sideport", platforms: [.macOS(.v15)],
  products: [.executable(name: "Sideport", targets: ["Sideport"])],
  dependencies: [
    .package(url: "https://github.com/openclaw/Peekaboo.git", exact: "4.9.1")
  ],
  targets: [
    .executableTarget(
      name: "Sideport",
      dependencies: [
        .product(name: "PeekabooAutomationKit", package: "Peekaboo"),
        .product(name: "PeekabooProtocols", package: "Peekaboo"),
      ], path: "Sources/Sideport")
  ], swiftLanguageModes: [.v5])
