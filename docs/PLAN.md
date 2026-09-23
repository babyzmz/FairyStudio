# Fairy Studio 实施计划（由主代理制定，实现由 Opus 子代理执行）

任务书：见用户提供的《Fairy Studio — iOS 27 / iPadOS 27 完整实现 Prompt》。本文件把它拆成可派发、可验收的工作包。环境事实见 docs/ENVIRONMENT.md，进度见 PROGRESS.md。

## 0. 不可协商的工程纪律（每个子代理都必须遵守）
1. 不编造：API、测试结果、截图、"已完成"状态一律以实际命令输出为准。未跑的测试写"待测"，不写"通过"。
2. 三档口径报告：已实现并验证 / 已实现待实机（或待 iOS 27 环境）/ 未实现或受外部条件阻塞。
3. 只用公开 API。不引入第三方生成式模型、越狱、私有 entitlement、动态库下载、机器码执行。
4. 用户源码是执行逻辑唯一权威；不得按模板名显示写死页面；不得用正则"翻译" Swift；不得用 WebView 假冒原生执行。
5. mock / 夹具只能进入测试目标或带持久可见"夹具"标记的验证构建，不得进入正式成功路径。
6. 修改公共契约（Packages/FairyCore/Sources/RuntimeContracts）必须同步测试与文档，并写入 docs/CONTRACT_CHANGES.md。M0 期间契约冻结：需要改动时先写 docs/CONTRACT_REQUESTS.md，由主代理裁决。
7. 每个工作包维护 docs/progress/<包名>.md：当前阶段、已验证内容（附命令与关键输出）、未完成项、下一步。中断后能续。
8. 不做 git 提交/推送（由主代理提交）；不清理工作树；不删除用户数据。
9. 先跑直接受影响的测试，阶段结束再跑对应回归。

## 1. 仓库结构与模块边界
```
FairyStudio/
  project.yml                # XcodeGen 定义，生成 FairyStudio.xcodeproj（生成物也提交）
  Config/                    # Brand / Base(iOS 27.0) / Verify-iOS26 / Signing.local
  App/                       # StudioApp：SwiftUI 页面、窗口、导航、编辑器（依赖各包，不含运行时逻辑）
  Packages/FairyCore/        # 单一 SwiftPM 包，多 target；可在 macOS 跑纯 Swift 单测
    Sources/RuntimeContracts # 运行事件、RenderTree、能力请求、值传输协议、引擎协议（共享真相）
    Sources/SwiftRuntime     # 解析、索引、语义子集、IR、VM、诊断、capability catalog
    Sources/NativeBridge     # RenderTree → 预编译 SwiftUI 组件；输入回传
    Sources/FoundationAI     # Apple 模型 ModelBroker、能力检测、上下文预算、任务、工具、评估
    Sources/ProjectCore      # (M1) manifest、文件、快照、数据版本、事务 actor
    Sources/CapabilityKit    # (M2) 能力注册、策略、授权、执行
    Sources/WebRuntime       # (M5) WKWebView 隔离运行
    Sources/ArtifactKit      # (M5/M6) 内容模型、文档提取、演示、导出(PDF/HTML/PPTX)
    Sources/TemplateLibrary  # (M4+) 模板元数据、源码、夹具
    Sources/fairy-run        # macOS CLI：无头运行 + 差分测试 + 导出 catalog
  Templates/                 # 模板项目包（.mojoproject）
  Tests/                     # App 单测 / UI 测试
  scripts/                   # verify-env.sh, build-verify.sh, differential.sh
  docs/                      # 架构、支持范围、格式、模型接入、权限、导出、验收矩阵、审核说明
  verification/              # 验收矩阵与实测日志（按环境口径分开）
```
依赖方向：App → NativeBridge/FoundationAI/ProjectCore/CapabilityKit/… → RuntimeContracts。SwiftRuntime 只依赖 RuntimeContracts + swift-syntax，绝不依赖 SwiftUI。模型层不持有项目写句柄或系统权限对象。

## 2. 关键技术决策
- **执行引擎**：SwiftParser 语法树 → 每文件 source map → 模块声明索引 → 受支持子集的名称/语义检查 → **已解析的槽位化 IR**（执行期不再引用 SwiftSyntax 节点）→ 带步数/栈深/分配/时间预算、可取消的解释器 → RenderTree。不维护第二套 AST evaluator 语义。
- **状态**：StateStore 以 (runID, 视图身份路径, 字段) 为键；ForEach/List 行用稳定业务 id；Binding 反向写入；视图重建不重复初始化 @State。
- **线程**：运行实例是 actor，在非 MainActor 执行；MainActor 只应用已验证的 RenderTree 快照并派发输入事件。事件带 runID + sequence。
- **重新运行**：保存候选快照 → 校验 → 停止旧实例（等待 stop 返回）→ 清理 → 启动新实例。首版重置临时 UI 状态、保留业务数据。
- **模型**：只有 OnDevice(SystemLanguageModel) 与 PrivateCloudCompute 两个后端，经 ModelBroker 统一；PCC 代码以 `FAIRY_PCC_SDK` 编译条件隔离，当前 SDK 缺失时后端固定"不可用：SDK 缺失"。每次任务开始检查能力。上下文与 token 从 API 实际结果读取；SDK 无公开容量查询时通过 exceededContextWindowSize 错误处理并记录。
- **部署目标**：Config/Base.xcconfig 固定 27.0；Verify-iOS26.xcconfig 仅供当前环境验证构建。
- **依赖**：swift-syntax exact 603.0.2（已 resolve 实测可编译于 Swift 6.2.4）；XcodeGen 生成工程。

