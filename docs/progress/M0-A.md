# M0-A SwiftRuntime 进度

- 当前阶段：**M0-A 实现完成，macOS 单测全绿**（2026-09-24）。待 M0-C 集成进 App 后在模拟器端到端复验。
- 环境口径：`macOS 单测`（macOS 15.7.4，Xcode 26.3，Swift 6.2.4，swift-syntax 603.0.2，debug 构建）。

## 交付物

| 路径 | 内容 |
|---|---|
| `Packages/FairyCore/Sources/SwiftRuntime/` | Parse / Index / Resolve / IR / VM / Stdlib / UI / Engine / Catalog（9,379 行） |
| `Packages/FairyCore/Sources/fairy-run/` | 无头 CLI：`run` / `render` / `validate` / `catalog [--markdown]` |
| `Packages/FairyCore/Tests/SwiftRuntimeTests/` | 59 个测试函数（其中 5 个参数化，展开后共 130 个用例），夹具在 `Fixtures/` |
| `Tests/SwiftRuntimeTests/Fixtures/counter/Sources/{Models/Counter.swift, Views/ContentView.swift}` | 供集成阶段 App 直接复用的计数器夹具 |
| `Tests/SwiftRuntimeTests/Fixtures/differential/*.swift` | 30 个差分夹具（其中 5 个 trap） |
| `docs/RUNTIME_DESIGN.md` | 数据结构、IR 指令集、预算检查点、状态存储键、线程模型、已知限制 |
| `docs/SWIFT_SUPPORT.md` | 由 catalog 生成（451 条：supported 150 / partial 104 / unsupported 197），测试保证一致 |
| `docs/CONTRACT_REQUESTS.md` | CR-1…CR-7 |

`Package.swift` 变更：SwiftRuntime 增加 swift-syntax 的 `SwiftOperators`、`SwiftParserDiagnostics`、`SwiftDiagnostics` 三个 product（运算符折叠与语法诊断），未改其他 target。
swift-syntax 版本未变（603.0.2）。另外使用了 `@_spi(Compiler) import SwiftParser` 以获得字符串插值片段的反转义（版本锁定，升级 swift-syntax 时需复核）。

## 已验证（命令与关键输出）

### 全部测试
```
$ cd Packages/FairyCore && swift test
✔ Test differential(fixture:) with 30 test cases passed
✔ Test unsupportedSyntaxMapsToCapabilityID(name:) with 26 test cases passed
✔ Test unsupportedSwiftUIMapsToCapabilityID(name:) with 6 test cases passed
✔ Test runtimeTrapsBecomeDiagnostics(name:) with 8 test cases passed
✔ Test hostIsProtectedFromPathologicalPrograms(name:) with 6 test cases passed
[M0-A] 30 次 run/stop 后：instances=0 threads=0 tasks=0
[M0-A] stop() 延迟（ms）：0.754, 1.117, 0.345, 0.641, 0.142；最大 1.117
✔ Test run with 59 tests in 8 suites passed after 1.436 seconds.
	 Executed 0 tests, with 0 failures (0 unexpected)   ← 其他 target 的 XCTest 占位，非本包
```
连续运行两次均全绿（第一次 stop 延迟样本：13.633, 0.096, 0.332, 0.084, 9.029 ms，最大 13.6 ms——与其他并行测试争用 CPU 时出现）。
差分测试首次运行会用本机 `swiftc` 编译 30 个夹具（约 8 秒，结果按源码+编译器版本哈希缓存于临时目录），之后命中缓存。

### 实测数字
- **stop() 延迟**（`stopInfiniteLoopWithin250ms`：`while true {}` 运行 80 ms 后调用 stop，计时到返回，此时启动任务与执行线程已结束）：
  单独运行该套件 0.080–0.150 ms；全量并行测试中最大 13.6 ms。断言 < 250 ms 通过。
- **30 次 run/stop**：weak 引用的 `SwiftRunHandle` 与 `RunInstance` 全部释放；`liveInstances = 0, liveThreads = 0, liveTasks = 0`。
- 性能（debug）：100 万次 `total &+= i % 7` 循环约 1.4 s，约 7 百万条指令/秒。

