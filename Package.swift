// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "xcbrief",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xcbrief", targets: ["xcbrief"])
    ],
    targets: [
        .target(name: "XCBriefCore"),
        .executableTarget(name: "xcbrief", dependencies: ["XCBriefCore"]),
        .testTarget(
            name: "XCBriefCoreTests",
            dependencies: ["XCBriefCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
