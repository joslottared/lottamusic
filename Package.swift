// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lotta",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool: exactly one library product = the app.
        .library(name: "Lotta", targets: ["Lotta"]),
    ],
    targets: [
        .target(name: "Lotta"),
    ],
    swiftLanguageModes: [.v5]
)
