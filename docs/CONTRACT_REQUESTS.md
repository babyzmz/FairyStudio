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
