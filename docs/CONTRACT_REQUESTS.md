# 契约与共享文件变更请求

M0 期间 RuntimeContracts 冻结；需要改动或需要主代理裁决的事项写在这里。

---

## M0-B（App / NativeBridge / FoundationAI）— 2026-09-23

### B-1 Package.swift：新增 DevFixtures 目标（已在 M0-B 工作区临时修改，合并时需保留）

M0-B 只改了两行（新增产品与目标），没有改其他任何内容：

```swift
// products:
        // M0-B：夹具引擎，仅供测试目标与 Verify-Debug 构建链接，Release 绝不链接（见 docs/progress/M0-B.md）。
        .library(name: "DevFixtures", targets: ["DevFixtures"]),
// targets:
        .target(name: "DevFixtures", dependencies: ["RuntimeContracts"]),
```

App 侧的条件链接方式（不需要 Package.swift 配合）：`project.yml` 中 DevFixtures 以 `link: false` 作为构建依赖，
只有 `Verify-Debug` 配置通过 `OTHER_LDFLAGS += $(BUILT_PRODUCTS_DIR)/DevFixtures.o` 链接；`scripts/check-release-link.sh` 校验 Release / Verify-Release / Debug 不含。
M0-C 移除夹具时：删除上述两行、`Sources/DevFixtures`、project.yml 中的 DevFixtures 依赖与 `OTHER_LDFLAGS`、App 中 `#if FAIRY_VERIFY_BUILD && DEBUG` 分支。

### B-2 导航约定（请确认，NativeBridge 已按此实现）

契约只写了 `navigationStack // children[0] = root` 与 `navigationDestination(NodeID) // 由 runtime 推入的目标页面节点`。NativeBridge 的解释：
- `navigationStack.children[0]` 是根页面；其后按顺序出现的 `.navigationDestination(id)` 子节点构成**当前路径**（运行时是唯一权威）；目标页面内容 = 该节点的 children。
- `navigationLink(destinationID:)` 点击只发送 `.navigationPush(destinationID:)`，不在本地先行推入；运行时接受后在树中加入对应 destination。
- 用户返回手势 / 返回按钮：发送 `.navigationPop(count:)`（弹出的层数）。
- 请求：在契约注释中写明上述约定，避免 SwiftRuntime 另作解释。

### B-3 sheetHost 关闭时发送哪个输入（请裁决）

`sheetHost(isPresented:dismiss: ActionID)` 自带 dismiss action，同时 `RuntimeInput` 另有 `.dismissSheet`。NativeBridge 目前在用户下滑关闭时发送 `.action(dismiss)`，**不**发送 `.dismissSheet`。
建议：二选一，删除另一个或注明用途（例如 `.dismissSheet` 仅用于宿主强制关闭）。

### B-4 alertHost：无 action 的按钮关闭后运行时无从得知（请求补充）

`AlertButton.action` 可为 nil。用户点这样的按钮后 SwiftUI 关闭 alert，但没有任何输入告诉运行时 `isPresented` 应变为 false；
NativeBridge 用本地呈现状态避免重复弹出，但运行时状态与界面会不一致。
建议：(a) 运行时保证每个按钮都有 action；或 (b) 新增 `RuntimeInput.alertDismissed(NodeID)`。

### B-5 onAppear / onDisappear / task 与 appear/disappear 输入的关系（请确认）

NativeBridge 按任务书把 `.onAppear(ActionID)` / `.onDisappear(ActionID)` / `.task(ActionID)` 映射为 `.action(id)`；
`RuntimeInput.appear(NodeID)` / `.disappear(NodeID)` 目前未被使用。另外 `.task` 在视图消失时没有“取消”输入，运行时无法取消对应异步任务。
建议：明确 appear/disappear(NodeID) 的用途；为 task 增加取消语义（例如消失时发送 `.disappear(nodeID)` 或新增 `.taskCancelled(ActionID)`）。

### B-6 样式字符串（建议 M1 改为枚举）

