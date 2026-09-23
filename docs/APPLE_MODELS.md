# Apple 模型接入（FoundationAI）

核验日期：2026-09-23。环境：Xcode 26.3 / iOS 26.2 SDK / iOS 26.3 模拟器 / macOS 15.7.4 宿主。
代码：`Packages/FairyCore/Sources/FoundationAI/`。

## 1. 后端

只有两个后端，经 `actor ModelBroker` 统一访问（唯一入口）：

| `ModelBackend` | 实现 | 当前状态 |
|---|---|---|
| `.onDevice` | `OnDeviceModelDriver`：`SystemLanguageModel.default` + `LanguageModelSession` | 已实现；真实成功调用**待实机**（见 §6） |
| `.privateCloudCompute` | `PrivateCloudComputeDriver`，实现放在 `#if FAIRY_PCC_SDK` 内 | 当前不定义 `FAIRY_PCC_SDK`，固定返回 `.pccSDKMissing`；定义该条件而未按真实 SDK 实现时会 `#error` 编译失败，防止编造 API |

策略（由 `ModelBroker` 执行，`ModelBrokerTests` 覆盖）：
- 默认后端 `.onDevice`（`ModelBroker.defaultBackend`）。
- **每个任务开始时**调用 `checkAvailability(backend:)`（不是只在启动时）。
- 云端首次使用需要用户确认（`CloudConsentStore`，M0 存 UserDefaults；键 `fairy.ai.privateCloudCompute.consent.v1`）；未确认时既不检测也不调用云端。
- **绝不自动回退**：请求显式指定后端；设备端不可用时任务以 `.unavailable(原因)` 失败，不会静默转到云端上传。
- 单在途：同一时刻一个任务，其他请求返回 `.busy`；`cancelCurrentTask()` 或调用方任务取消都会停止底层生成（取消经 `AsyncThrowingStream.onTermination` 传到持有 `LanguageModelSession` 的任务）。
- M0 每个请求新建 `LanguageModelSession`（无多轮上下文）；`isResponding` 在发送前检查，单在途由 Broker 的 `isResponding` 保证并供界面读取。

## 2. 可用性状态 `ModelAvailability`

| 状态 | 来源 | 说明 |
|---|---|---|
| `available` | `SystemLanguageModel.Availability.available` 且 `supportsLocale(Locale.current)` 为 true | |
| `deviceNotEligible` | `.unavailable(.deviceNotEligible)` | |
| `appleIntelligenceNotEnabled` | `.unavailable(.appleIntelligenceNotEnabled)` | |
| `modelNotReady` | `.unavailable(.modelNotReady)`；生成时 `assetsUnavailable` | |
| `unsupportedLanguage` | 模型可用但 `supportsLocale(Locale.current) == false`；生成时 `unsupportedLanguageOrLocale` | |
| `regionOrAccountRestricted` | 当前 SDK 无对应公开信号 | 预留，当前代码不会产生 |
| `pccNotEntitled` | 待 PCC SDK | 预留 |
| `pccSDKMissing` | 未定义 `FAIRY_PCC_SDK` | 当前 PCC 的固定值 |
| `noNetwork` | 待 PCC SDK（设备端不涉及网络） | 预留 |
| `quotaExhausted` | 生成时 `rateLimited` | |
| `refused` | 生成时 `refusal` / `guardrailViolation` | 单次拒绝不改写界面上的后端可用性 |
| `systemError(String)` | 系统版本低于 26、SDK 不含框架、未知错误 | 附原始描述 |
| `unknown` | `UnavailableReason` 出现本代码未识别的新 case（`@unknown default`） | 判断不了原因时返回 unknown，不猜 |

映射函数：`ModelStatusMapping.availability(from:localeSupported:)`（平台无关、macOS 单测）；SDK 类型 → 镜像：`FoundationModelsBridge.signal(from:)`（iOS 模拟器单测逐一覆盖 3 个 SDK case）。

