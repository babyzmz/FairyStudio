# M0-C 进度：SwiftRuntime 接入 App + 端到端验证

- 当前阶段：**M0-C 模拟器端到端完成；iPhone 实机在本包内受阻于签名账户，之后的实机构建与测试由主代理执行**（2026-09-24）
- **实机由主代理执行**：主代理通知（2026-09-24）其直接运行 iPhone 实机构建与测试（DerivedData `~/Library/Developer/Xcode/DerivedData/FairyStudio-device`，日志 `verification/logs/*-device-main-*.log`），结果由主代理补入 verification/M0.md。本包之后不再启动实机 xcodebuild。
- 环境：macOS 15.7.4 / Xcode 26.3 (17C529) / Swift 6.2.4 / iOS 26.2 SDK / iOS 26.3 模拟器 / XcodeGen 2.46.0
- 口径：模拟器结果为「验证构建（部署目标 26.2）」，只能记为「已实现待 iOS 27 环境复验」。

## 改动清单

| 范围 | 改动 |
|---|---|
| App 引擎 | `App/Runtime/EngineCatalog.swift`：`EngineChoice` 只剩 `.swiftRuntime` → `SwiftRuntimeEngine()`；删除 `PendingSwiftRuntimeEngine`、夹具 case、`-fairy.engine` 启动参数；新增 `EngineLiveCounts` / `LiveCountReporting`（读 `SwiftRuntimeEngine.liveCounters`） |
| 模板 | `Templates/Counter/`（`template.json` + `Sources/Models/Counter.swift` + `Sources/Views/ContentView.swift`，与 `Tests/SwiftRuntimeTests/Fixtures/counter` 逐字节一致，`AppTemplateConsistencyTests` 校验）；project.yml 以文件夹引用拷入 App 包；`App/Runtime/TemplateLoader.swift` 读取 manifest 与源码（不写死在 Swift 里） |
| 运行实验页 | `StudioModel` 默认加载 Counter 模板、入口 `.rootView(ContentView)`；「交换文件顺序」按钮 + 当前顺序显示；`CodeTextView`（UITextView，关闭弯引号 / 破折号 / 自动更正 / 自动大写 / 拼写 / 智能插删 / 行内预测，组字期间不回写）替换 TextEditor——SwiftUI TextEditor 键入 `"` 会变成 `“`，源码无法解析；运行时收起键盘；工具条引擎菜单改为只读标签 |
| 夹具移除 | project.yml：App 不再依赖 DevFixtures、删除 Verify-Debug 的 `OTHER_LDFLAGS`；删除 `FixtureBanner` 与横幅代码；DevFixtures 以 `link: false` + `OTHER_LDFLAGS $(BUILT_PRODUCTS_DIR)/DevFixtures.o` 只进 FairyStudioTests；Package.swift 保留 DevFixtures target |
| RunCoordinator | `run(_:entry:budget:)`；状态机只前进（忽略引擎启动时重复的 validating/preparing 与重复的 stopping）；引擎重复报告的校验诊断去重；自身校验失败记 `exitReason = .validationFailed`；DEBUG 指标：持有实例数、已启动/已释放数、引擎存活（实例/线程/任务）、`mach_task_basic_info` 常驻内存与 `phys_footprint`、进入运行耗时、校验耗时、停止→终态、停止→释放、状态序列（`App/Runtime/ProcessMemory.swift`；诊断抽屉 DEBUG「指标」页） |
| 调试长预算 | DEBUG 启动参数 `-fairy.budget long`（maxSteps = Int.max/2，slice 1h），指标页显示当前预算。用于测量**用户点击停止**的延迟；默认预算下 UI 事件无限循环会先被 200ms 墙钟中断 |
| SwiftRuntime（契约对齐） | 校验失败 / 入口无效：`failed` → `finished(.validationFailed)`；预算超限：`interrupted`（原 failed）；`stop()` 返回前兜底 `finish()`；`.appear/.disappear` 只记账（`appearedNodes`），不执行用户代码；`ViewEvaluator` 的 appear/disappear 处理器表改为 `lifecycleNodes` |
| NativeBridge（契约对齐） | `Lifecycle.swift`：`LifecycleInputs`（纯函数）+ `LifecycleHooks`；带 onAppear/onDisappear/task 的节点出现时发 `.appear(NodeID)` + onAppear 的 `.action`，task 启动时发 `.action`，消失时发 onDisappear 的 `.action` + `.disappear(NodeID)`；每节点只挂一次；`ModifierChain` 不再单独挂接 |
| 测试 | SwiftRuntimeTests：`ContractAlignmentTests`（3）、`AppTemplateConsistencyTests`（1）、改写 `validationFailureEndsStreamWithFailedState` / `conditionalBranchesAndOnAppear`；NativeBridgeTests：`LifecycleInputsTests`（5，含 NSHostingView 真实挂载）；FairyStudioTests：`SwiftRuntimeIntegrationTests`（9，真实引擎）、`BridgeLifecycleTests`（1，UIHostingController）、`OnDeviceModelCallTests`（1）；删除 `PendingEngineTests`；FairyStudioUITests 全部改为真实引擎（10 个） |
| 脚本 | `check-release-link.sh`：四个配置都断言无 DevFixtures，正向对照改为测试包；`build-verify.sh` 汇总包含全部 `[FAIRY-…]` 行；新增 `device-verify.sh`；`verify-env.sh` 统计 Xcode UserData 中的 profile 与 Xcode 账户可用团队（只输出 Team ID） |
| 文档 | ENVIRONMENT.md「实测变化」、RUNTIME_DESIGN.md §7、CONTRACT_CHANGES.md「M0-C 实现对齐」、APPLE_MODELS.md §6、verification/ACCEPTANCE.md、verification/M0.md |

