# RuntimeContracts 变更记录

## 2026-09-24 M0 合并后（主代理裁决 docs/CONTRACT_REQUESTS.md 中 B-1…B-7、CR-1…CR-7）
| 请求 | 裁决 | 契约改动 |
|---|---|---|
| B-1 DevFixtures target | 保留在 Package.swift；App 正式路径在 M0-C 移除夹具，DevFixtures 只供测试目标 | 无 |
| B-2 导航约定 | 接受 NativeBridge 的解释 | RenderKind 注释 |
| B-3 sheet 关闭 | 用户手势 → `.action(dismiss)`；`.dismissSheet` 仅宿主强制关闭 | RenderKind 注释 |
| B-4 alert 无 action 按钮 | 采用 (a)：运行时保证每个按钮都有 action（合成关闭 action） | RenderKind 注释 |
| B-5 / CR-2 生命周期 | 宿主触发，运行时不自动触发；宿主发 `.action(id)` 执行闭包，另发 `.appear/.disappear(NodeID)` 记账 | RenderModifier 注释 |
| B-6 样式字符串 | M1 改枚举 | 注释 |
| B-7 事件流结束 | `stop()` 返回前 events 必须 finish；stateChanged 与 finished 都发 | RunHandle 注释 |
| CR-1 校验失败终止 | 新增 `ExitReason.validationFailed` | **新增 case**（SwiftRuntime 与 RunCoordinator 在 M0-C 同步） |
| CR-3 预算计量 | 写入文档注释 | ExecutionBudget 注释 |
| CR-4 调用栈 | 推迟到 M2 调试器（届时增加 `related`/`callStack`） | 无 |
| CR-5 started() | 不加；宿主等待首个 `.render` | 无 |
| CR-6 ID 格式 | 声明不透明 | Identifiers 注释 |
| CR-7 RunOptions | 记录，M3 候选运行使用 | 无 |

## 2026-09-24 M0-C 实现对齐（RuntimeContracts 未改动）
按上表裁决对齐双方实现，契约源码无变更：
| 裁决 | SwiftRuntime | NativeBridge / App | 测试 |
|---|---|---|---|
| CR-1 / B-7 终止事件 | 校验失败（含入口无效）发 `stateChanged(.failed)` → `finished(.validationFailed)`；预算超限改为 `stateChanged(.interrupted)`（原为 failed）；`stop()` 返回前兜底 `finish()` 事件流 | RunCoordinator 在自身校验失败时记 `exitReason = .validationFailed`；状态机只前进（忽略引擎启动时重复的 validating / preparing 与重复的 stopping） | `ContractAlignmentTests.everyTerminationHasStateChangedThenFinished`、`stopFinishesEventStreamBeforeReturning`；`EntryPointTests.validationFailureEndsStreamWithFailedState` |
| B-5 / CR-2 生命周期 | `.appear/.disappear(NodeID)` 只记账（`appearedNodes`），不执行用户代码、不重新渲染；闭包只由 `.action` 执行 | `LifecycleInputs` + `LifecycleHooks`：出现时 `.appear(NodeID)` + 各 onAppear 的 `.action`；task 启动时 `.action`；消失时各 onDisappear 的 `.action` + `.disappear(NodeID)`；每节点只挂一次 | `ContractAlignmentTests.appearAndDisappearOnlyRecordLifecycle`；`LifecycleInputsTests`（macOS，含 NSHostingView 真实挂载）；`BridgeLifecycleTests`（iOS 模拟器 UIHostingController 挂载/移除） |