## 3. `LanguageModelSession.GenerationError` 映射

| SDK case | `ModelTaskFailure` | 对可用性的影响 |
|---|---|---|
| `exceededContextWindowSize(Context)` | `.exceededContextWindowSize(debugDescription)` | 无（提示缩短输入） |
| `assetsUnavailable(Context)` | `.assetsUnavailable` | `modelNotReady` |
| `guardrailViolation(Context)` | `.guardrailViolation` | `refused` |
| `unsupportedGuide(Context)` | `.unsupportedGuide` | 无 |
| `unsupportedLanguageOrLocale(Context)` | `.unsupportedLanguageOrLocale` | `unsupportedLanguage` |
| `decodingFailure(Context)` | `.decodingFailure` | 无 |
| `rateLimited(Context)` | `.rateLimited` | `quotaExhausted` |
| `concurrentRequests(Context)` | `.concurrentRequests` | 无 |
| `refusal(Refusal, Context)` | `.refusal` | `refused` |
| 未来新增 case | `.unrecognizedGenerationError(String(describing:))` | 无 |

另有 Broker 自身的状态：`.unavailable(ModelAvailability)`、`.cloudConsentRequired`、`.busy`、`.systemError`，以及结果 `.cancelled`。
测试：macOS `FoundationAITests`（镜像映射，9 个 case 一一且两两不同）；iOS 模拟器 `FairyStudioTests/FoundationModelsOnSimulatorTests`（用 `GenerationError.Context(debugDescription:)` 与 `Refusal(transcriptEntries:)` 构造 9 个真实 SDK 值逐一映射）。

## 4. SDK 实测符号（iOS 26.2 Simulator SDK）

来源：`$(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64-apple-ios-simulator.swiftinterface`（1536 行）。`scripts/verify-env.sh` 会重新统计。

已核实并在代码中使用的签名：
- `final public class SystemLanguageModel : Sendable`；`public static let default`；`final public var availability: Availability`；`final public func supportsLocale(_ locale: Locale = Locale.current) -> Bool`
- `@frozen public enum Availability { case available; case unavailable(UnavailableReason) }`；`UnavailableReason`：`deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady`（非 frozen，代码带 `@unknown default`）
- `final public class LanguageModelSession`（SDK 中 `extension LanguageModelSession : @unchecked Sendable`）；`init(model:tools:instructions: String?)`；`final public var isResponding: Bool`
- `final public func streamResponse(to prompt: String, options: GenerationOptions = GenerationOptions()) -> sending ResponseStream<String>`；`ResponseStream : AsyncSequence`，`Snapshot.content: Content.PartiallyGenerated`
- `public enum GenerationError : Error, LocalizedError`，9 个 case 如 §3；`Context.debugDescription`；`Refusal(transcriptEntries:)`

**上下文容量**：在该 swiftinterface 中 grep `contextSize|tokenCount|contextWindow` 的声明为 0 处；唯一相关的是 `GenerationOptions.maximumResponseTokens: Int?`（是**响应长度上限参数**，不是容量查询）。结论：**当前 SDK 无公开容量 / token 计数查询**。代码不写死任何容量数字，超限通过 `exceededContextWindowSize` 处理。Xcode 27 SDK 到位后需重新 grep。

**PCC**：iOS 26.2 Simulator SDK 全部 swiftinterface 中 grep `PrivateCloudCompute` 命中 0 个文件（`PrivateCloudComputeLanguageModel` 不存在）。

## 5. PCC 待核对清单（Xcode 27 SDK 与官方文档到位后）

