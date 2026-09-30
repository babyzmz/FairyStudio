# AI 改码工作流（W2）

> 后端：设备端（agent 工具循环）、Apple 云端（PCC，待资格）、OpenRouter（用户自配云端，
> 见 docs/OPENROUTER.md）。三后端独立授权，绝不自动回退；改码闭环与校验回喂对所有后端一致。

上下文组装 → 模型 → `FileChangeSet` → 内存预览 → 候选校验 → 变更卡片 → 应用运行 → 失败回喂（最多 2 轮）。

代码：`Packages/FairyCore/Sources/FoundationAI/AssistantPipeline.swift`（纯逻辑，可单测）、
`AssistantTools.swift`（工具）、`AssistantProposal.swift`（`ProposedChangeSet`）、
`App/Assistant/AssistantSession.swift`（编排）、`App/Assistant/*.swift`（UI）。

## 1. 上下文组装（`AssistantPromptBuilder`）

顺序固定，预算逐级裁剪（见 §5）：

1. 规则头：只改必要文件；回复格式 = 一句话说明 + 一个 ` ```json {"operations":[...]}` 块；
   既有文件用 fileID；`expectedBaseHash` 可省略；只用 supported / partial 能力；无需改码则纯文本回答。
2. 待修复的诊断（修复轮才有）。
3. 用户需求原文。
4. 项目文件列表：`ListFilesTool`（path + id + hash 前 12 + 行数；L1 起只留签名）。
5. 当前打开文件全文（`session.selectedPath`，W1 编辑器设置；各预算级都保留）。
6. 能力目录摘要：`ReadCapabilityTool`，条目由 App 层经 `SwiftRuntimeEngine.catalog` 注入
   （FoundationAI 不依赖 SwiftRuntime），supported / partial 在前，按行数截断。
7. 最近诊断：`ReadDiagnosticsTool`（`coordinator.diagnostics` + 控制台尾部，只读）。
8. 最近 N 轮对话（默认 6，用户/助手文本，助手截断 500 字）。

## 2. 模型输出（`ProposedChangeSet`）

```json
{"operations": [
  {"action": "replace", "fileID": "f1", "contents": "…", "note": "改按钮文字"},
  {"action": "create", "path": "Sources/NewView.swift", "contents": "…", "note": "新建"}
]}
```

- action：create | replace | rename | delete；rename 另需 `newPath`。
- 既有文件优先 fileID（改名不变），其次 path；找不到 → `parseFailed`，不建卡。
- `expectedBaseHash` 省略时，`ProposeChangesTool.buildChangeSet` 自动填入快照读取时的哈希；
  模型手填且与快照不符 → 预览/提交时整个 ChangeSet 被拒绝（原子）。
- 无 JSON 块 = 纯文本回答（`noChange`），只显示助手消息，不建卡。
- 有 FoundationModels SDK 的 Xcode 构建中本结构带 `@Generable`（Xcode 27 SDK 已核实，
  见 `docs/APPLE_MODELS.md` §8）；SPM 构建（部署目标 macOS 15，`@Generable` 要求 26+）
  退化为纯 Codable，走 JSON 解析路径。条件用 `SWIFT_PACKAGE` 区分，不猜 SDK 版本。

## 3. 预览与校验

1. `ChangeSetPreview.apply(changeSet, to: snapshot)` 内存演算出候选快照（不落盘）。
   `hashMismatch` / `revisionMismatch` → 直接失败并提示"请重新读取项目后重试"，不自动重发。
2. `AssistantValidating.validate(candidate.program)` 校验候选程序。
   生产注入 coordinator 持有的引擎（即 SwiftRuntimeEngine，经 `RunCoordinatorValidator` 取
   `coordinator.engine`，App 层无新增依赖）；单测注入假 validator。
3. 无 error 诊断 → `PendingChange`（changeSet + 候选快照 +逐文件 +/−行 + validation +
   已用修复轮数 + 上次错误签名 + 是否裁剪过上下文）。

行数统计（`AssistantDiff`）：新旧行数组裁掉前后公共行，中间计 +/−；内容相同计 0/0。

## 4. 应用运行与回喂

- `autoRunOnValidated`（默认 true）：校验通过即 `project.apply` + `coordinator.run`；
  关闭时先出变更卡片，等用户点"应用并运行"。
- 应用前重读快照：`baseRevision` 不一致 → 卡片标过期，不提交。
- 提交被 `hashMismatch` / `revisionMismatch` 拒绝 → 卡片标过期，提示重新读取。
- 运行后等终态（30 秒上限）读 `coordinator.diagnostics`：
  无 error → 卡片标已应用（有警告则附诊断卡）；
  有 error → 附诊断卡，按错误签名走 `RepairTracker`：
  - 相同签名再次出现 → 停（无进展）；
  - 已用 2 轮 → 停，显示剩余问题；
  - 否则带着新快照 + 运行诊断自动修一轮（`repairContext` 进 prompt 最前）。
- 校验失败的修复（未应用前）由 pipeline 内部同规则完成，最多 2 轮；
  运行失败的修复由 session 递归，两者共用计数（`repairRoundsUsed` / `lastErrorSignature`
  在 `PendingChange` 中透传）。

## 5. 上下文预算（不写死容量）

`exceededContextWindowSize` 触发时退避，不消耗修复轮数：

- full → signaturesOnly：文件列表只留签名（path + hash 前缀），能力摘要截到 20 行；
- signaturesOnly → noHistory：再去掉旧轮次，诊断只留错误行；
- 退过级时同时注入"输出约束"提示（上下文是输入与输出共享的，光缩输入救不回长输出）；
- 无可退 → `contextOverflow` 失败。
- 退过级即标记，UI 显示"已裁剪上下文"。

## 6. 取消与代次

- 同一会话单在途：`send()` 先取消旧任务（`broker.cancelCurrentTask()` + Task 取消），
  新代次 UUID 写入 `CurrentGeneration` 盒。
- 流式更新、最终落卡/应用前都校验代次：过期代次静默丢弃（迟到结果不落盘、不建卡）。
- pipeline 内 `perform` 返回后即 `Task.checkCancellation()`，取消不再做解析/演算/校验。
- 用户取消恰好落在 `apply` 成功之后：如实标已应用，提示"未运行"，不再启动运行。

## 7. 状态机（变更卡片）

```
pending → applying → applied
              ├→ expired（修订过期 / 哈希拒绝）
              └→ applyFailed（其他提交错误）
