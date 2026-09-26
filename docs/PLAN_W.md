# 阶段 W：整合开发（先把大致功能做出来，再按 M1–M5 细化验收）

用户 2026-09-27 的方向调整：不再按里程碑逐个打深，而是先把产品主干整合起来——自由多文件工作区、模型对话直接改代码并运行、模板、网页项目、数据与导出的雏形——让 App 作为一个完整产品可用；之后再按 M1–M5 逐项细化到任务书的验收深度。M0 已完成的部分（解释器、桥接、协调器、模型可用性）全部沿用。

界面方向：不要"调试台"观感。运行页只有代码、预览、运行/停止；诊断、控制台、模型对话统一进入右侧/底部的「助手」面板；首页是作品库。遵循系统控件、清晰层级、适度材质，代码区高对比。

## 共享契约（已定义）
- `RuntimeContracts`：运行事件、RenderTree、引擎协议（M0）。
- `ProjectContracts`（新）：`ProjectSnapshot` / `ProjectFileSnapshot(hash)` / `FileChangeSet(baseRevision, operations[create|replace|rename|delete with expectedBaseHash])` / `ProjectAccess` 协议 / `ChangeSetPreview`（内存演算 + 路径校验 + 上限）。**AI 与 UI 都只通过 `ProjectAccess` 读快照、提交 ChangeSet。**

## 工作包与所有权

### W1 项目存储 + 工作区（App 主体）
所有权：`Packages/FairyCore/Sources/ProjectCore/**`、`Tests/ProjectCoreTests/**`、`App/**`（除 `App/Assistant/**`）、`Templates/**`、`project.yml`、`Tests/FairyStudio*Tests/**`（除 Assistant 相关）、`docs/PROJECT_FORMAT.md`、`docs/progress/W1.md`。
交付：
1. **ProjectCore**：`.mojoproject` 文档包（`project.json` manifest：projectID、schemaVersion、runtimeVersion、languageProfile、moduleName、entryKind、entryFile/entrySymbol、sourceRoots、resourceRoots、dataSchemaVersion、requestedCapabilities、templateID；`Sources/ Resources/ Documents/ Data/ Tests/`）；文件表带稳定 fileID（改名不变）；`actor ProjectStore: ProjectAccess`：原子写（临时目录 + replaceItemAt）、修订号、写前记录、幂等 changeSetID、上限检查、`snapshots()` 推送；`ProjectLibrary`：Documents/Projects 下枚举、新建空白、从模板创建、复制（新 projectID）、删除（说明连同快照/数据）、重命名、导入单个 `.swift`（托管工作区，不改原文件）、导入/导出 ZIP（路径穿越、符号链接、大小写冲突、体积与数量限制）。
2. **首页「我的作品」**：最近项目、模板、新建（描述需求创建 → 打开工作区并把描述交给助手；空白 Swift 项目；导入）。作品卡：名称、运行类型、最后修改时间、兼容性状态（runtimeVersion 对比）。
3. **工作区**：文件树（新建/改名/删除文件与目录、拖放到目录）、多标签编辑器（沿用 `CodeTextView`，未保存标记、⌘S 保存、切换标签不丢光标）、预览区、运行/停止（⌘R/⌘.）始终可达；iPhone「作品 / 代码 / 助手」三段切换 + 文件树抽屉；iPad 按窗口宽度：宽 = 文件树 + 编辑器 + 预览，助手为可切换侧栏；窄 = 双栏/单栏。键盘弹出不遮挡运行与助手输入。
4. **助手面板槽位**：工作区提供 `AssistantPanelHost(project: any ProjectAccess, coordinator: RunCoordinator, library: ProjectLibrary)` 位置；在 W2 合并前放一个明确标注的占位视图（不是假对话）。运行时诊断与控制台由 `RunCoordinator` 暴露，不再在运行页显示抽屉。
5. **模板**：`Templates/<id>/template.json + Sources/...`；Counter 成为一个模板；再加两个能在当前解释器上真实运行的模板（例如"参数可调的计算演示"与"待办清单"）。
6. UI 测试：新建项目 → 新建第二个文件 → 编辑 → 运行 → 改名文件 → 重跑一致 → 删除文件 → 诊断显示；导入 ZIP 攻击夹具被拒绝；iPhone 与 iPad 布局各一条。

