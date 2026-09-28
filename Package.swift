// swift-tools-version: 6.2
import PackageDescription
import Foundation
let discovery = Process(); let discoveryOutput = Pipe()
discovery.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun"); discovery.arguments = ["--find","swift"]; discovery.standardOutput = discoveryOutput
try discovery.run(); discovery.waitUntilExit()
let swiftPath = String(decoding:discoveryOutput.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
let root = URL(fileURLWithPath:swiftPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let frameworks = root.appendingPathComponent("Library/Developer/Frameworks").path
let libraries = root.appendingPathComponent("Library/Developer/usr/lib").path
let hasTesting = FileManager.default.fileExists(atPath:frameworks+"/Testing.framework")
let testingMacros = root.appendingPathComponent("usr/lib/swift/host/plugins/testing/libTestingMacros.dylib").path
let macroFlags = FileManager.default.fileExists(atPath:testingMacros) ? ["-load-plugin-library",testingMacros] : []
let testSwift:[SwiftSetting] = hasTesting ? [.unsafeFlags(["-F",frameworks] + macroFlags)] : []
let testLink:[LinkerSetting] = hasTesting ? [.unsafeFlags(["-F",frameworks,"-Xlinker","-rpath","-Xlinker",frameworks,"-Xlinker","-rpath","-Xlinker",libraries]),.linkedFramework("Testing")] : []
let package = Package(name: "CodexKonten", platforms: [.macOS(.v14)], products: [.library(name: "AccountCore", targets: ["AccountCore"]), .library(name: "UpdateSafety", targets: ["UpdateSafety"]), .executable(name: "CodexAccounts", targets: ["CodexAccounts"]), .executable(name: "CodexAccountsTool", targets: ["CodexAccountsTool"])], dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")], targets: [.target(name: "AccountCore"), .target(name: "UpdateSafety"), .executableTarget(name: "CodexAccounts", dependencies: ["AccountCore", "UpdateSafety", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]), .executableTarget(name: "CodexAccountsTool", dependencies: ["AccountCore"]), .testTarget(name: "AccountCoreTests", dependencies: ["AccountCore"],swiftSettings:testSwift,linkerSettings:testLink), .testTarget(name: "UpdateSafetyTests", dependencies: ["UpdateSafety"],swiftSettings:testSwift,linkerSettings:testLink)])