pending → discarded（用户放弃）
```

消息流：user → assistant（流式）→ change 卡 / diagnostics 卡 / system 状态。
`initialPrompt`（首页"描述需求创建"）首次填入输入框并提示发送，不自动发送。

## 8. 输出截断与自动续写（2026-09-28）

端上模型上下文约 4K tokens（输入与输出共享），创建项目 / 大改动的长 JSON 会在半途断掉。
输出上限已提到 `contextSize`（见 docs/APPLE_MODELS.md §9），窗口本身仍是硬墙，
因此管线（`AssistantPipeline.generateComplete`）带截断续写：

- **检测**（`looksTruncated`）：裸 `{` 开头 JSON 不合法；有 ```json 块时，闭合块看块内
  JSON 能否解析、未闭合块取首个围栏之后到末尾尝试解析（内容完整只缺闭合围栏不算截断）。
  用 `JSONSerialization` 而非 Decodable——字段名错误是 parseFailed，不是截断。
- **续写**：带已输出全文（每次请求都是新会话，模型无记忆）要求"从结尾直接接着写、
  不要重复、不要围栏"；拼接时剥掉片段自带的围栏行，不加分隔符（截断常发生在 JSON
  字符串内部），按需补闭合围栏。最多 2 轮（`maxContinuations`），无进展即停。
- **仍不完整**：报 `outputTruncated`（"请把需求拆小：一次只改一个文件，或分几条消息"），
  不误走纯文本 / 解析失败路径。
- **预防**：基础指令要求输出精简、大改动拆多轮（每轮一个文件）、新建项目每文件 ≤ 50 行。

## 9. Agent 工具循环（设备端，2026-09-28）

设备端后端不再依赖"模型一次性吐 JSON"（端上小模型不守格式 → 只回话不动手）：
`App/Assistant/AgentRunner.swift` 把真实 `FoundationModels.Tool` 挂进会话：

- `listFiles` / `readFile` / `readCapability` / `readDiagnostics`：模型主动读项目与能力目录；
- `proposeChanges`：提交结构化文件操作，**可多次调用**（每个文件一次，单次很小），
  累计后序列化成 ```json 块交给 `AssistantPipeline` —— 解析 / 预览 / 校验 / 修复回喂 /
  变更卡片 / autoRun 全部与文本路径共用；
- 工具调用事件实时回显到对话气泡（"已提交 2 个操作：…"）；
- 云端后端与单测仍走纯文本路径（`AgentPerforming` 注入，测试用假件）。

## 10. 多文件自动续作（[[MORE]]，2026-09-28）

目标：让本地模型完成"从需求描述创建完整多文件项目"（AI_EVAL 固定任务及同类）。
端上模型单轮输出有限，多文件任务必须分批；之前需要用户手动回复"继续"，现在自动：

- **协议**：模型在回复最末尾单独输出 `[[MORE]]` 表示"还有下一批"；全部完成则不输出。
  两条路径的指令都已定义（文本路径 prompt / agent 路径 instructions）。
- **会话编排**（`AssistantSession.maybeAutoContinue`）：`AssistantTurnOutcome.modelTail`
  携带回复尾部；proposed 路径在 **apply+run 成功后**才续作（下一批基于新修订，避免过期哈希）；
  noChange 路径直接续作（显示文本剥掉标记）。自动发"继续"，上限 3 轮防失控，
  达到上限提示手动回复"继续"；手动发送重置计数；取消 / 切会话自然终止。
- **未开 autoRun 时不自动续作**（用户手动应用期间下一批会基于旧修订产生过期卡片）。
