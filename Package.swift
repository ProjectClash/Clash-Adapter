// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClashAdapter",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "ClashAdapter", targets: ["ClashAdapter"]),
    ],
    targets: [
        .target(name: "ClashAdapter", path: "Sources/ClashAdapter"),
    ]
)
