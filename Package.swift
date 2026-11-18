// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EmbyAPI",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16)],
    products: [.library(name: "EmbyAPI", targets: ["EmbyAPI"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "EmbyAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .testTarget(
            name: "EmbyAPITests",
            dependencies: [
                "EmbyAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