`buttonStyle(String)` / `textFieldStyle(String)` / `listStyle(String)` 使用字符串。NativeBridge 接受：
buttonStyle = bordered / borderedProminent / plain / borderless；textFieldStyle = roundedBorder / plain；listStyle = plain / inset / sidebar / insetGrouped / grouped（后两者仅 iOS）。
未知字符串不会被静默忽略：节点上叠加可见的「无效参数」标记。建议后续契约改为枚举，让非法值在运行时侧就被诊断。

### B-7 其他需要运行时保证的前提

- `picker.options` 的 `tag` 必须互不相同（桥接以 tag 作为 ForEach 身份）。
- `progressView.value` 按 0…1 的比例解释，桥接会夹到该区间；非有限值按不确定进度显示。
- `slider` 需 `lower < upper` 且两端有限，否则桥接显示可见占位。
- `ImageSource.resource(name)`：M0 无项目资源存储，桥接显示可见占位（能力 ID `view.Image.resource`），M1 ProjectCore 接入后实现。
- `RunHandle.events`：请在 `stop()` 返回前关闭事件流（`finish()`）。RunCoordinator 最多等 1 秒，超时会记录 internalError 诊断。
- 引擎只发 `finished(reason)` 而不发 `stateChanged` 时，RunCoordinator 用固定映射：completed / stoppedByUser → stopped，budgetExceeded → interrupted，trap / internalError → failed。建议 SwiftRuntime 两者都发。

---
# 契约变更请求（M0 期间契约冻结，由主代理裁决）

## CR-1（M0-A）校验失败的终止事件
- 现状：`ExitReason` 没有"校验失败"。SwiftRuntime 在 `run()` 遇到编译错误时发出 `validating → diagnostic… → stateChanged(.failed)`，然后结束事件流，**不发 `finished`**。
- 请求：增加 `ExitReason.validationFailed`，使 `finished` 成为所有运行的统一终止事件。
- 绕过：宿主以"事件流结束 + 最后状态为 failed"判定终止。

## CR-2（M0-A）onAppear / task 的触发方
- 现状：运行时把 `.onAppear/.onDisappear/.task` 映射为 `RenderModifier.onAppear(ActionID)` 等，但**不自动触发**。
  宿主在 SwiftUI 的 onAppear 回调中发送 `.appear(NodeID)`（或 `.action(对应 ActionID)`，二者等价）。
- 请求：在契约注释中写明"由宿主触发、运行时不自动触发"，避免双方都触发导致执行两次。

## CR-3（M0-A）ExecutionBudget.maxSteps 的计量范围
- 现状：`maxSteps` 按"执行单元"计：脚本入口为整个脚本；UI 入口为每次初次渲染、每次输入处理（含随后的重新渲染）。
  `sliceWallClock` 在脚本入口是让出点，在 UI 事件中是硬上限。
- 请求：把以上语义写入 `ExecutionBudget` 的文档注释。

## CR-4（M0-A）诊断的调用栈 / 附加位置
- 现状：`Diagnostic` 只有一个 `range`；运行错误只能指向出错语句，消息里附带函数名。
- 请求（非阻塞，M2 调试器需要）：增加 `related: [SourceRange]` 或 `callStack: [String]`。

## CR-5（M0-A）RunHandle 等待启动完成
- 现状：协议只有 `events/send/stop`。`SwiftRunHandle` 额外提供 `waitUntilStarted()`、`currentActionIDs()`（CLI/测试用）。
- 请求（可选）：若 RunCoordinator 需要"等初次渲染完成"，建议协议增加 `func started() async`；目前可通过等待第一个 `.render` 事件实现。

## CR-6（M0-A）ActionID / BindingID / NodeID 的格式
- 现状：`NodeID` = 视图身份路径（如 `root/ContentView/c.1/c.0`）；`ActionID` = `runToken|NodeID|action`；`BindingID` = `runToken|NodeID|text`。
  宿主应只把它们当不透明字符串。
- 请求：契约注释中声明"不透明、同一 runID 内跨渲染稳定"。

## CR-7（M0-A）RunOptions 字段
- 现状：`isCandidate`、`enableTracing` 在 M0 未使用（运行时没有宿主副作用，也没有追踪）。无需改动，仅记录。
