# 页面重构 P0：基线与状态契约（审计报告）

版本：P0 · 2026-09-30 · 依据《页面重构与运行中更新设计计划 v1.0》
退出条件：可复现当前行为 ✓；无覆盖用户修改 ✓（守卫在位 + 新增测试锁定）；状态契约明确 ✓（本文件 + StateContract.swift）。

## 1. 现状清单（页面 / 路由 / 状态）

### 页面与路由

| 现状 | 位置 | 计划归属 |
|---|---|---|
| 作品库首页（最近项目/模板/新建/导入，硬编码三模板已改动态发现+分类） | App/Views/LibraryView.swift | LibraryFeature（P1 重排：网格+缩略图、导入合并菜单、模板详情） |
| 工作区三面板（侧栏会话历史 / 中聊天 / 右运行预览+代码分段） | App/Workspace/WorkspaceView.swift | WorkspaceShell + ArtifactStage（P1：作品为主舞台、聊天移右栏、按需文件/历史/诊断） |
| 助手侧栏+设置（三后端选择、OpenRouter Key/连接测试/模型选择） | App/Assistant/AssistantSidebarView.swift | AssistantPanel（P2：任务流/改动卡/输入器/模型菜单） |
| 对话流/输入器/改动卡/诊断卡 | App/Assistant/ChatView.swift、ChangeCardView.swift、DiagnosticCardView.swift | AssistantPanel（P2 迭代） |
| 预览渲染（RenderTree → 原生组件） | App/Views/LabPanes.swift + Packages/NativeBridge | ArtifactStage（P1：布局预览、空态分型） |
| 旧 AI 状态页（App/AI/AIStatusModel+View） | 已不被主流程引用，仍编译 | P1 移除或并入诊断二级入口 |

### 状态原语（P0 前的事实来源）

| 轴 | 既有原语 | 缺口 |
|---|---|---|
| 生成 | `session.isResponding` + 流式消息 + 收尾 system 消息 | 阶段（receiving/validating/…）不可观察、取消/失败要靠文本推断 |
| 运行 | `RunState`（RuntimeContracts：idle/validating/preparing/running/stopping/stopped/failed/interrupted）+ RunCoordinator 事件去重（旧 RunID/sequence/revision 倒退丢弃） | 无 |
| 更新 | `AssistantCardStatus`（pending/applying/applied/expired/applyFailed/discarded）散落在消息里 | 无会话级汇总，UI 需自行扫描消息 |

## 2. 基础哈希填入时机审计（计划 §8.5 点名项）

**结论：合规。** 证据链（file:line 以当前工作树为准）：

1. `AssistantSession.runTurnFlow` 在任何模型调用**之前**取 `project.snapshot()`（AssistantSession.swift:359）——该快照即生成基线；
2. `AssistantTurnInput.snapshot` 携带这份冻结快照进入管线；
3. `ProposeChangesTool.buildChangeSet` 的哈希回填来源是 `input.snapshot` 中的文件哈希（AssistantTools.swift `hash(op.expectedBaseHash, or: file.hash)`）——**不是**回答到达时重读的最新文件；
4. 修复轮与 `[[MORE]]` 续作各自重新进入 `runTurnFlow` → 重新冻结基线（语义正确：新轮次 = 新基线）；
5. 应用前的双保险：`applyAndRun` 校验 `fresh.revision == pending.changeSet.baseRevision`（AssistantSession.swift:494），过期 → 卡片 `.expired` + 明确提示；底层 `ProjectStore.apply` 再做一次哈希/修订校验。

新增测试锁定：`StateContractTests.expiredCandidateDoesNotOverwriteUserEdits`（候选待确认期间推进项目修订 → 应用被阻断 `.blocked`，用户内容逐字节不变）。

## 3. 状态契约（本次落地：App/Workspace/StateContract.swift）

