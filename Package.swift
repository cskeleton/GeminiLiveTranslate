// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeminiLiveTranslate",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "GeminiLiveTranslate",
            path: "Sources/GeminiLiveTranslate",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
