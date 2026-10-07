// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QuantumAuxBridgeCore", products: [.library(name: "QuantumAuxBridgeCore", targets: ["QuantumAuxBridgeCore"])], targets: [
    .target(name: "QuantumAuxBridgeCore", path: "Sources", exclude: ["BridgeHost.swift", "QuantumAuxBridgeApp.swift"], sources: ["BridgeCore.swift", "OSC.swift", "HTTP.swift"]),
    .testTarget(name: "QuantumAuxBridgeCoreTests", dependencies: ["QuantumAuxBridgeCore"], path: "Tests")
])