以下全部**未核对**，不得在代码中假设：
1. PCC 模型的公开类型名与初始化方式（ENVIRONMENT.md 记录的候选名 `PrivateCloudComputeLanguageModel` 仅为待核对名称）。
2. 可用性 API 与不可用原因枚举（是否区分资格、网络、配额、地区/账户），逐一映射到 `pccNotEntitled` / `noNetwork` / `quotaExhausted` / `regionOrAccountRestricted`。
3. 所需 entitlement 的**精确标识**与申请流程（Small Business Program / 首次下载量门槛等资格条件）——需在 Apple Developer 后台核对后记入本节。
4. 会话与流式 API 是否与 `LanguageModelSession` 一致；错误类型是否复用 `GenerationError`。
5. 是否有容量 / token 计数 API。
6. 隐私说明文案要求（App Store 隐私标签、用户告知）。
7. 实现后：定义 `FAIRY_PCC_SDK`、删除 `#error`、补 `PrivateCloudComputeDriver` 测试。

## 6. 实测记录

| 环境 | 结果 | 命令 / 位置 |
|---|---|---|
| macOS 15.7.4 宿主（`swift test`） | `OnDeviceModelDriver.checkAvailability()` = `systemError("系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用")`（`#available(macOS 26)` 为假，未调用框架） | `swift test --filter FoundationAITests` 输出 `[FoundationAITests] 宿主 OnDevice availability = systemError …` |
| iOS 26.3 模拟器（iPhone 17 Pro，宿主 macOS 15.7.4） | 原始值：`availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true` → 映射 `modelNotReady` | `FairyStudioTests` 输出 `[FAIRY-AVAILABILITY]`；UI 测试输出 `[FAIRY-AVAILABILITY-UI] onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用` |
| iOS 26.3 模拟器（iPad Pro 11-inch (M5)） | 见 docs/progress/M0-B.md 的 build-verify 汇总 | `scripts/build-verify.sh` |
| PCC（所有环境） | `pccSDKMissing` | 同上 |
| iPhone 16 Pro Max 实机（iOS 27.0，2026-09-24 M0-C） | **受阻：未能安装到设备**。DDI 可用（`ddiServicesAvailable: true`），但构建在签名步骤失败：`No Account for Team "66F6479Y4Q"` / `No profiles for 'com.fairystudio.app' were found`。可用性真实值与真实调用均未取得 | `scripts/device-verify.sh`（运行 `OnDeviceModelCallTests` 并输出 `[FAIRY-MODEL-CALL]` 行） |

说明：模拟器报告的是 `modelNotReady`，而不是 `deviceNotEligible`——这是系统原样返回的值，本代码未做推断。按 docs/ENVIRONMENT.md，模拟器上的 Foundation Models 需要 macOS 26 宿主，因此该状态在当前宿主上不会变为可用。

**真实成功调用：已实现待实机**。M0-C 已加入 `FairyStudioTests/OnDeviceModelCallTests`：可用时经 ModelBroker 发送「用一句话介绍你自己」，记录实际后端、耗时与响应前 200 字；不可用时原样记录原因、不调用、无假响应。
2026-09-24 复核：Xcode 26.3 与 iOS 27.0 实机的 DDI 可用，阻塞点改为签名账户（见 docs/ENVIRONMENT.md「实测变化」）。解除后运行 `scripts/device-verify.sh` 即可补入本表。

## 7. 隐私与上传策略

- 默认设备端：提示与输出不离开设备。
- 云端（PCC）只有在用户于「AI 状态」页确认后才可选；确认可随时撤销（`CloudConsentStore.revokeConsent()`）。
- 不存在任何自动回退路径：设备端不可用 → 任务失败并显示原因，**从本地模式绝不静默上传**（`ModelBrokerTests.noSilentCloudFallback`）。
- 不可用时界面禁用发送并显示原因，**不提供假响应**。
- FoundationAI 目标内无 URLSession / URLRequest / 外部端点，模块导入仅限 Foundation / FoundationModels / Synchronization / RuntimeContracts（`NetworkAuditTests`，项目自定义源码审计）。
- M3 起的项目上下文、秘密信息检测、工具调用策略不在 M0 范围。
