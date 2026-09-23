# 验收矩阵

> 来源说明：PLAN.md §4 要求按任务书第 20 节逐条列出。任务书原文不在仓库中，本矩阵的条目取自 docs/PLAN.md 各里程碑的交付与门禁（M0–M7）。主代理拿到第 20 节原文后应逐条核对、补齐或改名；**不得因此把「待测」改为通过**。

环境口径（与 docs/ENVIRONMENT.md 一致）：
- **macOS 单测**：宿主 macOS 15.7.4 / Xcode 26.3 / Swift 6.2.4，`cd Packages/FairyCore && swift test`
- **模拟器（验证构建）**：iOS 26.3 模拟器，FairyStudio-Verify scheme（部署目标 26.2），只能记为「已实现待 iOS 27 环境复验」
- **iPhone 实机**：iPhone 16 Pro Max，iOS 27.0（24A437）
- **iPad 实机**：当前无可部署 iPad

结果取值：通过（附数字）/ 失败 / 待测 / 受阻（附原因）。「待测」「受阻」都不算通过。

## M0 环境与技术验证

| # | 条目 | 环境口径 | 命令 / 测试 | 结果 | 日期 |
|---|---|---|---|---|---|
| M0-1 | SwiftRuntime 单测全绿 | macOS 单测 | `swift test`（Packages/FairyCore） | 通过：103 tests / 17 suites | 2026-09-24 |
| M0-2 | 两个互相引用的 Swift 文件经解释器输出原生计数器；点击后 Count 0→1→2；停止 | macOS 单测 | `CounterFixtureTests.counterRootViewRendersAndIncrementsOnAction` | 通过 | 2026-09-24 |
| M0-2s | 同上（App 真实引擎，端到端 UI） | 模拟器 iPhone 17 Pro / iPad Pro 11 (M5) | `FairyStudioUITests.testCounterRunIncrementStop` | 通过（iPhone 17 Pro、iPad Pro 11 (M5)） | 2026-09-24 |
| M0-2d | 同上 | iPhone 实机 | 同上，`-destination id=00008140-000E2C523A52801C` | 本包内受阻：签名账户（`No Account for Team "66F6479Y4Q"`）；之后由主代理执行，结果见 verification/M0.md | 2026-09-24 |
| M0-3 | 状态按 idle→validating→preparing→running→stopping→stopped 变化（来自真实事件） | 模拟器 | `testCounterRunIncrementStop` 断言指标面板的状态序列 | 通过：`idle→validating→preparing→running→stopping→stopped`（两台） | 2026-09-24 |
| M0-4 | 修改源码后重新运行，界面变化 | 模拟器 | `testEditSourceAndRerunChangesUI`（真实编辑器键入）；`SwiftRuntimeIntegrationTests.editedSourceChangesUI` | 通过：Count: 0 → 改初始值 → Count: 10 → 11（两台） | 2026-09-24 |
| M0-5 | 文件顺序无关 | macOS 单测 / 模拟器 | `FileOrderAndNameTests`（24 种排列）；`testFileOrderSwapGivesSameResult`；`SwiftRuntimeIntegrationTests.fileOrderIndependence` | 通过（macOS；两台模拟器） | 2026-09-24 |
| M0-6 | 无限循环可停止，停止 ≤250ms | macOS 单测 | `BudgetAndCancellationTests.stopInfiniteLoopWithin250ms` | 通过：最大 1.338 ms（最终回归） | 2026-09-24 |
| M0-6s | 同上（App：点击停止 → 状态已停止） | 模拟器 | `testInfiniteLoopStopLatency`（调试长预算）；`SwiftRuntimeIntegrationTests.infiniteLoopStop` | 通过：App 内「停止→终态」iPhone 6.4 ms、iPad 11.5 ms；协调器单测 0.18–0.20 ms | 2026-09-24 |
| M0-6d | 同上 | iPhone 实机 | 同上 | 本包内受阻：签名账户；由主代理执行 | 2026-09-24 |
| M0-7 | 默认预算下 UI 事件无限循环被中断（interrupted + budgetExceeded） | 模拟器 | `testInfiniteLoopDefaultBudgetInterrupts` | 通过：已中断 + budgetExceeded（sliceWallClock 0.2s）（两台） | 2026-09-24 |
| M0-8 | 连续 30 次运行—停止无残留（实例 / 线程 / 任务 = 0），记录内存 | macOS 单测 / 模拟器 | `thirtyRunStopCyclesReleaseEverything`；`testThirtyRunStopCyclesLeaveNoInstances`；`SwiftRuntimeIntegrationTests.thirtyCyclesLeaveNothing` | 通过：实例/线程/任务 0/0/0，已启动/已释放 30/30；footprint iPhone 57.4→60.8 MB、iPad 56.7→61.1 MB（UI 驱动） | 2026-09-24 |
| M0-8d | 同上 | iPhone 实机 | 同上 | 本包内受阻：签名账户；由主代理执行 | 2026-09-24 |
| M0-9 | 合法但不支持的 Swift → 「运行时尚不支持」+ capability ID，不是名称错误 | macOS 单测 / 模拟器 | `UnsupportedAndCatalogTests`（26+6 种）；`testUnsupportedSyntaxShowsCapabilityID` | 通过：`unsupportedSyntax · syntax.class`，无 nameResolution（两台） | 2026-09-24 |
| M0-10 | 运行时 trap（除零等）→ runtimeTrap 诊断、状态 failed、App 不崩 | macOS 单测 / 模拟器 | `runtimeTrapsBecomeDiagnostics`（8 种）；`testDivideByZeroTrapIsDiagnosed` | 通过：runtimeTrap「除以零」、失败、App 仍在前台（两台） | 2026-09-24 |
| M0-11 | 事件协议：每个终止 stateChanged + finished，stop() 返回前流已结束；生命周期 appear/disappear 只记账 | macOS 单测 / 模拟器 | `ContractAlignmentTests`；`LifecycleInputsTests`；`BridgeLifecycleTests` | 通过（macOS；两台模拟器） | 2026-09-24 |
| M0-12 | 中文输入不丢字、不颠倒（真实引擎 TextField） | 模拟器 | `testFormControlsWithRealEngine`；`BridgeTextFieldTests` | 通过：「你好」「世界」分两批 → `Hello, 你好世界`（两台） | 2026-09-24 |
| M0-13 | 夹具引擎不进入 App 任何构建配置 | 模拟器（generic 构建） | `scripts/check-release-link.sh` | 通过：Release / Debug / Verify-Release / Verify-Debug 均 0 符号；测试包正向对照 1194 个符号 | 2026-09-24 |
| M0-14 | 进入运行耗时（请求运行 → 首个 RenderTree） | 模拟器 | 指标面板 `metrics.startLatency` | 记录：iPhone 135.3 ms（校验 31.5 ms）、iPad 40.9 ms（校验 27.6 ms），Counter 模板 2 文件 | 2026-09-24 |
| M0-15 | 本地模型可用性检测（原样记录系统返回值） | 模拟器 | `FoundationModelsOnSimulatorTests.recordRealAvailability`；`testAIStatusReportsRealAvailability` | 模拟器：`modelNotReady`（宿主 macOS 15.7.4） | 2026-09-24 |
| M0-15d | 同上 | iPhone 实机 | `OnDeviceModelCallTests` | 本包内受阻：签名账户；由主代理执行 | 2026-09-24 |
| M0-16 | 本地模型一次真实调用（实际后端、耗时、响应） | iPhone 实机 | `OnDeviceModelCallTests.realCallOrRecordedReason` | 本包内受阻：签名账户；由主代理执行（模拟器：modelNotReady，按设计未调用） | 2026-09-24 |
| M0-17 | PCC 后端 | 全部 | — | 受阻：SDK 缺失（`pccSDKMissing`）+ 资格与 entitlement 未核对 | 2026-09-24 |
| M0-18 | 产品配置（部署目标 iOS 27.0）运行与测试 | 需 iOS 27 SDK | `xcodebuild -scheme FairyStudio test` | 受阻：无 iOS 27 SDK / 模拟器（仅 generic 目的地可编译） | 2026-09-24 |
| M0-19 | iPad 实机 | iPad 实机 | — | 受阻：iPad Pro 11 (M5) tunnel 不可用；iPad Pro 12.9 为 iOS 18.7.8 | 2026-09-24 |