## 3. 里程碑与工作包

### M0 环境与技术验证（当前）
| 包 | 所有权（可写路径） | 交付 |
|---|---|---|
| M0-A SwiftRuntime | Packages/FairyCore/Sources/SwiftRuntime, Sources/fairy-run, Tests/SwiftRuntimeTests, Package.swift, docs/RUNTIME_DESIGN.md, docs/SWIFT_SUPPORT.md, docs/progress/M0-A.md | 两个互相引用的 Swift 文件经解释器输出原生计数器 RenderTree；闭包、@State 更新、无限循环停止（目标 ≤250ms）、重新运行清理；差分测试 CLI；capability catalog |
| M0-B App + Bridge + AI | project.yml, App/, Tests/, scripts/, Packages/FairyCore/Sources/NativeBridge, Sources/FoundationAI, Sources/DevFixtures, Tests/NativeBridgeTests, Tests/FoundationAITests, docs/APPLE_MODELS.md, docs/DEPENDENCIES.md, docs/progress/M0-B.md | XcodeGen 工程，iPhone/iPad 模拟器验证构建通过；RenderTree 渲染器；RunCoordinator 状态机；ModelBroker 能力检测全部状态；AI 状态页；模拟器上验证"不可用路径" |
| M0-C 集成 | 上述全部 | SwiftRuntime 接入 App，模拟器端到端跑通计数器；30 次运行—停止无泄漏；夹具引擎从 App 路径移除；写 verification/M0.md |

M0 门禁：M0-A 单测全绿（macOS）；M0-B 模拟器构建 + 测试通过；M0-C 端到端在 iOS 26.3 模拟器验证；本地模型真实调用记录为"受阻：需 macOS 26.6+ / Xcode 27 / 实机"；PCC 记录为"受阻：SDK 缺失 + 资格未核对"。模型缺失不阻塞解释器。

### M1 项目与编辑器
ProjectCore：.mojoproject 文档包（project.json manifest 字段齐全、稳定 fileID、Sources/Resources/Documents/Data/Tests）、单文件托管工作区、ZIP 导入校验（路径穿越、符号链接、大小写冲突、体积/数量上限）、security-scoped 访问与文件协调、iCloud 未下载处理、快照与修订号、事务 actor、原子写。
编辑器：TextKit 2 原生编辑器，行号、高亮、缩进、括号匹配、查找替换、标签、未保存标记、撤销重做、诊断定位、marked text（中文输入法）、UTF-8→UTF-16 映射。
工作区：iPhone 作品/代码/助手三段式 + 抽屉；iPad 自适应多栏。
门禁：文件顺序无关索引、改名不丢历史、ZIP 攻击夹具全部拒绝、中文输入不被高亮打断。

### M2 运行时与数据
完成 v1 语言子集（含 enum、extension、guard、switch、值语义、溢出/除零/越界诊断）；SwiftUI 子集（Image/Slider/Picker/ScrollView/Form/NavigationStack 受限/sheet/alert/动画）；受控异步 .task/onAppear；CapabilityKit 注册与授权链路；业务数据记录 API（CRUD、筛选、排序、聚合、JSON/CSV 导出）与 schema 迁移（计划/备份/验证/回滚）。
门禁：跨文件/身份/取消/恢复测试；20 文件 3000 行项目缓存后 ≤2s 进入运行（实测记录）；停止 ≤250ms；30 次运行—停止无泄漏。

### M3 Apple AI 闭环
ModelBroker 任务、上下文预算、工具集（listFiles/readFileRange/searchSymbols/readCapability/proposeChanges/validateCandidate/previewCandidate/readDiagnostics）、ProjectPlan/FileChangeSet/DiagnosticFixPlan 结构化输出、expectedBaseHash 冲突拒绝、候选隔离运行、diff 与事务提交、最多两轮修复、取消后迟到结果不落盘、秘密信息检测、Apple-only 网络审计、固定评测集。

### M4 交互演示、个人工具、教学模板
TemplateDefinition；三个真实可运行模板项目（参数演示、器材借还、函数图像/代码课程）；调试器 console/调用栈/当前位置/变量只读/受限单步；端到端案例。

### M5 WebRuntime、数据研究、现场工具、音频/设备与其余模板
WKWebView 隔离、CSP、导航策略、消息桥校验、内容进程终止恢复；CSV 分析台；检查表；音频调度与传感器；分支故事/二维互动；节拍器；网页模板。

### M6 导出、讲稿、恢复、多窗口、外屏、辅助功能
PDF/HTML/PPTX（本地 OOXML，结构校验）、Markdown 讲稿、版本恢复、多窗口 ProjectStore 冲突、外接显示器演示、VoiceOver/Dynamic Type/Reduce Motion。

### M7 设备矩阵、安全回归、性能、AI 评估、许可、审核材料、发布构建
验收矩阵全部条目有实测口径；未实机验证项明确标注。

## 4. 验收矩阵
verification/ACCEPTANCE.md 按任务书第 20 节逐条列出，每条记录：环境口径（macOS 单测 / 模拟器验证构建 / iPhone 实机 / iPad 实机）、命令、结果、日期。"待测"不算通过。