RuntimeContracts 源码**未改动**。

## UI 测试（全部真实引擎；源码修改都通过真实编辑器键入：点入 → ⌘A → 删除 → 键入，并核对编辑器内容与键入内容逐字一致）

| 测试 | 验证 |
|---|---|
| `testCounterRunIncrementStop` | 无夹具横幅；运行 → 运行中 → Count: 0 → 1 → 2 → 停止 → 已停止；状态序列 = `idle→validating→preparing→running→stopping→stopped` |
| `testEditSourceAndRerunChangesUI` | 先 Count: 0；把 Counter.swift 初始值改为 10 → 重新运行 → Count: 10 → 11 |
| `testInfiniteLoopStopLatency` | 长预算下 increment 改为 `while true`，点击后 1.5s 仍为运行中；点停止，读 App 内 ContinuousClock 测得的「停止→终态」，断言 < 250ms |
| `testInfiniteLoopDefaultBudgetInterrupts` | 默认预算：同样的循环 → 已中断 + budgetExceeded 诊断 |
| `testThirtyRunStopCyclesLeaveNoInstances` | 30 次运行—停止；持有实例 0、引擎 0/0/0、已启动/已释放 30/30；记录前后内存 |
| `testFileOrderSwapGivesSameResult` | 交换顺序前后：Count、按钮、Reset 启用状态一致 |
| `testUnsupportedSyntaxShowsCapabilityID` | 追加 `class Base {}` / `class Derived: Base {}` → 失败；诊断含「尚不支持」「unsupportedSyntax · syntax.class」；无 nameResolution |
| `testDivideByZeroTrapIsDiagnosed` | `count += 10 / (step - step)` → 点击 → 失败 + runtimeTrap 诊断；App 仍在前台，可再次运行 |
| `testFormControlsWithRealEngine` | ContentView 换成 TextField/Toggle/ForEach 程序：中文分两批输入「你好」「世界」→ `Hello, 你好世界`、输入框值不变；Toggle → `State: on`；Reverse 后 durian 到首行 |
| `testAIStatusReportsRealAvailability` | 可用性原样显示；PCC = pccSDKMissing；不可用时发送禁用 |