## M1 项目与编辑器
| # | 条目 | 环境口径 | 命令 / 测试 | 结果 | 日期 |
|---|---|---|---|---|---|
| M1-1 | .mojoproject 包格式与 manifest 字段、稳定 fileID | macOS 单测 | — | 待测 | — |
| M1-2 | ZIP 导入：路径穿越 / 符号链接 / 大小写冲突 / 体积与数量上限夹具全部拒绝 | macOS 单测 | — | 待测 | — |
| M1-3 | 改名不丢历史；快照、修订号、原子写、事务 actor | macOS 单测 | — | 待测 | — |
| M1-4 | security-scoped 访问、文件协调、iCloud 未下载处理 | iPhone / iPad 实机 | — | 待测 | — |
| M1-5 | TextKit 2 编辑器：高亮、缩进、括号匹配、查找替换、撤销重做、诊断定位 | 模拟器 / 实机 | — | 待测 | — |
| M1-6 | 中文输入法 marked text 不被高亮打断；UTF-8→UTF-16 映射 | 模拟器 / 实机 | — | 待测 | — |
| M1-7 | iPhone 三段式 + 抽屉；iPad 自适应多栏 | 模拟器 / 实机 | — | 待测 | — |

## M2 运行时与数据
| # | 条目 | 环境口径 | 命令 / 测试 | 结果 | 日期 |
|---|---|---|---|---|---|
| M2-1 | v1 语言子集（enum、extension、guard、switch、值语义、溢出/除零/越界诊断） | macOS 单测 | — | 部分已在 M0 覆盖；完整子集待测 | — |
| M2-2 | SwiftUI 子集（Image/Slider/Picker/ScrollView/Form/NavigationStack/sheet/alert/动画）真实引擎端到端 | 模拟器 / 实机 | — | 待测（M0 移除夹具后 sheet/alert/导航/Slider 的 UI 端到端暂无真实引擎覆盖，见 M0-C.md） | — |
| M2-3 | 受控异步 .task / onAppear（含 disappear 取消） | macOS 单测 / 模拟器 | — | 待测 | — |
| M2-4 | CapabilityKit 注册与授权链路 | 实机 | — | 待测 | — |
| M2-5 | 业务数据 CRUD / 筛选 / 聚合 / 导出；schema 迁移备份回滚 | macOS 单测 | — | 待测 | — |
| M2-6 | 20 文件 3000 行项目缓存后 ≤2s 进入运行 | 实机 | — | 待测 | — |
| M2-7 | 停止 ≤250ms、30 次运行—停止无泄漏（M2 复测） | 实机 | — | 待测 | — |

