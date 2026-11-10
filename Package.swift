// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRLaTeX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OCRLaTeX",
            path: "Sources/OCRLaTeX",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