移除的 M0-B 夹具 UI 测试：`testGalleryPresentationAndNavigation`（sheet / alert / NavigationLink / Slider）与 `testUnsupportedNodeIsVisible`（`.unsupported` 占位节点）。SwiftRuntime 在 M0 对这些 API 在校验阶段就报 unsupported，真实引擎无法产生对应 RenderTree，因此这两项的**端到端 UI 覆盖回到「待测」（M2）**；桥接组件本身仍由 macOS `RenderSmokeTests` 覆盖（每种 RenderKind 真实布局）。

## 已验证（命令与关键输出）

### 1. macOS `swift test`（Packages/FairyCore）
见文末「最终回归」。

### 2. `scripts/build-verify.sh`（FairyStudio-Verify / Verify-Debug，两台模拟器）
第一次完整运行 `20260924-011456`（日志 `verification/logs/20260924-011456-*.log`，不入库）：

```
== platform=iOS Simulator,name=iPhone 17 Pro
exit=65
** BUILD SUCCEEDED **
** TEST FAILED **
✔ Test run with 28 tests in 6 suites passed after 2.536 seconds.       # FairyStudioTests
Test Case '-[FairyStudioUITests.FairyStudioUITests testAIStatusReportsRealAvailability]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testCounterRunIncrementStop]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testDivideByZeroTrapIsDiagnosed]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testEditSourceAndRerunChangesUI]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFileOrderSwapGivesSameResult]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFormControlsWithRealEngine]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopDefaultBudgetInterrupts]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopStopLatency]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testUnsupportedSyntaxShowsCapabilityID]' passed.
	 Executed 1 test, with 0 failures (0 unexpected) in 21.838 (21.845) seconds
[FAIRY-AVAILABILITY-UI] device=iPhone 17 Pro onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用
[FAIRY-AVAILABILITY] mapped=modelNotReady reason=模型尚未就绪（可能正在下载），请稍后重新检测 raw=availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true

== platform=iOS Simulator,name=iPad Pro 11-inch (M5)
exit=0
** BUILD SUCCEEDED **
** TEST SUCCEEDED **
✔ Test run with 28 tests in 6 suites passed after 3.101 seconds.
	 Executed 10 tests, with 0 failures (0 unexpected) in 394.408 (394.420) seconds
Test Case '-[FairyStudioUITests.FairyStudioUITests testAIStatusReportsRealAvailability]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testCounterRunIncrementStop]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testDivideByZeroTrapIsDiagnosed]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testEditSourceAndRerunChangesUI]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFileOrderSwapGivesSameResult]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFormControlsWithRealEngine]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopDefaultBudgetInterrupts]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopStopLatency]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testThirtyRunStopCyclesLeaveNoInstances]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testUnsupportedSyntaxShowsCapabilityID]' passed.
[FAIRY-AVAILABILITY-UI] device=iPad Pro 11-inch (M5) onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用
overall_exit=65
```

iPhone 这一轮的 `testThirtyRunStopCyclesLeaveNoInstances` 没有结论：第 14 次循环点击停止后（等待「已停止」期间），xcodebuild 输出
`Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.`；
同一时刻宿主生成崩溃报告 `~/Library/Logs/DiagnosticReports/SimRenderServer-2026-09-24-012037.ips`
（`SimRenderServer` = CoreSimulator 的渲染 XPC 服务，`EXC_BREAKPOINT` / `Trace/BPT trap: 5`）。App 没有崩溃报告；runner 重启后其余测试继续并通过。
因此单独对 iPhone 重跑了整条 build-verify（见下）。

