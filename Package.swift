// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "MinaSCP", platforms: [.macOS(.v14)], products: [.executable(name: "MinaSCP", targets: ["MinaSCP"])], dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")], targets: [.executableTarget(name: "MinaSCP", dependencies: [.product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]), .executableTarget(name: "MinaSCPAskPass"), .testTarget(name: "MinaSCPTests", dependencies: ["MinaSCP"])])
