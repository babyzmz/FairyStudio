import Foundation
import Observation
import Synchronization
import FoundationAI
import ProjectContracts
import RuntimeContracts
import SwiftRuntime

// 助手会话：对话消息 + 单在途请求 + 后端选择 + 改码闭环编排。
// 不持有文件句柄：读只经 project.snapshot()，写只经 project.apply(_:)。

/// W1 侧 ProjectLibrary 的最小视图：W1 以 extension 适配本协议，避免循环依赖。
/// 库是集合对象，没有单一 projectID；会话需要的项目身份经 `project.snapshot()` 取得。
public protocol AssistantProjectLibrary: Sendable {
    var displayName: String { get }
}

/// 与 W1 的接口契约名：`AssistantPanelHost(library:)` 的参数类型。
public typealias ProjectLibraryStub = any AssistantProjectLibrary

public enum AssistantCardStatus: Sendable, Hashable {
    case pending
    case applying
    case applied
    case discarded
    case expired
    case applyFailed(String)
}

public enum AssistantMessageKind: Hashable {
    case user(String)
    case assistant(String, streaming: Bool)
    case change(PendingChange, AssistantCardStatus)
    case diagnostics([Diagnostic], String)
    case system(String)
}

public struct AssistantMessage: Identifiable, Hashable {
    public var id: UUID
    public var kind: AssistantMessageKind
    public init(id: UUID = UUID(), kind: AssistantMessageKind) {
        self.id = id; self.kind = kind
    }
}

/// coordinator 持有的引擎快照版校验器（FoundationAI 不依赖 SwiftRuntime，
/// 实际注入的就是 SwiftRuntimeEngine，见 EngineCatalog）。
struct RunCoordinatorValidator: AssistantValidating {
    let engine: any RuntimeEngine
    func validate(_ program: ProgramSource) async -> ValidationResult {
        await engine.validate(program)
    }
}

/// 当前代次盒（引用语义）：Sendable 闭包共享读取；写入只发生在 MainActor。
final class CurrentGeneration: Sendable {
    private let box = Mutex(UUID())
    func get() -> UUID { box.withLock { $0 } }
    func set(_ id: UUID) { box.withLock { $0 = id } }
}

@MainActor
@Observable
final class AssistantSession {
    /// 针对 FairyStudio（Apple 平台 / Swift SwiftUI 子集解释器）的编程提示词。
    /// 文本路径（Apple 云端 / OpenRouter）以此作为 system 指令；逐轮提示由 AssistantPromptBuilder 组装。
    static let instructions = """
        你是 FairyStudio 的资深 Apple 平台 Swift 编程助手。FairyStudio 是 iPad/iPhone 上的本地应用：\
        用户用 SwiftUI 子集编写界面，由内置解释器沙盒执行（不是完整 Swift 工具链）。

        【运行环境硬约束】以下语法会直接校验失败，禁止生成：
        - class / 继承 / 协议 / 泛型 / struct 方法外的下标重载 / async-await / throws-try / 宏 / lazy / AnyView；
        - 随机 API（*.random）、Timer、DispatchQueue、Task、网络、文件系统、Bundle；
        - 未列出的 SwiftUI 视图与修饰符（以"能力目录摘要"为准，只使用其中 supported / partial 项）。

        【支持的视图】Text、Button、TextField、SecureField、Toggle、Slider、Stepper、Picker（.tag 行）、\
        ForEach、List、Form、Section、ScrollView、NavigationStack、NavigationLink + navigationDestination、\
        sheet(isPresented:)、alert(_:isPresented:)、Image(systemName:)、ProgressView(value:total:)、\
        Group、Spacer、Divider、VStack/HStack/ZStack。
        【支持的修饰符】padding、font（.title/.headline/.callout/.caption 等文本样式）、bold、\
        foregroundColor、background(颜色)、frame、cornerRadius、opacity、disabled、navigationTitle、\
        buttonStyle(.bordered/.borderedProminent/.plain)、pickerStyle(.segmented/.menu)、tag。
        【状态与数据】@State + struct 模型（memberwise init）、enum 关联值与 switch、元组、\
        Dictionary/Array/Set 风格的常用方法、String(format:) 的 %.Nf、Date() 只读、math（sqrt/pow/sin/cos…）。\
        列表更新用下标写回（items[i].x = …）或模型 mutating 方法。

        【输出协议】先一句话说明做了什么，然后输出一个 ```json 代码块，内容为 {"operations":[...]}；\
        每项含 action（create|replace|rename|delete）、fileID 或 path、contents（create/replace 必填，完整文件内容）、\
        newPath（rename 必填）、note（一句话）。expectedBaseHash 可省略（工具侧自动填读取时哈希）。\
        无需改码时直接纯文本回答，不要输出 JSON。

        【工作方式】
        - 只改必要文件；既有文件用 fileID 标识，新建文件给相对路径（如 Sources/Models/X.swift、Sources/Views/Y.swift）；
        - 输出尽量短：不加注释与空行、不复述未修改的代码；新建项目最小可运行，每个文件 ≤ 50 行；
        - 多文件任务分批：本轮提交一部分，结尾单独输出 [[MORE]]（会自动继续），全部完成则不输出；\
          收到"继续"时接着做下一批，不要重复已完成的内容；
        - 生成后代码会经解释器校验并真实运行，校验失败会把诊断回喂给你修复（最多 2 轮）。
        """