- **GenerationState** idle/receiving/validating/waiting/cancelled/failed——会话现以事件回写（send→receiving、proposed 未自动应用→waiting、failed→failed、cancel→cancelled、成功收尾→idle）。缺口：`validating` 阶段需管线回调，列 P2。
- **RuntimeState** stopped/starting/running/stopping/interrupted/failed——`init(from: RunState)` 一对一映射，无新事实来源。
- **UpdateState** none/ready/applying/applied/blocked/failed/discarded——`init(from: AssistantCardStatus)`，`setCardStatus` 统一回写会话级 `updateState`。
- **版本关系** `WorkspaceVersionRelationship`：saved（工作副本修订）/ running（实际运行实例修订，本次新增记录：apply 成功后写 `runningVersion = candidate.revision`）/ candidateBase（候选基线）。生成基线 = 候选 baseRevision 的来源快照。四版本中"生成基线"与"候选版本"在候选结构里已隐含（baseRevision/candidate.revision），P1 起随改动卡 UI 显式展示。

已知边界（如实）：`runningVersion` 目前只覆盖 AI 应用后运行；手动运行（WorkspaceModel.run）的版本记录列 P1；`validating` 阶段回调列 P2。

## 4. 与计划条文的差距清单（P1–P5 最小修改顺序）

### P1 视觉与结构
1. LibraryFeature：作品网格+最近成功版本缩略图（缩略图来源=用户明确运行后的 RenderTree 快照，存档于项目 `Data/`，不做后台批量渲染）；模板独立入口+详情；导入合并菜单。动 LibraryView.swift（重排）+ ProjectStore（缩略图存档）。
2. WorkspaceShell：作品为主舞台（65–72%）+ 助手右栏（320–380pt）；"作品|代码"分段进顶栏；文件/历史/诊断按需抽屉。动 WorkspaceView.swift（布局重排，聊天与预览换位）。
3. DesignSystem：token（§10.2 色板/字号/间距）落地 App/DesignSystem/。
4. 空态分型（新项目/可信已有/导入/失败）按 §4.4。

### P2 助手创作体验
1. 管线阶段回调：`AssistantPipeline.runTurn` 增加 `onPhase: (GenerationState) -> Void`（perform 开始=receiving、解析后=validating、候选就绪=waiting），会话转接——补齐契约缺口。
2. 输入器改造（3→6 行、上下文标签、附件占位、发送↔停止生成切换）；模型菜单三分区（修正 nvidia/ 前缀——现目录 `vidia/…:free` 拼写待用户确认或实时目录核对）；任务串行化提示（排队/补充/取消）。
3. "仅讨论"模式（不提交变更）。
4. 失败文案三段式（发生了什么/作品是否受影响/下一步）。

### P3 受控更新
1. LiveUpdateCoordinator 最小实现：候选与运行实例解耦——改动卡应用前运行实例保持旧版本（**现状已满足**：apply 在 run 之前、run 失败不影响已应用源码——需测试锁定）。
2. 更新策略菜单（手动确认/自动兼容/暂停更新）替代 `autoRunOnValidated` 单开关；首次导入默认手动。
3. 历史时间线（任务、模型、已运行版本）+ 命名检查点 + 代码恢复不回滚业务数据（恢复=源码事务，Data/ 不动）。
4. 失败恢复：原实例已停止时如实显示"可恢复"。

### P4 兼容热更新与选择
1. SelectionBridge：RenderNode → (fileID, sourceRange) 映射（解释器 IR 已有节点来源信息基础，需在 ViewBuiltins/RenderTree 携带 sourceRange）；缺映射时如实降级为源码范围选择。
2. 兼容分级（§8.2）：首版只交付"检查后重建"；文字/颜色类保状态更新在状态映射测试成熟后单独放行。
3. 安全交互点：输入法组合/拖动期间延迟切换（配合 UI 层信号）。

### P5 打磨
键盘避让复核、VoiceOver 双停止名称、44pt 命中区、Reduce Motion、分屏不重置状态、多窗口单写者限制。

## 5. 不可变约束（重申）

- 保留 SwiftRuntime、能力目录、ProjectStore、三后端、Keychain、取消与权限测试；
- 不用 `.id(UUID())` 伪装保状态；不以截图冒充运行；不用定时器伪造阶段；
- 每阶段以真实项目截图 + 事件 + 测试日志验收；mock 与真实 API 结果分开报告。
