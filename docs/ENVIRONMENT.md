# 开发环境记录（核验日期 2026-09-23）

## 实测工具链
| 项目 | 实测值 |
|---|---|
| macOS（宿主机） | 15.7.4 (24G517) |
| Xcode | 26.3 (17C529)，路径 /Applications/Xcode.app，本机唯一 Xcode |
| Swift | 6.2.4 (swiftlang-6.2.4.1.4)，swift-tools-version 默认 6.2 |
| iOS SDK | **iOS 26.2 / iOS Simulator 26.2**（无 iOS 27 SDK） |
| 模拟器运行时 | iOS 26.3 (26.3.1 - 23D8133) |
| 可用模拟器 | iPhone 17 Pro / Pro Max / Air / 17 / 16e；iPad Pro 13/11 (M5)、iPad mini (A17 Pro)、iPad (A16)、iPad Air 13/11 (M3) |
| 已配对实机 | iPhone 16 Pro Max (iPhone17,2)，**iOS 27.0 (24A437)**，Developer Mode 已开启，`ddiServicesAvailable: false` |
| 未配对/不可用实机 | iPad Pro 11-inch (M5)、iPad Pro 12.9 (6th gen)（状态 unavailable） |
| 签名身份 | 2 个 Apple Development 身份（Team 66F6479Y4Q、726834KAPQ）；本机无 provisioning profile |
| XcodeGen | /opt/homebrew/bin/xcodegen（已安装，用于生成 .xcodeproj） |
| swift-syntax 远端标签 | 600.0.1 … 602.0.0, 603.0.0–603.0.2, 604.0.0（实际锁定版本以 `swift package resolve` 结果为准，记录在 docs/DEPENDENCIES.md） |
| FoundationModels (iOS 26.2 SDK) | 有 `SystemLanguageModel`、`LanguageModelSession`、`Tool`、`Generable`、`GenerationOptions`、`Transcript`；`Availability.UnavailableReason` = deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady；`GenerationError` = exceededContextWindowSize / assetsUnavailable / guardrailViolation / unsupportedGuide / unsupportedLanguageOrLocale / decodingFailure / rateLimited / concurrentRequests / refusal |
| PCC API | **iOS 26.2 SDK 中不存在 `PrivateCloudComputeLanguageModel` 符号** |

## 环境阻塞（外部条件，不能靠代码绕过）
1. **无 iOS 27 SDK**：产品部署目标固定为 iOS 27.0（写在 `Config/Base.xcconfig`）。当前环境只能用 `Config/Verify-iOS26.xcconfig` 做 *验证构建*（临时把部署目标降到 26.2 以在 26.3 模拟器上运行）。验证构建的结果只能标记为"已实现待 iOS 27 环境复验"，不得标记为最终通过。
2. **PCC API 不在 SDK 中**：`PrivateCloudComputeLanguageModel` 相关代码以编译条件 `FAIRY_PCC_SDK` 隔离；当前构建中 PCC 后端固定返回"不可用：SDK 缺失"。PCC 资格（Small Business Program / 首次下载量门槛 / entitlement）需要开发者账号侧核对，未核对。
3. **宿主 macOS 15.7 不支持 Foundation Models**：macOS 端单测无法调用本地模型；模拟器上的 Foundation Models 需要 macOS 26 宿主。本地模型真实调用只能在 iPhone 16 Pro Max 实机进行。
4. **Xcode 26.3 无 iOS 27 DDI**：实机 `ddiServicesAvailable: false`，当前 Xcode 不能向 iOS 27.0 实机部署调试。需要 Xcode 27（大概率同时要求 macOS 26）。
5. **签名**：仅有个人开发身份，无 profile；模拟器构建不需要签名；实机构建需在 `Config/Signing.local.xcconfig`（gitignored）中填入 DEVELOPMENT_TEAM。

## 解除阻塞所需动作（需用户执行）
- Apple 官方 Xcode 支持页（2026-09-23 查询）：**Xcode 27 要求 macOS Tahoe 26.6 或更高**，自带 iOS 27 SDK，Swift 6.4 编译器，部署目标 iOS 17+。因此宿主机至少升级到 macOS 26.6（macOS 27 亦可，非必须），再安装 Xcode 27，然后重新执行 `scripts/verify-env.sh`。
- 切换到 Xcode 27 / Swift 6.4 后需重新核对 swift-syntax 锁定版本（可能升到 604.x）并跑全部回归。
- 在 Apple Developer 后台核对 PCC 资格与 entitlement，并把官方文档中的精确 entitlement 标识记入 `docs/APPLE_MODELS.md`。

## 各类验证结果的记录口径
- `macOS 单测`：SwiftRuntime / ProjectCore 等纯 Swift 包在宿主机 `swift test` 的结果。
- `模拟器 (iOS 26.3, 验证构建)`：使用 Verify-iOS26.xcconfig 的结果。
- `iPhone 实机 (iOS 27.0)`：当前被 DDI 阻塞。
- `iPad 实机`：当前无可用 iPad。
