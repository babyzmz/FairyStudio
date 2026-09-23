# M0-B 进度：App 工程 + NativeBridge + FoundationAI

- 当前阶段：**M0-B 交付完成，等待 M0-C 集成**（验证构建口径：模拟器 iOS 26.3，结果只能记为「已实现待 iOS 27 环境复验」）
- 最后更新：2026-09-24
- 环境：macOS 15.7.4 / Xcode 26.3 (17C529) / Swift 6.2.4 / iOS 26.2 SDK / iOS 26.3 模拟器 / XcodeGen 2.46.0

## ⚠️ 合并注意

1. **Package.swift 改动仅为新增 DevFixtures target，主代理合并时需保留。** 片段见 docs/CONTRACT_REQUESTS.md B-1（一个 `.library(name: "DevFixtures", …)` 产品 + 一个 `.target(name: "DevFixtures", dependencies: ["RuntimeContracts"])`）。
2. DerivedData **不能放在 ~/Desktop 下**：iCloud / 文件提供者扩展属性会让 codesign 报 `resource fork, Finder information, or similar detritus not allowed`（已实测）。脚本默认用 `~/Library/Developer/Xcode/DerivedData/FairyStudio-verify`。
3. 仓库根 `build/` 已在 .gitignore；`verification/logs/*.log` 不入库，本文件摘录了关键输出。

## 交付物与所在位置

