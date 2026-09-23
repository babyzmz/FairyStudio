# 依赖清单

核验日期：2026-09-23。只列实际使用的依赖；新增依赖必须先更新本文件。

## 随 App 分发的依赖

| 依赖 | 版本（锁定） | 许可 | 用途 | 核验方式 |
|---|---|---|---|---|
| swift-syntax（swiftlang/swift-syntax） | 603.0.2（revision 79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1，`exact:`） | Apache License 2.0 + Runtime Library Exception | SwiftRuntime 解析用户源码（SwiftParser / SwiftSyntax） | `Packages/FairyCore/Package.resolved`；checkout 中 `LICENSE.txt` 首行为 Apache License 2.0，第 205 行为 Runtime Library Exception |

说明：
- swift-syntax 由 SwiftRuntime 目标依赖，App 链接 SwiftRuntime 产品，因此随 App 分发。发布前需在 App 内「致谢/许可」页附上 Apache 2.0 许可文本（M7）。
- 切换到 Xcode 27 / Swift 6.4 后需重新核对锁定版本（可能升到 604.x），见 docs/ENVIRONMENT.md。

## 仅构建期使用（不随 App 分发）

| 工具 | 版本 | 许可 | 用途 | 核验方式 |
|---|---|---|---|---|
| XcodeGen | 2.46.0（Homebrew，`/opt/homebrew/bin/xcodegen`） | MIT | 由 `project.yml` 生成 `FairyStudio.xcodeproj` | `xcodegen --version`；`/opt/homebrew/Cellar/xcodegen/2.46.0/LICENSE` |

## 系统框架（Apple SDK，非第三方）

SwiftUI、UIKit、Foundation、Observation、Synchronization、FoundationModels（iOS 26.2 SDK）。

## 明确不使用

- 无第三方生成式模型 SDK、无网络客户端库、无分析/广告 SDK。
- FoundationAI 目标内禁止 URLSession / URLRequest / 外部端点，由 `Packages/FairyCore/Tests/FoundationAITests/NetworkAuditTests.swift` 做源码审计（项目自定义审计，不是 Apple API）。