### W2 模型对话 + 改码闭环（Assistant）
所有权：`Packages/FairyCore/Sources/FoundationAI/**`、`Tests/FoundationAITests/**`、`App/Assistant/**`（新）、`Tests/FairyStudioTests/Assistant*`、`docs/APPLE_MODELS.md`、`docs/AI_WORKFLOW.md`、`docs/progress/W2.md`。
交付：
1. **AssistantSession（actor/@MainActor 模型）**：对话消息（用户、助手文本流、变更卡片、诊断卡片、系统状态）；每个会话一个在途请求、可取消；后端选择（设备端默认；云端首次确认，PCC 缺失时禁用并显示原因）。
2. **工具**（FoundationModels `Tool`，本项目自定义，不冒充 Apple API）：`listFiles`、`readFile(path|fileID, range?)`、`searchSymbols(query)`、`readCapability(topic)`（从 SwiftRuntime capability catalog 取子集摘要）、`readDiagnostics()`（最近一次运行）、`proposeChanges(FileChangeSet 结构)`。模型输出 **结构化 FileChangeSet**（`@Generable` 结构：operations 数组，含 path/fileID、expectedBaseHash 由工具侧自动填充为读取时的哈希、新内容、说明）。
3. **闭环**：用户消息 → 上下文（项目摘要：文件列表与签名摘要、当前打开文件、能力目录摘要、最近诊断、最近 N 轮对话）→ 模型 → ChangeSet → `ChangeSetPreview.apply` 内存演算 → `SwiftRuntime.validate` 候选程序 → 变更卡片（文件、+/- 行、说明；"应用并运行" / "查看差异" / "放弃"）。设置项「模型修改后直接运行」（默认开）：校验通过即 `ProjectAccess.apply` 并 `RunCoordinator.run`。校验或运行失败：把诊断回喂模型，自动修复最多 2 轮，相同错误/无进展即停止并显示剩余问题。用户取消后迟到结果不落盘；基于旧哈希的补丁被 `apply` 拒绝并提示重新读取。
4. **预算**：不写死上下文容量；按 `exceededContextWindowSize` 错误做退避（缩短文件摘要、去掉旧轮次），显示"已裁剪上下文"。
5. **Assistant UI**：对话流（气泡、流式文本、变更卡片、诊断卡片可展开定位到文件行）、输入框（多行、发送/取消）、顶部后端与状态胶囊（设备端 / Apple 云端 / 不可用+原因）、"诊断与控制台"折叠区（从运行页迁入）。深浅色、Dynamic Type。
6. 评测：`Tests/FoundationAITests` 用假的 `ModelBackendDriver` 回放模型输出验证闭环逻辑（哈希拒绝、取消、两轮上限、校验失败回喂）；实机上用 3 个固定任务（改按钮文字、加一个字段、新建一个 View 文件）记录真实可运行率与耗时到 `docs/AI_EVAL.md`（未跑写待测）。

### W3 解释器广度（让模型生成的常见代码更可能跑起来）
所有权：`Packages/FairyCore/Sources/SwiftRuntime/**`、`Sources/fairy-run/**`、`Tests/SwiftRuntimeTests/**`、`Sources/NativeBridge/**`（仅补组件映射）、`docs/SWIFT_SUPPORT.md`、`docs/RUNTIME_DESIGN.md`、`docs/progress/W3.md`。
交付（按优先级，逐项进 catalog 与测试）：Image(systemName:)、Slider、Picker、Stepper、ScrollView、Form/Section、NavigationStack + NavigationLink + navigationDestination（按契约 B-2）、sheet/alert（按 B-3/B-4）、Spacer/Divider 已有；`.task`/`.onAppear` 同步子集完善；enum 关联值 + switch 模式匹配；tuple 解构；带 setter 的计算属性；`inout`；一侧范围；`didSet`；`String` 常用 API 扩充；`Array` sort(by:)/firstIndex/removeAll/contains(where:)/allSatisfy；`Dictionary` 遍历、default 下标；`Double` 格式化（`String(format:)` 子集）；`Date` 只读基础；差分夹具同步增加。
注意：不做 class/协议/泛型（v1 外）；对每个新增能力更新 catalog 与 `docs/SWIFT_SUPPORT.md`。

### W4 网页运行时 + 模板库 + 数据雏形（W1 合并后启动）
`WebRuntime`（WKWebView 隔离、随包资源、CSP、消息桥校验、内容进程终止恢复）、网页模板、`TemplateLibrary` 八类模板的可运行首版（能力不足的模板在解释器能力内实现最小版本并标注）、`Data/` 记录 API 与 JSON/CSV 导出、ZIP/Swift/项目包导出与系统分享。

### W5 集成与打磨
把 W1–W4 接起来、统一视觉、无障碍、iPad 多窗口共用 ProjectStore、验收矩阵更新。

## 之后：按 M1–M5 细化
W 阶段完成后，重新对照任务书 §5–§16 与 §20，把每个领域细化成 M1（项目/编辑器深度：TextKit 2 编辑器功能、iCloud、文件协调）、M2（语言子集完整、异步、CapabilityKit、数据迁移）、M3（AI 评测集、秘密检测、网络审计、候选隔离运行）、M4（模板端到端案例、调试器）、M5（网页策略完整、音频/传感器、其余模板）的任务清单与门禁，逐项写入 `verification/ACCEPTANCE.md`。