iPhone 重跑（`FAIRY_SKIP_GENERATE=1 FAIRY_ONLY_DEVICE=iphone scripts/build-verify.sh`，20260924-013051，汇总原样）：
```
== platform=iOS Simulator,name=iPhone 17 Pro → verification/logs/20260924-013051-iPhone-17-Pro.log
exit=0
	 Executed 10 tests, with 0 failures (0 unexpected) in 427.879 (427.897) seconds
** BUILD SUCCEEDED **
** TEST SUCCEEDED **
Test Case '-[FairyStudioUITests.FairyStudioUITests testAIStatusReportsRealAvailability]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testCounterRunIncrementStop]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testDivideByZeroTrapIsDiagnosed]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testEditSourceAndRerunChangesUI]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFileOrderSwapGivesSameResult]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testFormControlsWithRealEngine]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopDefaultBudgetInterrupts]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testInfiniteLoopStopLatency]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testThirtyRunStopCyclesLeaveNoInstances]' passed.
Test Case '-[FairyStudioUITests.FairyStudioUITests testUnsupportedSyntaxShowsCapabilityID]' passed.
[FAIRY-AVAILABILITY-UI] device=iPhone 17 Pro onDevice=modelNotReady pcc=pccSDKMissing headline=AI 当前不可用
[FAIRY-AVAILABILITY] mapped=modelNotReady reason=模型尚未就绪（可能正在下载），请稍后重新检测 raw=availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true
[FAIRY-M0C-UI] device=iPhone 17 Pro 30 cycles: activeInstances=0 engineLive(实例/线程/任务)=0/0/0 started/released=30/30 residentMB 330.9→342.5 footprintMB 57.4→60.8
[FAIRY-M0C-UI] device=iPhone 17 Pro defaultBudget infiniteLoop → 预算超限（wallClock）：单次执行片段超过墙钟预算（sliceWallClock = 0.2 seconds）。、budgetExceeded
[FAIRY-M0C-UI] device=iPhone 17 Pro infiniteLoop stop: app(停止→终态)=6.4ms app(停止→释放)=9.9ms xcuitest(点击→观察到已停止，含 XCUITest 点击与无障碍查询开销)=356ms budget=调试长预算（maxSteps≈∞，slice 1h）
[FAIRY-M0C-UI] device=iPhone 17 Pro order「传给运行时的文件顺序：Counter.swift → ContentView.swift」→["Count: 1", "Increment", "Reset", "reset-enabled"]；order「传给运行时的文件顺序：ContentView.swift → Counter.swift」→["Count: 1", "Increment", "Reset", "reset-enabled"]
[FAIRY-M0C-UI] device=iPhone 17 Pro stateHistory=idle→validating→preparing→running→stopping→stopped startLatencyMs=135.3 validationMs=31.5
[FAIRY-M0C-UI] device=iPhone 17 Pro trap → 运行错误：除以零：10 / 0（Swift: Division by zero）（在 CounterModel.increment() 中）、runtimeTrap
[FAIRY-M0C-UI] device=iPhone 17 Pro unsupported → 运行时尚不支持：class 'Base'（类与继承）。这是合法的 Swift，但 Fairy Studio 当前版本的解释器还不能执行它。、unsupportedSyntax · syntax.class
[FAIRY-M0C] 30 cycles: engine=EngineLiveCounts(instances: 0, threads: 0, tasks: 0) resident 423.9→420.1 MB footprint 87.4→87.7 MB
[FAIRY-M0C] coordinator stop latency=0.00018225 seconds completion=0.000371459 seconds
[FAIRY-MODEL-CALL] availability mapped=modelNotReady raw=availability=unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady); supportsLocale(zh-Hans_AU)=true
[FAIRY-MODEL-CALL] 未调用：设备端模型不可用（模型尚未就绪（可能正在下载），请稍后重新检测）
✔ Test run with 28 tests in 6 suites passed after 3.566 seconds.
overall_exit=0
```
结论：两台模拟器上 FairyStudioTests 28/28、FairyStudioUITests 10/10 全部通过（iPhone 以重跑为准，iPad 以 20260924-011456 为准）。

### 3. 实测数字（`[FAIRY-M0C…]` 行，原样摘录）