| 项 | 位置 |
|---|---|
| XcodeGen 工程 | `project.yml` → `FairyStudio.xcodeproj`（生成物一并提交）；schemes `FairyStudio`（Debug/Release，Base.xcconfig，iOS 27.0）与 `FairyStudio-Verify`（Verify-Debug/Verify-Release，Verify-iOS26.xcconfig） |
| 测试目标配置 | `Tests/Config/Tests.xcconfig`、`Tests/Config/Tests-Verify.xcconfig`（include Config/ 下的 xcconfig，只改产品名/Bundle ID，前缀取自 Brand） |
| Info.plist | 由 project.yml 生成 `App/Info.plist`：无任何 `*UsageDescription` |
| 脚本 | `scripts/verify-env.sh`、`scripts/build-verify.sh`、`scripts/check-release-link.sh` |
| NativeBridge | `Packages/FairyCore/Sources/NativeBridge/`（RenderTreeView、BridgeCatalog、ModifierChain、Components/*） |
| FoundationAI | `Packages/FairyCore/Sources/FoundationAI/`（ModelBroker、OnDeviceModelDriver、PrivateCloudComputeDriver、CloudConsentStore、StatusMapping、ModelTypes） |
| DevFixtures | `Packages/FairyCore/Sources/DevFixtures/`（FixtureEngine：counter / form / unsupported / budgetExceeded / gallery） |
| App | `App/`：`Runtime/RunCoordinator.swift`、`Runtime/EngineCatalog.swift`、`Runtime/StudioModel.swift`、`Views/*`、`AI/*` |
| 测试 | `Packages/FairyCore/Tests/{NativeBridgeTests,FoundationAITests}`、`Tests/FairyStudioTests`、`Tests/FairyStudioUITests` |
| 文档 | `docs/APPLE_MODELS.md`、`docs/DEPENDENCIES.md`、`docs/CONTRACT_REQUESTS.md`（M0-B 段） |

## 关键设计决定（续跑必读）

- **DevFixtures 只进 Verify-Debug**：project.yml 中以 `link: false` 作为构建依赖（保证模块被编译、可 import），仅 `Verify-Debug` 配置 `OTHER_LDFLAGS += $(BUILT_PRODUCTS_DIR)/DevFixtures.o`；App 源码中的 `import DevFixtures` 与夹具分支都在 `#if FAIRY_VERIFY_BUILD && DEBUG` 内。测试包由 App 宿主加载（TEST_HOST/BUNDLE_LOADER），不重复链接。
- **夹具横幅**放在每个页签内容的 VStack 顶部。最初用挂在 TabView 上的 `safeAreaInset`，在 iOS 26 模拟器截图中实测会**遮住运行/停止工具条**，已改；UI 测试断言横幅底边不低于运行按钮顶边。
- **TextField**：iOS 用 `UITextField`（`BridgeTextFieldController`，闭包式 `UIAction`，无 selector）+ 平台无关的 `TextBufferReconciler`：组字中不回传、不覆盖；同一运行时文本重复下发不触碰 text/光标；迟到回声不覆盖新输入；运行时主动改写才写入并夹住光标。
- **RunCoordinator**：所有 run/stop/换引擎操作串行；重新运行先 `await performStop()`；输入经单一 AsyncStream 队列按 sequence 送达；stop 后最多等 1 s 让事件流排空，超时记 internalError 诊断；引擎未报告终态时以 `stop()` 返回为准记为 stopped（并在控制台注明）。
- **正式引擎路径**：`PendingSwiftRuntimeEngine` 如实报告「SwiftRuntime 尚未接入（M0-C）」→ 状态 failed，不伪造运行。M0-C 在 `App/Runtime/EngineCatalog.swift` 的 `.swiftRuntime` 分支换成 SwiftRuntime 的引擎。
- **PCC**：`#if FAIRY_PCC_SDK` 下是 `#error`（防止编造 API）；未定义时固定 `.pccSDKMissing`。

## 已验证（命令与关键输出）

见文末「最终回归（2026-09-24）」。

### 其他实测

- `xcodebuild -scheme FairyStudio-Verify -showdestinations`：`iPhone 17 Pro`（id 4643FD35-…，OS 26.3.1）、`iPad Pro 11-inch (M5)`（id 11FB3503-…，OS 26.3.1）等 11 台模拟器；另有已配对 iPhone（iOS 27.0）。
- `xcodebuild -scheme FairyStudio -showdestinations`（产品配置，部署目标 27.0）：**无任何模拟器目的地**（全部为 26.3），只有 Any iOS Device / Any iOS Simulator Device。
- 产品配置 Release 以 `generic/platform=iOS Simulator` 构建：`** BUILD SUCCEEDED **`，带警告 `The iOS Simulator deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 27.0, but the range of supported deployment target versions is 12.0 to 26.2.99.`
- 深色模式 + Dynamic Type `accessibility-large`（`xcrun simctl ui <iPhone 17 Pro> appearance dark` / `content_size accessibility-large`）下全部 6 个 UI 测试通过（AI 测试在修复懒加载滚动后单独重跑通过）；截图核对：横幅不遮挡工具条、工具条在大字号下切换为纯图标、无溢出。日志：`verification/logs/20260924-dark-axlarge-iPhone-17-Pro-ui.log`。测试后已恢复 light / large。
- `scripts/verify-env.sh` → `verification/env-2026-09-23.log`。与 docs/ENVIRONMENT.md 的差异：iPad Pro 11-inch (M5) 现为 `pairing=paired`、iOS 27.0（build 24A5408d）、`tunnel=unavailable`、`ddiServicesAvailable=False`（仍不可部署）。设备名已脱敏。

### Foundation Models 可用性真实返回值

| 环境 | 原样值 | 映射 |
|---|---|---|
| macOS 15.7.4 宿主 `swift test` | `#available(macOS 26)` 为假，未调用框架 | `systemError("系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用")` |
| iOS 26.3 模拟器 iPhone 17 Pro（宿主 macOS 15.7.4） | `availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true` | `modelNotReady` |
| iOS 26.3 模拟器 iPad Pro 11-inch (M5) | 同上（见最终回归日志） | `modelNotReady` |
| PCC（全部环境） | SDK 无符号 | `pccSDKMissing` |

UI 层：`[FAIRY-AVAILABILITY-UI] onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用`，发送按钮禁用并显示原因。

## 三档状态

### 已实现并验证（模拟器验证构建口径 / macOS 单测口径）
- XcodeGen 工程、两个 scheme、Brand 取名、生成 Info.plist；Verify-Debug 在 iPhone 17 Pro 与 iPad Pro 11-inch (M5) 模拟器 build + test。
- DevFixtures 仅链接进 Verify-Debug（`scripts/check-release-link.sh`，含正向对照）。
- NativeBridge：27 个 RenderKind、24 个 RenderModifier 全映射（穷举 switch + Mirror 名称校验 + 集合相等）；macOS NSHostingView 冒烟渲染每种 kind / 全部 modifier / 非法参数；列表以 NodeID 为身份。
- TextField 本地编辑缓冲：macOS 纯逻辑测试 + iOS UIKit 测试（光标不动、marked text 不被打断、迟到回声）+ UI 测试（中文分两批输入不丢字、不颠倒，其他控件引起的 revision 更新不影响输入框）。
- Button→action、Toggle/Slider/TextField→setBinding、Sheet 打开/关闭（dismiss action）、Alert 按钮 action、NavigationLink→navigationPush、返回→navigationPop、unsupported 可见占位：UI 测试逐项通过（gallery / form / counter / unsupported）。
- RunCoordinator：丢弃旧 RunID、sequence 倒退、revision 倒退；重新运行先 stop 后 start（记录顺序）；30 次 run/stop 与 30 次直接重跑后夹具实例计数分别为 0 / 1→0；budgetExceeded→interrupted；⌘R / ⌘. 快捷键已绑定（未做硬件键盘自动化测试）。
- ModelBroker：每任务检测、单在途 busy、取消（显式与调用方取消）、云端确认、禁止静默回退、PCC 固定 pccSDKMissing；GenerationError 9 个 case 在 iOS 运行时用真实 SDK 值逐一映射；网络审计 + 导入白名单。
- AI 状态页三态 + 原因 + 重新检测 + prompt（不可用时禁用发送，无假响应），真实可用性已记录。
- 深色模式 / accessibility-large 下 UI 测试与截图核对。

### 已实现待实机 / 待 iOS 27 环境
- 设备端模型**真实成功调用**（流式、取消、实际后端名显示）：需 iPhone 16 Pro Max + Xcode 27（macOS 26.6+），或 macOS 26 宿主上的模拟器。
- 产品配置（iOS 27.0）的运行与测试：当前无 iOS 27 SDK / 模拟器，只验证了能以 generic 目的地编译。
- ⌘R / ⌘. 在 iPad 硬件键盘上的实际触发。

### 未实现 / 受阻
- PCC 后端：SDK 缺失 + 资格与 entitlement 未核对（docs/APPLE_MODELS.md §5 清单）。
- SwiftRuntime 接入 App（M0-C）。
- 能力请求（capabilityRequest）只做了如实拒绝，CapabilityKit 属 M2。
- 源码编辑器仍为 TextEditor（M1 换 TextKit 2）。

## 下一步（M0-C）
1. 合并 Package.swift 时保留 DevFixtures 两行；主代理裁决 CONTRACT_REQUESTS B-2…B-7。
2. `EngineCatalog.swift` 的 `.swiftRuntime` 换成 SwiftRuntime 的 `RuntimeEngine`；删除 `PendingSwiftRuntimeEngine`。
3. 端到端：用示例两文件在模拟器跑计数器（UI 测试可复用 `testCounterRunIncrementStop`，去掉 `-fairy.engine` 参数）。
4. 移除夹具：见 CONTRACT_REQUESTS B-1 的移除清单；再跑 `scripts/check-release-link.sh`（届时改为断言所有配置都不含）。

## 最终回归（2026-09-24）

### macOS `swift test`（Packages/FairyCore，宿主 macOS 15.7.4）
```
$ cd Packages/FairyCore && swift test
[FoundationAITests] 宿主 OnDevice availability = systemError (系统错误：系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用); raw = 系统版本低于 26
✔ Test run with 35 tests in 6 suites passed after 0.659 seconds.
```
（NativeBridgeTests 16 个测试 / 3 个 suite，其中「每种 RenderKind 单独渲染」为 27 个参数化用例；FoundationAITests 19 个测试 / 3 个 suite，其中 GenerationError 映射为 9 个参数化用例。SwiftRuntimeTests / RuntimeContractsTests 仍为占位，0 个测试。）

### `scripts/build-verify.sh`（FairyStudio-Verify，Verify-Debug）
日志：`verification/logs/20260924-001207-*.log`（不入库）
```
== platform=iOS Simulator,name=iPhone 17 Pro
exit=0
** BUILD SUCCEEDED **
** TEST SUCCEEDED **
✔ Test run with 19 tests in 4 suites passed        # FairyStudioTests（Swift Testing）
Executed 6 tests, with 0 failures (0 unexpected)    # FairyStudioUITests
  testAIStatusReportsRealAvailability / testChineseTextInputKeepsEveryCharacter / testCounterRunIncrementStop /
  testFormToggleAndReorder / testGalleryPresentationAndNavigation / testUnsupportedNodeIsVisible  passed
[FAIRY-AVAILABILITY-UI] onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用
[FAIRY-AVAILABILITY] mapped=modelNotReady … raw=availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true

== platform=iOS Simulator,name=iPad Pro 11-inch (M5)
exit=0
** BUILD SUCCEEDED **
** TEST SUCCEEDED **
✔ Test run with 19 tests in 4 suites passed
Executed 6 tests, with 0 failures (0 unexpected)     # 同上 6 个 UI 测试全部 passed
[FAIRY-AVAILABILITY-UI] onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用
[FAIRY-AVAILABILITY] mapped=modelNotReady …（原样值同 iPhone）
overall_exit=0
```
过程中修复过的问题（均为真实失败后修复并重跑）：IME 模拟方式（unmarkText 会把拼音按原样提交）；iPad 上「AI 状态」同名按钮多个；懒加载 Form 需要滚动；iPad 分栏时需滑动 Form 本身；夹具横幅遮挡工具条（产品缺陷，已改布局）。

### `scripts/check-release-link.sh`
```
== FairyStudio / Release（期望 DevFixtures absent）        linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio-Verify / Verify-Release（期望 absent）      linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio / Debug（期望 absent）                      linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio-Verify / Verify-Debug（期望 present，正向对照） other_ldflags_contains=1 binary_symbols=1218                  OK
failures=0
```