    var messages: [AssistantMessage] = []
    var inputDraft = ""
    var isResponding = false
    /// 兼容出口：等价于 updateStrategy == .autoCompatible。
    var autoRunOnValidated: Bool {
        get { updateStrategy == .autoCompatible }
        set { updateStrategy = newValue ? .autoCompatible : .manual }
    }
    /// 会话历史（左面板）：当前对话的消息同步存放在 conversations 里。
    private(set) var conversations: [AssistantConversation] = []
    private(set) var currentConversationID = UUID()
    /// 后端/更新策略/OpenRouter 配置存于应用级设置（首页设置入口与会话共享）。
    @ObservationIgnored private let settings: AssistantSettingsModel
    var backend: ModelBackend {
        get { settings.backend }
        set { settings.backend = newValue }
    }
    var updateStrategy: UpdateStrategy {
        get { settings.updateStrategy }
        set { settings.updateStrategy = newValue }
    }
    var onDeviceAvailability: ModelAvailability?
    /// OpenRouter（用户自配云端）可用性：Key 已配置 = 可尝试；授权在 send 时强校验。
    var openRouterAvailability: ModelAvailability?
    var cloudAvailability: ModelAvailability?
    var hasCloudConsent: Bool
    /// 置 true 时界面弹出云端确认框。
    var needsCloudConsent = false
    /// 模型修改后直接运行（默认开）：校验通过即 apply + coordinator.run。
    /// 当前打开文件（W1 编辑器设置），进入上下文全文。
    var selectedPath: String?
    /// 本轮裁剪过上下文时置 true，界面显示"已裁剪上下文"。
    var contextTrimmedNotice = false

    /// 云端不可用时的禁用原因（PCC SDK 缺失等），nil 表示可选。
    var cloudDisabledReason: String? {
        guard let cloudAvailability else { return "检测中" }
        return cloudAvailability.isAvailable ? nil : cloudAvailability.reasonDescription
    }