iPhone 17 Pro 模拟器（20260924-011456）：
```
[FAIRY-M0C] coordinator stop latency=0.000190083 seconds completion=0.000343042 seconds
[FAIRY-M0C] 30 cycles: engine=EngineLiveCounts(instances: 0, threads: 0, tasks: 0) resident 326.6→326.6 MB footprint 55.8→55.8 MB
[FAIRY-M0C-UI] device=iPhone 17 Pro stateHistory=idle→validating→preparing→running→stopping→stopped startLatencyMs=137.0 validationMs=31.5
[FAIRY-M0C-UI] device=iPhone 17 Pro infiniteLoop stop: app(停止→终态)=6.3ms app(停止→释放)=9.7ms xcuitest(点击→观察到已停止，含 XCUITest 点击与无障碍查询开销)=371ms budget=调试长预算（maxSteps≈∞，slice 1h）
[FAIRY-M0C-UI] device=iPhone 17 Pro defaultBudget infiniteLoop → 预算超限（wallClock）：单次执行片段超过墙钟预算（sliceWallClock = 0.2 seconds）。、budgetExceeded
[FAIRY-M0C-UI] device=iPhone 17 Pro trap → 运行错误：除以零：10 / 0（Swift: Division by zero）（在 CounterModel.increment() 中）、runtimeTrap
[FAIRY-M0C-UI] device=iPhone 17 Pro unsupported → 运行时尚不支持：class 'Base'（类与继承）。这是合法的 Swift，但 Fairy Studio 当前版本的解释器还不能执行它。、unsupportedSyntax · syntax.class
[FAIRY-M0C-UI] device=iPhone 17 Pro order「传给运行时的文件顺序：Counter.swift → ContentView.swift」→["Count: 1", "Increment", "Reset", "reset-enabled"]；order「传给运行时的文件顺序：ContentView.swift → Counter.swift」→["Count: 1", "Increment", "Reset", "reset-enabled"]
```
iPad Pro 11-inch (M5) 模拟器（20260924-011456）：
```
[FAIRY-M0C] coordinator stop latency=0.000197125 seconds completion=0.000478292 seconds
[FAIRY-M0C] 30 cycles: engine=EngineLiveCounts(instances: 0, threads: 0, tasks: 0) resident 334.3→334.3 MB footprint 58.0→58.2 MB
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) stateHistory=idle→validating→preparing→running→stopping→stopped startLatencyMs=40.9 validationMs=27.6
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) infiniteLoop stop: app(停止→终态)=11.5ms app(停止→释放)=15.0ms xcuitest(点击→观察到已停止，含 XCUITest 点击与无障碍查询开销)=411ms budget=调试长预算（maxSteps≈∞，slice 1h）
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) 30 cycles: activeInstances=0 engineLive(实例/线程/任务)=0/0/0 started/released=30/30 residentMB 329.9→321.7 footprintMB 56.7→61.1
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) defaultBudget infiniteLoop → 预算超限（wallClock）：单次执行片段超过墙钟预算（sliceWallClock = 0.2 seconds）。、budgetExceeded
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) trap → 运行错误：除以零：10 / 0（Swift: Division by zero）（在 CounterModel.increment() 中）、runtimeTrap
[FAIRY-M0C-UI] device=iPad Pro 11-inch (M5) unsupported → 运行时尚不支持：class 'Base'（类与继承）。…、unsupportedSyntax · syntax.class
```
说明：
- 「停止→终态」= App 内 `ContinuousClock`，从 `RunCoordinator.stop()` 被调用到状态进入 stopped；「停止→释放」= 到实例 `stop()` 返回、事件流排空、句柄释放。XCUITest 数字包含点击合成、等待 App 空闲与 100ms 轮询无障碍树，只作上界参考。
- 常驻内存（resident）包含共享库与渲染缓冲，UI 驱动下波动较大（iPad 30 次后反而下降 8 MB）；`phys_footprint` 增长 3.6–4.4 MB（UI 测试，含控制台 / 诊断累积与 SwiftUI 缓存），单测中 30 次循环为 0–0.2 MB。实例 / 线程 / 任务计数为 0 是泄漏判断的主依据。

