// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "bebop-vapor",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // Stellar Swift Wallet SDK
        .package(url: "https://github.com/Soneso/stellar-swift-wallet-sdk.git", exact: "0.6.0"),
        // Apple Push Notification Service
        .package(url: "https://github.com/swift-server-community/APNSwift.git", exact: "6.0.0"),
       // .package(url: "https://github.com/stellar-ios-mac-sdk.git", from: "3.0.7"),
    ],
    targets: [
        .executableTarget(
            name: "bebop-vapor",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "stellar-wallet-sdk", package: "stellar-swift-wallet-sdk"),
                .product(name: "APNS", package: "APNSwift"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "APNSURLSession", package: "APNSwift"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "bebop-vaporTests",
            dependencies: [
                .target(name: "bebop-vapor"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
