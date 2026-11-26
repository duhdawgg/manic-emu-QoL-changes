// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "CollectionViewPagingLayout",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "CollectionViewPagingLayout",
            targets: ["CollectionViewPagingLayout"])
    ],
    targets: [
        .target(
            name: "CollectionViewPagingLayout",
            path: "Lib")
    ]
)