### 4. `scripts/check-release-link.sh`（20260924-010456）
```
== FairyStudio / Release（期望 DevFixtures absent）              linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio-Verify / Verify-Release（期望 absent）            linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio / Debug（期望 absent）                            linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudio-Verify / Verify-Debug（期望 absent）              linkfilelist_contains=0 other_ldflags_contains=0 binary_symbols=0  OK
== FairyStudioTests / Verify-Debug（期望 present，正向对照）     test_bundle=…/Fairy Studio.app/PlugIns/FairyStudioTests.xctest binary_symbols=1194  OK
failures=0
```

### 5. `scripts/verify-env.sh` → `verification/env-2026-09-24.log`
```
iPad Pro 11-inch (M5) (iPad17,1) os=27.0 build=24A5408d pairing=paired tunnel=unavailable ddiServicesAvailable=False developerMode=enabled
iPad Pro (12.9-inch) (6th generation) (iPad14,5) os=18.7.8 build=22H352 pairing=paired tunnel=disconnected ddiServicesAvailable=False developerMode=enabled
iPhone 16 Pro Max (iPhone17,2) os=27.0 build=24A437 pairing=paired tunnel=connected ddiServicesAvailable=True developerMode=enabled
有效身份数：2 / Team 66F6479Y4Q / Team 726834KAPQ
provisioning profile 数（Xcode UserData）：4（Team 8M39RSH36Q ×3、978L5PZ2LT ×1）
Xcode 账户可用的开发团队：Team 978L5PZ2LT（Personal Team）
```

## 实机（iPhone 16 Pro Max，iOS 27.0）——本包内受阻：签名账户（后续由主代理执行）

所有尝试都停在构建的签名步骤，**未安装、未运行任何测试**，因此实机 availability 真实值与真实模型调用都没有取得。

1. `20260924-003231-device-preflight-build.log`（目的地用 devicectl 标识）：
```
xcodebuild: error: Unable to find a device matching the provided destination specifier:
		{ id:5A098528-3D0F-5EC7-8F05-2A912C790B95 }
	Available destinations for the "FairyStudio-Verify" scheme:
		{ platform:iOS, arch:arm64, id:00008140-000E2C523A52801C, name:<设备名> }
```
→ xcodebuild 只认硬件 UDID `00008140-000E2C523A52801C`。
2. `20260924-003405-device-preflight-build.log`、`20260924-004726-device-retry-build-*.log`（用户在手机上信任开发者后重试）、`20260924-011436-device-build.log`（用户告知已在 Xcode 登录账户后重试）、`20260924-012915-device-build.log`（`scripts/device-verify.sh`）——五次结果相同：
```
** BUILD FAILED **
/Users/richie/Desktop/AI-program/FairyStudio/FairyStudio.xcodeproj: error: No Account for Team "66F6479Y4Q". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'FairyStudio' from project 'FairyStudio')
/Users/richie/Desktop/AI-program/FairyStudio/FairyStudio.xcodeproj: error: No profiles for 'com.fairystudio.app' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'com.fairystudio.app'. (in target 'FairyStudio' from project 'FairyStudio')
```
3. 只读核对（未改任何设置）：Xcode 偏好 `IDEProvisioningTeamByIdentifier` 中唯一的团队是 `978L5PZ2LT`（"Personal Team"）；2026-09-24 01:08 Xcode 为该团队生成了 `978L5PZ2LT.com.fairystudio.app` 的开发 profile（含这台 iPhone）。也就是说当前登录的账户属于 978L5PZ2LT，而 `Config/Signing.local.xcconfig` 要求 66F6479Y4Q。按任务要求**没有修改团队 ID**，也没有用命令行覆盖。

需要用户做的（二选一）：
- 在 Xcode「设置 → 账户」登录**属于 Team 66F6479Y4Q 的 Apple ID**（登录后确认该团队出现在账户的团队列表里），然后运行 `scripts/device-verify.sh`；或
- 若决定改用已登录的 Personal Team，由用户（或主代理征得用户同意后）把 `Config/Signing.local.xcconfig` 的 `DEVELOPMENT_TEAM` 改为 `978L5PZ2LT`，再运行 `scripts/device-verify.sh`。注意 Personal Team 的 profile 有效期 7 天。