    @ObservationIgnored private let project: any ProjectAccess
    @ObservationIgnored let coordinator: RunCoordinator
    @ObservationIgnored private let library: ProjectLibraryStub?
    @ObservationIgnored private let broker: ModelBroker
    @ObservationIgnored private let consent: CloudConsentStore
    @ObservationIgnored private let validator: any AssistantValidating
    @ObservationIgnored private let runner: (ProgramSource) async -> [Diagnostic]
    /// agent 执行器（FoundationModels 工具循环）：设备端后端时启用；nil = 纯文本路径（云端 / 单测）。
    @ObservationIgnored private let agent: AgentPerforming?
    /// 当前代次：Sendable 盒，供 @Sendable perform/onPartial 闭包读取；新发送先取消旧的，
    /// 以此校验，迟到结果不落盘、不建卡。
    @ObservationIgnored private let generationBox = CurrentGeneration()
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var currentStreamID: UUID?
    @ObservationIgnored private var lastUserPrompt = ""
    /// [[MORE]] 自动续作：已自动发送的"继续"轮数（手动发送重置）。
    @ObservationIgnored private var autoContinueCount = 0
    @ObservationIgnored private let maxAutoContinue = 3
    /// "仅讨论"模式：本轮不提交文件变更（输入器菜单切换）。
    var discussionOnly = false
    /// 已应用变更记录（历史时间线 + 恢复上一版的数据来源；只含源码，不含业务数据）。
    private(set) var appliedRecords: [AppliedChangeRecord] = []
    /// 最近一次应用前的源码快照（恢复上一版直接取用；随记录保留首版）。
    private(set) var lastPreApplySnapshot: ProjectSnapshot?
    // P0 状态契约（docs/REFACTOR_P0.md）：三状态轴 + 运行版本记录。
    private(set) var generationState: GenerationState = .idle
    private(set) var updateState: UpdateState = .none
    /// 实际运行实例对应的源码修订（AI 应用后运行时记录；手动运行记录属 P1）。
    private(set) var runningVersion: ProjectRevision?

