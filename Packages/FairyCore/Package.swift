// swift-tools-version: 6.2
import PackageDescription

// 平台声明是构建下限，不是产品部署目标。产品部署目标 iOS 27.0 在 Config/Base.xcconfig 中设定；
// 当前环境（iOS 26.2 SDK）只能做验证构建，见 docs/ENVIRONMENT.md。macOS 仅用于跨平台单测与差分测试 CLI。
let package = Package(
    name: "FairyCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "RuntimeContracts", targets: ["RuntimeContracts"]),
        .library(name: "SwiftRuntime", targets: ["SwiftRuntime"]),
        .library(name: "NativeBridge", targets: ["NativeBridge"]),
        .library(name: "FoundationAI", targets: ["FoundationAI"]),
        // W1：项目契约（共享，冻结）与项目存储（.mojoproject 文档包、ProjectStore、ProjectLibrary、ZIP 导入导出）。
        .library(name: "ProjectContracts", targets: ["ProjectContracts"]),
        .library(name: "ProjectCore", targets: ["ProjectCore"]),
        // M0-B：夹具引擎，仅供测试目标与 Verify-Debug 构建链接，Release 绝不链接（见 docs/progress/M0-B.md）。
        .library(name: "DevFixtures", targets: ["DevFixtures"]),
        .executable(name: "fairy-run", targets: ["fairy-run"]),
    ],
    dependencies: [
        // 锁定版本以 `swift package resolve` 实测为准，记录在 docs/DEPENDENCIES.md。
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
    ],
    targets: [
        .target(name: "RuntimeContracts"),
        .target(name: "SwiftRuntime", dependencies: [
            "RuntimeContracts",
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
            // SwiftOperators：把 SequenceExpr 按标准运算符优先级折叠；SwiftParserDiagnostics：把语法错误转为诊断。
            .product(name: "SwiftOperators", package: "swift-syntax"),
            .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        ]),
        .target(name: "NativeBridge", dependencies: ["RuntimeContracts"]),
        .target(name: "FoundationAI", dependencies: ["RuntimeContracts", "ProjectContracts"]),
        .target(name: "ProjectContracts", dependencies: ["RuntimeContracts"]),
        .target(name: "ProjectCore", dependencies: ["ProjectContracts", "RuntimeContracts"]),
        .target(name: "DevFixtures", dependencies: ["RuntimeContracts"]),
        .executableTarget(name: "fairy-run", dependencies: ["SwiftRuntime", "RuntimeContracts"]),
        .testTarget(name: "RuntimeContractsTests", dependencies: ["RuntimeContracts"]),
        .testTarget(name: "SwiftRuntimeTests", dependencies: ["SwiftRuntime", "RuntimeContracts"], resources: [.copy("Fixtures")]),
        .testTarget(name: "NativeBridgeTests", dependencies: ["NativeBridge", "RuntimeContracts"]),
        .testTarget(name: "FoundationAITests", dependencies: ["FoundationAI", "ProjectContracts", "RuntimeContracts"]),
        .testTarget(name: "ProjectContractsTests", dependencies: ["ProjectContracts", "RuntimeContracts"]),
        .testTarget(name: "ProjectCoreTests", dependencies: ["ProjectCore", "ProjectContracts", "RuntimeContracts", "SwiftRuntime"]),
    ],
    swiftLanguageModes: [.v6]
)