解除后 `scripts/device-verify.sh` 会依次 build、跑 FairyStudioTests（含 `OnDeviceModelCallTests`：可用则发送「用一句话介绍你自己」并输出 `[FAIRY-MODEL-CALL] completed backend=… elapsed=… head200=…`；不可用则输出原样原因）与全部 FairyStudioUITests（含 30 次循环，不做其他压力测试），汇总写入 `verification/logs/<时间>-device-summary.log`。

## 三档状态

### 已实现并验证（模拟器验证构建 / macOS 单测口径）
- App 正式路径使用 SwiftRuntime：Counter 模板（两个互相引用的文件）在 iPhone 17 Pro 与 iPad Pro 11 (M5) 模拟器端到端 Count 0→1→2、停止；状态序列与终止原因来自真实事件。
- 修改源码后重跑界面变化；文件顺序交换结果一致；class 继承 → unsupportedSyntax + `syntax.class`；除零 → runtimeTrap + failed，App 不崩。
- 停止延迟：App 内测「停止→终态」iPhone 17 Pro 6.3 / 6.4 ms、iPad Pro 11 (M5) 11.5 ms（UI 驱动）；协调器单测 0.18–0.23 ms；macOS 引擎 stop() 最大 1.3–3.0 ms。均 < 250 ms。
- 30 次运行—停止：两台模拟器 UI 测试与单测均为实例 / 线程 / 任务 0，已启动 = 已释放 = 30。
- 夹具引擎从 App 所有配置移除（链接检查 + 测试包正向对照）。
- 契约对齐：CR-1 / B-7 / B-5 双方实现与测试。

### 已实现待实机 / 待 iOS 27 环境
- 上述全部在 iPhone 16 Pro Max（iOS 27.0）上的复验；实机 `SystemLanguageModel.default.availability` 真实值；一次真实本地模型调用（测试已就绪）。
- 产品配置（部署目标 27.0）运行。

### 未实现 / 受阻
- 实机：签名账户（上文）。iPad 实机：iPad Pro 11 (M5) tunnel 不可用；iPad Pro 12.9 为 iOS 18.7.8。
- PCC：SDK 缺失（`pccSDKMissing`）+ 资格与 entitlement 未核对。
- sheet / alert / 导航 / Slider 与 `.unsupported` 占位的端到端 UI（真实引擎 M2 才支持）。
- 性能：validate 与 run 各编译一次（进入运行耗时含两次编译），M2 做编译缓存。

## 下一步
1. 实机由主代理执行（签名账户解决后可用 `scripts/device-verify.sh`，或主代理自己的命令），把 `[FAIRY-MODEL-CALL]`、`[FAIRY-M0C-UI]` 与 XCTest 汇总补入本文件、verification/M0.md、verification/ACCEPTANCE.md 与 docs/APPLE_MODELS.md §6。
2. 进入 M1（ProjectCore + TextKit 2 编辑器）。

## 最终回归（2026-09-24）

### macOS `swift test`（Packages/FairyCore，宿主 macOS 15.7.4）
```
$ cd Packages/FairyCore && swift test
[FoundationAITests] 宿主 OnDevice availability = systemError (系统错误：系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用); raw = 系统版本低于 26
[M0-A] 30 次 run/stop 后：instances=0 threads=0 tasks=0
[M0-A] stop() 延迟（ms）：1.338, 0.505, 0.103, 0.129, 0.109；最大 1.338
✔ Test run with 103 tests in 17 suites passed after 1.129 seconds.
exit=0
```
（M0-A/M0-B 合并时 94 项；新增 ContractAlignmentTests 3、AppTemplateConsistencyTests 1、LifecycleInputsTests 5。）

### 模拟器
- iPhone 17 Pro：`20260924-013051`，`overall_exit=0`（上文）。
- iPad Pro 11-inch (M5)：`20260924-011456`，`exit=0`（上文）。

### 链接检查
- `scripts/check-release-link.sh`：`failures=0`（上文）。

### 实机
- 本包内：签名账户阻塞（上文，原始错误已记录）。之后由主代理执行。