    init(project: any ProjectAccess, coordinator: RunCoordinator, library: ProjectLibraryStub?,
         initialPrompt: String = "",
         broker: ModelBroker = .live(), consent: CloudConsentStore = .standard,
         settings: AssistantSettingsModel,
         validator: (any AssistantValidating)? = nil,
         runner: ((ProgramSource) async -> [Diagnostic])? = nil,
         agent: AgentPerforming? = nil) {
        self.settings = settings
        self.project = project
        self.coordinator = coordinator
        self.library = library
        self.broker = broker
        self.consent = consent
        self.hasCloudConsent = consent.hasConsented
        self.validator = validator ?? RunCoordinatorValidator(engine: coordinator.engine)
        self.runner = runner ?? { [weak coordinator] program in
            guard let coordinator else { return [] }
            return await AssistantSession.runDefault(program, coordinator: coordinator)
        }
        self.agent = agent
        let firstConversation = AssistantConversation()
        conversations = [firstConversation]
        currentConversationID = firstConversation.id
        if !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputDraft = initialPrompt
            messages.append(AssistantMessage(kind: .system("已填入创建时的需求描述，检查后直接发送。")))
        }
    }

    // MARK: - 后端

    func availability(of backend: ModelBackend) -> ModelAvailability? {
        switch backend {
        case .onDevice: onDeviceAvailability
        case .privateCloudCompute: cloudAvailability
        case .openRouter: openRouterAvailability
        }
    }

    func refreshAvailability() async {
        onDeviceAvailability = await broker.checkAvailability(backend: .onDevice)
        cloudAvailability = await broker.checkAvailability(backend: .privateCloudCompute)
        openRouterAvailability = await broker.checkAvailability(backend: .openRouter)
        hasCloudConsent = consent.hasConsented
    }

    // MARK: - OpenRouter（用户自配云端）

    /// 授权开关：授权前 Broker 与会话都拒绝发起任何 OpenRouter 请求。
    var isOpenRouterEnabled: Bool { settings.isOpenRouterEnabled }

    func setOpenRouterEnabled(_ on: Bool) {
        settings.setOpenRouterEnabled(on)
        if !on && backend == .openRouter { backend = .onDevice }
        Task { await refreshAvailability() }
    }

    var openRouterModelID: String { settings.openRouterModelID }

    func setOpenRouterModel(_ id: String) {
        settings.openRouterModelID = id
        let broker = self.broker
        Task { await broker.selectOpenRouterModel(id) }
    }

    func grantCloudConsent() {
        consent.grantConsent()
        hasCloudConsent = true
        needsCloudConsent = false
    }

    func revokeCloudConsent() {
        consent.revokeConsent()
        hasCloudConsent = false
        if backend == .privateCloudCompute { backend = .onDevice }
    }

    // MARK: - 发送 / 取消

    func send() {
        sendInternal(auto: false)
    }

    private func sendInternal(auto: Bool) {
        if !auto { autoContinueCount = 0 }
        let text = inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 任务串行化：同一项目写入任务不并发竞争；提示用户选择，不静默丢弃。
        if isResponding {
            messages.append(AssistantMessage(kind: .system(
                "已有任务进行中。可以取消当前任务后重新发送，或等它完成。")))
            return
        }
        if backend == .privateCloudCompute, !consent.hasConsented {
            needsCloudConsent = true
            return
        }
        if backend == .openRouter, !settings.isOpenRouterEnabled {
            messages.append(AssistantMessage(kind: .system("请先在助手设置中启用 OpenRouter 并配置 API Key。")))
            return
        }
        if let avail = availability(of: backend), !avail.isAvailable {
            messages.append(AssistantMessage(kind: .system("AI 不可用：\(avail.reasonDescription)")))
            return
        }
        // 同一会话单在途：新发送先取消旧的。
        cancelInflight()
        let gen = UUID()
        generationBox.set(gen)
        lastUserPrompt = text
        if let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) {
            // 首条消息作为会话标题。
            if conversations[idx].title == "新对话" {
                conversations[idx].title = String(text.prefix(16))
            }
            conversations[idx].updatedAt = Date()
        }
        inputDraft = ""
        isResponding = true
        generationState = .receiving
        contextTrimmedNotice = false
        messages.append(AssistantMessage(kind: .user(text)))
        let streamID = UUID()
        currentStreamID = streamID
        messages.append(AssistantMessage(id: streamID, kind: .assistant("", streaming: true)))
        inflight = Task { [weak self] in
            await self?.runTurnFlow(prompt: text, streamID: streamID, generation: gen,
                                    tracker: RepairTracker(), repairContext: nil)
        }
    }

    func cancel() {
        cancelInflight()
        generationBox.set(UUID())
        generationState = .cancelled
        if let id = currentStreamID {
            updateMessage(id, kind: .assistant("已取消", streaming: false))
            currentStreamID = nil
        } else if isResponding {
            messages.append(AssistantMessage(kind: .system("已取消")))
        }
        isResponding = false
    }

    private func cancelInflight() {
        let broker = self.broker
        Task { await broker.cancelCurrentTask() }
        inflight?.cancel()
        inflight = nil
    }

    // MARK: - 会话历史

    /// 当前消息写回会话记录（切换 / 新建 / 删除 / 发送时；流式消息落为静态）。
    private func syncCurrentConversation() {
        guard let idx = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        conversations[idx].messages = messages.map { message in
            if case let .assistant(text, streaming) = message.kind, streaming {
                return AssistantMessage(id: message.id, kind: .assistant(text.isEmpty ? "已取消" : text, streaming: false))
            }
            return message
        }
        conversations[idx].updatedAt = Date()
    }

    func newConversation() {
        cancelInflight()
        generationBox.set(UUID())
        generationState = .idle
        syncCurrentConversation()
        let fresh = AssistantConversation()
        conversations.append(fresh)
        currentConversationID = fresh.id
        messages = []
        inputDraft = ""
        isResponding = false
        currentStreamID = nil
    }

    func selectConversation(_ id: UUID) {
        guard id != currentConversationID,
              conversations.contains(where: { $0.id == id }) else { return }
        cancelInflight()
        generationBox.set(UUID())
        syncCurrentConversation()
        currentConversationID = id
        messages = conversations.first(where: { $0.id == id })?.messages ?? []
        isResponding = false
        currentStreamID = nil
    }

    func deleteConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations.remove(at: idx)
        guard id == currentConversationID else { return }
        cancelInflight()
        generationBox.set(UUID())
        if let next = conversations.last {
            currentConversationID = next.id
            messages = next.messages
        } else {
            let fresh = AssistantConversation()
            conversations.append(fresh)
            currentConversationID = fresh.id
            messages = []
        }
        isResponding = false
        currentStreamID = nil
    }

    // MARK: - 闭环

    private func runTurnFlow(prompt: String, streamID: UUID, generation: UUID,
                             tracker: RepairTracker, repairContext: String?) async {
        let snapshot = await project.snapshot()
        let agentActive = backend == .onDevice && agent != nil
        // agent 路径的提示词只带精简能力摘要（模型可用 readCapability 工具按需查全量），
        // 给 4K 上下文里的文件内容与输出留空间。
        let caps = agentActive
            ? ReadCapabilityTool.summary(entries: SwiftRuntimeEngine.catalog.entries, lineLimit: 12)
            : ReadCapabilityTool.summary(entries: SwiftRuntimeEngine.catalog.entries)
        let diagText = ReadDiagnosticsTool.summary(diagnostics: coordinator.diagnostics,
                                                   consoleTail: consoleTailStrings())
        let effectivePrompt = discussionOnly ? "【仅讨论】不要修改任何文件，只作解释或建议。\n\(prompt)" : prompt
        let input = AssistantTurnInput(
            userPrompt: effectivePrompt, snapshot: snapshot, backendName: backend.shortName,
            selectedPath: selectedPath, capabilitySummary: caps, diagnosticsSummary: diagText,
            history: recentHistory(), alreadyUsedRounds: tracker.usedRounds,
            lastErrorSignature: tracker.lastSignature, repairContext: repairContext)
        let broker = self.broker
        let backend = self.backend
        let agent = self.agent
        let generationBox = self.generationBox
        // agent 回合上下文：与纯文本 prompt 同一来源，一次组装两边共用。
        let catalogEntries = SwiftRuntimeEngine.catalog.entries
        let agentContext = AgentTurnContext(snapshot: snapshot, catalogEntries: catalogEntries,
                                            diagnosticsSummary: diagText)
        // 流式更新闭包：@Sendable，只捕获盒与弱 session；代次过期直接丢弃。
        let onPartial: @Sendable (String) async -> Void = { [weak self, generationBox] partial in
            guard generationBox.get() == generation else { return }
            await MainActor.run { self?.updateStream(streamID: streamID, generation: generation, text: partial) }
        }
        let outcome: AssistantTurnOutcome
        do {
            outcome = try await AssistantPipeline().runTurn(input, perform: { [broker, backend, generationBox, onPartial, agent, agentContext] promptText in
                // 设备端走 agent 工具循环：模型经工具读文件、经 proposeChanges 提交结构化操作
                // （可多次调用，每个文件一次），工具事件回显到气泡。云端与单测走纯文本路径。
                if backend == .onDevice, let agent {
                    let output = try await agent.run(prompt: promptText, context: agentContext, onEvent: { note in
                        guard generationBox.get() == generation else { return }
                        await onPartial(note)
                    })
                    guard generationBox.get() == generation else { throw CancellationError() }
                    return output.pipelineText
                }
                let result = await broker.perform(
                    ModelRequest(prompt: promptText, backend: backend, instructions: Self.instructions),
                    onPartial: { partial in await onPartial(partial) }
                )
                guard generationBox.get() == generation else { throw CancellationError() }
                switch result {
                case let .completed(response): return response.text
                case .cancelled: throw CancellationError()
                case let .failed(failure): throw failure
                }
            }, validator: validator, onPhase: { [weak self, generationBox] phase in
                guard generationBox.get() == generation, phase == .modelComplete else { return }
                Task { @MainActor in
                    guard let self, self.generationState == .receiving else { return }
                    self.generationState = .validating
                }
            })
        } catch is CancellationError {
            // 迟到结果不落盘： generation 已被新发送取代则静默丢弃。
            guard generationBox.get() == generation else { return }
            updateMessage(streamID, kind: .assistant("已取消", streaming: false))
            isResponding = false
            currentStreamID = nil
            return
        } catch {
            guard currentGeneration() == generation else { return }
            updateMessage(streamID, kind: .assistant("", streaming: false))
            messages.append(AssistantMessage(kind: .system("请求失败：\(error)")))
            isResponding = false
            currentStreamID = nil
            return
        }
        // 非取消路径同样校验 generation：迟到结果不落盘、不建卡。
        guard currentGeneration() == generation else { return }
        if outcome.contextTrimmed { contextTrimmedNotice = true }
        switch outcome.result {
        case let .proposed(pending):
            if discussionOnly {
                updateMessage(streamID, kind: .assistant(
                    cardIntro(pending) + "\n（仅讨论模式：建议的修改未应用。）", streaming: false))
                isResponding = false
                currentStreamID = nil
                generationState = .idle
                return
            }
            updateMessage(streamID, kind: .assistant(cardIntro(pending), streaming: false))
            messages.append(AssistantMessage(kind: .change(pending, .pending)))
            updateState = .ready
            if autoRunOnValidated {
                await applyAndRun(pending: pending, generation: generation,
                                  tracker: RepairTracker(usedRounds: pending.repairRoundsUsed,
                                                         lastSignature: pending.lastErrorSignature))
                // 应用+运行成功后：生成轴回到 idle（更新轴由 updateState 表达）。
                generationState = .idle
                // 应用+运行成功后才续作：下一批基于新修订，避免过期哈希。
                maybeAutoContinue(after: outcome.modelTail, generation: generation)
            } else {
                isResponding = false
                currentStreamID = nil
                generationState = .waiting
            }
        case let .noChange(text):
            updateMessage(streamID, kind: .assistant(
                text.replacingOccurrences(of: AssistantPipeline.moreMarker, with: ""), streaming: false))
            isResponding = false
            currentStreamID = nil
            generationState = .idle
            maybeAutoContinue(after: outcome.modelTail, generation: generation)
        case let .failed(error):
            updateMessage(streamID, kind: .assistant("", streaming: false))
            messages.append(AssistantMessage(kind: .system(error.userMessage)))
            isResponding = false
            currentStreamID = nil
            generationState = .failed
        }
    }

    /// [[MORE]] 自动续作：模型表明本轮未完成时自动发"继续"接着下一批
    /// （上限 3 轮，防失控；手动发送会重置计数）。
    private func maybeAutoContinue(after modelTail: String, generation: UUID) {
        guard currentGeneration() == generation else { return }
        guard modelTail.contains(AssistantPipeline.moreMarker) else { return }
        guard autoContinueCount < maxAutoContinue else {
            messages.append(AssistantMessage(kind: .system(
                "已自动续作 \(maxAutoContinue) 轮；剩余部分请回复“继续”手动完成。")))
            return
        }
        autoContinueCount += 1
        inputDraft = "继续"
        sendInternal(auto: true)
    }

    /// 恢复某条应用记录的上一版源码（只回滚代码；业务数据/记录不受影响）。
    /// 走同一 ProjectStore.apply 事务：以当前哈希为基线，替换回上一版内容。
    func restorePreviousVersion(recordID: UUID) {
        guard !isResponding else { return }
        guard let record = appliedRecords.first(where: { $0.id == recordID }) else { return }
        guard !record.previousFiles.isEmpty else {
            messages.append(AssistantMessage(kind: .system("该记录没有可恢复的上一版文件（全部为新建）。")))
            return
        }
        isResponding = true
        inflight = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isResponding = false
                self.currentStreamID = nil
            }
            let snapshot = await self.project.snapshot()
            var ops: [FileOperation] = []
            for (fileID, path, previousContents) in record.previousFiles {
                // 优先按 fileID 解析当前文件；找不到（被删除）则按 path 重建。
                let current = snapshot.file(id: fileID) ?? snapshot.file(path: path)
                if let current {
                    ops.append(.replace(fileID: current.id, expectedBaseHash: current.hash, contents: previousContents))
                } else {
                    ops.append(.create(path: path, contents: previousContents))
                }
            }
            let changeSet = FileChangeSet(
                id: UUID(), baseRevision: snapshot.revision,
                operations: ops,
                summary: "恢复上一版（记录 r\(record.revision.rawValue)）",
                origin: .user)
            do {
                _ = try await self.project.apply(changeSet)
                self.updateState = .applied
                self.messages.append(AssistantMessage(kind: .system("已恢复上一版源码（r\(snapshot.revision.rawValue) → 新修订），业务记录未变动。")))
                // 恢复后的程序重新运行
                let restored = await self.project.snapshot()
                let program = ProgramSource(moduleName: restored.moduleName, files: restored.files.map {
                    SourceFile(id: $0.id, path: $0.path, contents: $0.contents)
                })
                _ = await self.runner(program)
                self.runningVersion = restored.revision
            } catch {
                self.updateState = .failed
                self.messages.append(AssistantMessage(kind: .system("恢复失败：\(error)")))
            }
        }
    }

    /// 变更卡片按钮：应用并运行。
    func applyCard(changeSetID: UUID) {
        guard !isResponding else { return }
        guard let msg = messages.first(where: {
            if case let .change(p, .pending) = $0.kind, p.changeSet.id == changeSetID { return true }
            return false
        }), case let .change(pending, _) = msg.kind else { return }
        isResponding = true
        updateState = .applying
        let gen = currentGeneration()
        inflight = Task { [weak self] in
            await self?.applyAndRun(pending: pending, generation: gen,
                                    tracker: RepairTracker(usedRounds: pending.repairRoundsUsed,
                                                           lastSignature: pending.lastErrorSignature))
        }
    }

    func discardCard(changeSetID: UUID) {
        setCardStatus(changeSetID, status: .discarded)
    }

    private func applyAndRun(pending: PendingChange, generation: UUID, tracker: RepairTracker) async {
        setCardStatus(pending.changeSet.id, status: .applying)
        let fresh = await project.snapshot()
        guard fresh.revision == pending.changeSet.baseRevision else {
            setCardStatus(pending.changeSet.id, status: .expired)
            messages.append(AssistantMessage(kind: .system("项目已有新版本，补丁过期，请重新发送。")))
            isResponding = false
            currentStreamID = nil
            return
        }
        do {
            // 结果（新修订等）不经此更新：快照刷新走 store 的 snapshots 订阅。
            _ = try await project.apply(pending.changeSet)
            // 该候选程序即将成为运行实例：记录其源码修订（P0 状态契约）。
            runningVersion = pending.candidate.revision
            // 应用记录（恢复上一版的数据来源：受影响文件的上一版内容；业务数据不在源码快照内，不受影响）。
            let previousFiles: [(FileID, String, String)] = pending.changeSet.operations.compactMap { op in
                switch op {
                case let .replace(fileID, _, _):
                    if let file = fresh.file(id: fileID) { return (fileID, file.path, file.contents) }
                    return nil
                case let .delete(fileID, _):
                    if let file = fresh.file(id: fileID) { return (fileID, file.path, file.contents) }
                    return nil
                case .create: return nil
                case .rename: return nil
                }
            }
            appliedRecords.append(AppliedChangeRecord(
                id: pending.changeSet.id, revision: pending.candidate.revision,
                backend: pending.backendName, timestamp: Date(),
                files: pending.files.map { ($0.fileID?.rawValue ?? $0.path, $0.path, $0.addedLines, $0.removedLines) },
                previousFiles: previousFiles))
        } catch let error as ChangeSetError {
            switch error {
            case .hashMismatch, .revisionMismatch:
                setCardStatus(pending.changeSet.id, status: .expired)
                messages.append(AssistantMessage(kind: .system("补丁基于旧版本，已被拒绝；请重新读取后重试。")))
            default:
                setCardStatus(pending.changeSet.id, status: .applyFailed(String(describing: error)))
                messages.append(AssistantMessage(kind: .system("应用失败：\(error)")))
            }
            isResponding = false
            currentStreamID = nil
            return
        } catch {
            setCardStatus(pending.changeSet.id, status: .applyFailed(String(describing: error)))
            isResponding = false
            currentStreamID = nil
            return
        }
        guard currentGeneration() == generation else {
            // 取消恰好落在应用之后：已落盘，如实标记，不再运行。
            setCardStatus(pending.changeSet.id, status: .applied)
            messages.append(AssistantMessage(kind: .system("已应用（取消前提交），未运行。")))
            isResponding = false
            currentStreamID = nil
            return
        }
        let diags = await runner(pending.candidate.program)
        guard currentGeneration() == generation else { return }
        let errors = diags.filter { $0.severity == .error }
        if errors.isEmpty {
            setCardStatus(pending.changeSet.id, status: .applied)
            if !diags.isEmpty {
                messages.append(AssistantMessage(kind: .diagnostics(diags, "运行完成（有警告）")))
            } else {
                messages.append(AssistantMessage(kind: .system("已应用并运行。")))
            }
            isResponding = false
            currentStreamID = nil
            return
        }
        messages.append(AssistantMessage(kind: .diagnostics(diags, "运行失败")))
        var next = tracker
        let signature = AssistantRepair.signature(of: diags)
        guard next.shouldRepair(signature: signature) else {
            setCardStatus(pending.changeSet.id, status: .applied)
            messages.append(AssistantMessage(kind: .system("自动修复已用完 2 轮，剩余问题见诊断卡。")))
            isResponding = false
            currentStreamID = nil
            return
        }
        messages.append(AssistantMessage(kind: .system("运行未通过，自动修复第 \(next.usedRounds) 轮…")))
        let streamID = UUID()
        currentStreamID = streamID
        messages.append(AssistantMessage(id: streamID, kind: .assistant("", streaming: true)))
        let diagText = ReadDiagnosticsTool.summary(diagnostics: diags, consoleTail: consoleTailStrings())
        await runTurnFlow(prompt: lastUserPrompt, streamID: streamID, generation: generation,
                          tracker: next,
                          repairContext: "上一轮修改已应用并运行，但运行失败，诊断如下，请针对性修正：\n\(diagText)")
    }

    // MARK: - 默认运行（apply 后运行并等终态，只读 coordinator 数据）

    private static func runDefault(_ program: ProgramSource, coordinator: RunCoordinator) async -> [Diagnostic] {
        let task = coordinator.run(program)
        await task.value
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while !coordinator.state.isTerminal, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return coordinator.diagnostics
    }

    // MARK: - 消息辅助

    private func currentGeneration() -> UUID {
        generationBox.get()
    }

    private func updateStream(streamID: UUID, generation: UUID, text: String) {
        guard currentGeneration() == generation else { return }
        updateMessage(streamID, kind: .assistant(text, streaming: true))
    }

    private func updateMessage(_ id: UUID, kind: AssistantMessageKind) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].kind = kind
    }

    private func setCardStatus(_ changeSetID: UUID, status: AssistantCardStatus) {
        guard let i = messages.firstIndex(where: {
            if case let .change(p, _) = $0.kind { return p.changeSet.id == changeSetID }
            return false
        }) else { return }
        if case let .change(pending, _) = messages[i].kind {
            messages[i].kind = .change(pending, status)
        }
        updateState = UpdateState(from: status)
    }

    private func recentHistory(limit: Int = 6) -> [TurnMessage] {
        var turns: [TurnMessage] = []
        for msg in messages {
            switch msg.kind {
            case let .user(t): turns.append(TurnMessage(role: .user, text: t))
            case let .assistant(t, streaming: s) where !s && !t.isEmpty:
                turns.append(TurnMessage(role: .assistant, text: String(t.prefix(500))))
            default: break
            }
        }
        return Array(turns.suffix(limit))
    }

    private func consoleTailStrings(limit: Int = 20) -> [String] {
        coordinator.console.suffix(limit).map { "[\($0.stream)] \($0.text)" }
    }

    private func cardIntro(_ pending: PendingChange) -> String {
        let files = pending.files.map { "・\($0.path)（+\($0.addedLines)/−\($0.removedLines)）" }
            .joined(separator: "\n")
        return "准备修改 \(pending.files.count) 个文件：\n\(files)"
    }
}
