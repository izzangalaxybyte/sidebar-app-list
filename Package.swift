// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidebarAppList",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SidebarAppList",
            path: "Sources/SidebarAppList"
        )
    ]
)