## M3 Apple AI 闭环
| # | 条目 | 环境口径 | 命令 / 测试 | 结果 | 日期 |
|---|---|---|---|---|---|
| M3-1 | ModelBroker 任务、上下文预算、工具集 | 实机 | — | 待测 | — |
| M3-2 | 结构化输出（ProjectPlan / FileChangeSet / DiagnosticFixPlan）、expectedBaseHash 冲突拒绝 | 实机 | — | 待测 | — |
| M3-3 | 候选隔离运行、diff 与事务提交、最多两轮修复、取消后迟到结果不落盘 | 实机 | — | 待测 | — |
| M3-4 | 秘密信息检测、Apple-only 网络审计 | macOS 单测 / 实机 | `NetworkAuditTests`（M0 源码审计部分） | M0 部分通过；完整待测 | — |
| M3-5 | 固定评测集 | 实机 | — | 待测 | — |

## M4–M7
| # | 条目 | 环境口径 | 命令 / 测试 | 结果 | 日期 |
|---|---|---|---|---|---|
| M4-1 | 三个真实可运行模板项目；调试器 console/调用栈/受限单步 | 模拟器 / 实机 | — | 待测 | — |
| M5-1 | WKWebView 隔离、CSP、导航策略、消息桥校验、内容进程终止恢复 | 实机 | — | 待测 | — |
| M5-2 | CSV 分析台、检查表、音频调度与传感器、节拍器、网页模板 | 实机 | — | 待测 | — |
| M6-1 | PDF / HTML / PPTX 导出（结构校验）、Markdown 讲稿 | macOS 单测 / 实机 | — | 待测 | — |
| M6-2 | 版本恢复、多窗口 ProjectStore 冲突、外接显示器演示 | iPad 实机 | — | 待测 | — |
| M6-3 | VoiceOver / Dynamic Type / Reduce Motion | 模拟器 / 实机 | M0-B 做过深色 + accessibility-large 的 UI 冒烟 | M0 部分；完整待测 | — |
| M7-1 | 设备矩阵、安全回归、性能、AI 评估、许可、审核材料、发布构建 | 全部 | — | 待测 | — |