### 需求逐项
| 需求 | 验证 |
|---|---|
| 两个互相引用的文件 → Text("Count: 0") + Button；`.action` 后 revision 递增、Text 变为 1 | `counterRootViewRendersAndIncrementsOnAction`（还验证 ActionID 跨渲染稳定、Reset 的 disabled、事件状态序列） |
| `.mainApp` 入口（@main App + WindowGroup） | `counterViaMainAppEntry` |
| 文件顺序无关 | `allFileOrdersProduceSameScriptOutput`（4 文件全部 24 种排列）、`shuffledFileOrderProducesSameRenderTree`（随机 20 次，RenderTree 与诊断一致） |
| 跨文件 private / 未声明符号 → nameResolution 且行列正确 | `crossFilePrivateMemberIsNameResolutionError`、`crossFilePrivateFunctionIsNameResolutionError`、`undeclaredSymbolPointsToCorrectFileLineColumn`（含中文前缀的 UTF-8 列）、`privateSetterBlocksCrossFileMutation` |
| 闭包捕获（计数器、按引用、逃逸到 Button） | `counterClosureCapturesVarByReference`、`letCaptureIsByValueAndLoopBindingsAreFresh`、`closureEscapesIntoButtonAndMutatesState`、差分 13/14 |
| 值语义 | `structCopyIsIndependent`、`arrayCopyIsIndependent`、差分 16 |
| Int/Double 区分；溢出、除零、越界、强制解包 nil、字典缺 key | `intAndDoubleMixingIsTypeError`、`integerLiteralsAdaptToDoubleContext`、`runtimeTrapsBecomeDiagnostics`（8 种）、差分 25–29（trap 前输出与本机一致） |
| 预算：maxSteps / maxCallDepth / maxCollectionElements（另 heap、string、sliceWallClock） | `infiniteLoopStopsAtMaxSteps`、`deepRecursionStopsAtMaxCallDepth`、`hugeArrayAppendStopsAtMaxCollectionElements`、`heapGrowthStopsAtMaxHeapBytesApprox`、`stringGrowthStopsAtMaxStringLength`、`uiActionInfiniteLoopHitsSliceWallClock`、`scriptYieldsAtSliceBoundaryAndResumesCorrectly` |
| 宿主不崩溃 | `hostIsProtectedFromPathologicalPrograms`（巨大区间、巨大 repeat、Int.min 取负、Double→Int 溢出、stride 0）、`deeplyNestedValueIsStoppedBeforeHostStackOverflow` |
| 取消 < 250 ms、30 次 run/stop 无泄漏、旧实例迟到输入无效 | `stopInfiniteLoopWithin250ms`、`thirtyRunStopCyclesReleaseEverything`、`lateInputsFromOldRunDoNotAffectNewRun`、`outOfOrderInputSequenceIsDropped` |
| ForEach 重排后 @State 不串行；TextField setBinding 反写 | `forEachReorderKeepsRowStateWithItsID`、`textFieldSetBindingWritesBack`（含 Toggle 与类型不匹配写入） |
| @Binding 传递、视图重建不重置 @State、if/else 分支、onAppear | `bindingPassedToChildWritesParentState`、`conditionalBranchesAndOnAppear` |
| 修饰符映射 | `modifiersMapToRenderModifiers`、`forEachOverIdentifiableAndRange` |
| 不支持语法 → capabilityID，不伪装成用户错误 | `unsupportedSyntaxMapsToCapabilityID`（26 种）、`unsupportedSwiftUIMapsToCapabilityID`（6 种） |
| catalog 的 testIDs 真实存在；SWIFT_SUPPORT.md 与 catalog 一致；引用的能力都在 catalog 中 | `catalogSupportedEntriesReferenceRealTests`、`supportDocMatchesCatalog`、`referencedCapabilitiesExistInCatalog`、`catalogIDsAreUniqueAndWellFormed` |
| validate 返回 entryPoints / referencedCapabilities；多入口与非法顶层语句报错 | `validateReportsEntryPointsAndCapabilities`、`validateListsScriptEntryAndCapabilities`、`multipleMainAppsIsError`、`topLevelStatementsOutsideMainSwiftIsError`、`mainAppMixedWithTopLevelCodeIsError` |
| 事件协议 | `scriptEntryPrintsToConsoleAndCompletes`、`eventSequenceIsStrictlyIncreasing`、`validationFailureEndsStreamWithFailedState` |

### CLI
```
$ .build/debug/fairy-run run Tests/SwiftRuntimeTests/Fixtures/differential/27_trap_index_out_of_range.swift
item a
item b
item c
27_trap_index_out_of_range.swift:5:19: error: runtimeTrap: 运行错误：数组下标越界：索引 3，数组长度 3（Swift: Index out of range）（在 main.swift 顶层代码 中）
exit=1

$ .build/debug/fairy-run run --max-steps 100000 perf.swift
perf.swift:2:1: error: budgetExceeded: 预算超限（steps）：执行步数超过预算（maxSteps = 100000）。可能存在无限循环。
exit=2

$ .build/debug/fairy-run validate Tests/SwiftRuntimeTests/Fixtures/counter
入口：[RuntimeContracts.EntryPoint.rootView(symbol: "ContentView")]
能力：modifier.buttonStyle, modifier.disabled, modifier.font, modifier.padding, propertyWrapper.State, …, view.customView

$ .build/debug/fairy-run render Tests/SwiftRuntimeTests/Fixtures/counter --entry rootView:ContentView   # 输出 RenderTree JSON（revision 1，含 "Count: 0" 与两个按钮）
$ .build/debug/fairy-run catalog --markdown > ../../docs/SWIFT_SUPPORT.md
```

## 本阶段修复记录
- 脚本入口在时间片边界让出后恢复时跳过一条已取出的指令，导致宿主数组越界崩溃（性能探针发现）。已修复并加回归测试 `scriptYieldsAtSliceBoundaryAndResumesCorrectly`。
- 区间 `count` 减法溢出、`String(repeating:count:)` 长度乘法溢出、极深嵌套值释放时耗尽宿主栈：均改为受控预算错误并加测试。

## 未完成 / 已知限制
- 见 `docs/RUNTIME_DESIGN.md` 第 9 节与 `docs/SWIFT_SUPPORT.md` 的 partial/unsupported 条目。主要：class/protocol/泛型/async/throws/inout/元组解构/关联值 enum/计算属性 setter；
  NavigationLink、sheet/alert、Slider/Picker 等；`.task` 仅同步子集；onAppear 由宿主触发。
- partial 条目中约 100 个标准库成员已实现但尚无专门测试。
- iOS：`xcodebuild -scheme SwiftRuntime -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`（仅编译验证）；
  尚未在 iOS 模拟器/实机上运行（M0-C 集成时验证）。
- 未做 release 构建性能测量与指令优化。

## 下一步
1. M0-C：App 通过 `SwiftRuntimeEngine` 运行 `Fixtures/counter`，宿主在 SwiftUI onAppear 时发送 `.appear(NodeID)`（见 CR-2）。
2. 主代理裁决 CONTRACT_REQUESTS.md 中的 CR-1、CR-2、CR-3。
3. M2：inout、元组解构、关联值 enum、计算属性 setter、单侧区间、NavigationLink/sheet/alert、Slider/Picker/Stepper、受控异步 `.task`。
