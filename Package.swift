// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MinaSCP", platforms: [.macOS(.v14)], products: [.executable(name: "MinaSCP", targets: ["MinaSCP"])], targets: [.executableTarget(name: "MinaSCP"), .executableTarget(name: "MinaSCPAskPass"), .testTarget(name: "MinaSCPTests", dependencies: ["MinaSCP"])])
