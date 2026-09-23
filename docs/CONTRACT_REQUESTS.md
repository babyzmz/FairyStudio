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
