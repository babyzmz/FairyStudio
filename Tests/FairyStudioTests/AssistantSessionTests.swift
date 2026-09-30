import Foundation
import Synchronization
import Testing
import FoundationModels
import FoundationAI
import ProjectContracts
import RuntimeContracts
import SwiftRuntime
@testable import Fairy_Studio

// 助手会话测试（Xcode）：用假 project / 假 driver / 假 validator / 假 runner 注入 session，
// 验证发送→变更卡片出现、autoRun 应用并运行、取消不落卡、initialPrompt 预填。

// MARK: - 假件

actor FakeAssistantProject: ProjectAccess {
    let projectID = ProjectID()
    var snapshotValue: ProjectSnapshot
    var appliedCount = 0

    init() {
        snapshotValue = ProjectSnapshot(
            projectID: ProjectID(), revision: ProjectRevision(3),
            displayName: "Demo", moduleName: "Demo",
            entry: .rootView(symbol: "ContentView"),
            files: [ProjectFileSnapshot(
                id: FileID("f1"), path: "Sources/ContentView.swift",
                contents: "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}")])
    }

    func snapshot() async -> ProjectSnapshot { snapshotValue }

    func apply(_ changeSet: FileChangeSet) async throws -> ChangeSetResult {
        let next = try ChangeSetPreview.apply(changeSet, to: snapshotValue)
        snapshotValue = next
        appliedCount += 1
        return ChangeSetResult(changeSetID: changeSet.id, revision: next.revision,
                               createdFileIDs: [], affectedFileIDs: next.files.map(\.id))
    }

    func snapshots() async -> AsyncStream<ProjectSnapshot> {
        AsyncStream { $0.finish() }
    }

    /// 模拟卡片待确认期间，项目被其他窗口/手动编辑推进了一个修订。
    func bumpRevision() async {
        snapshotValue = ProjectSnapshot(
            projectID: snapshotValue.projectID, revision: ProjectRevision(snapshotValue.revision.rawValue + 1),
            displayName: snapshotValue.displayName, moduleName: snapshotValue.moduleName,
            entry: snapshotValue.entry, files: snapshotValue.files)
    }
}

enum AssistantScriptStep: Sendable {
    case text(String)
    case hang
}

final class ScriptedAssistantDriver: ModelBackendDriver, Sendable {
    let backend: ModelBackend
    private let steps: Mutex<[AssistantScriptStep]>

    init(_ steps: [AssistantScriptStep], backend: ModelBackend = .onDevice) {
        self.steps = Mutex(steps)
        self.backend = backend
    }

    func checkAvailability() async -> ModelAvailability { .available }

    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error> {
        let step = steps.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch step {
                case .text(let t):
                    continuation.yield(t)
                    continuation.finish()
                case .hang:
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish(throwing: CancellationError())
                case nil:
                    continuation.finish(throwing: ModelTaskFailure.systemError("剧本用尽"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct AssistantTestValidator: AssistantValidating {
    func validate(_ program: ProgramSource) async -> ValidationResult {
        ValidationResult(diagnostics: [], entryPoints: [.rootView(symbol: "ContentView")],
                         referencedCapabilities: [])
    }
}

/// 每次会话独立的设置实例：不读被污染的 UserDefaults.standard，backend 恒为设备端。
func isolatedSettings() -> AssistantSettingsModel {
    AssistantSettingsModel(
        defaults: UserDefaults(suiteName: "fairy.tests.settings.\(UUID().uuidString)")!,
        openRouterConsent: OpenRouterConsentStore(suiteName: "fairy.tests.orconsent.\(UUID().uuidString)"))
}

func assistantConsent() -> CloudConsentStore {
    let store = CloudConsentStore(suiteName: "fairy.tests.assistant.\(UUID().uuidString)")
    store.revokeConsent()
    return store
}

func replaceJSON(contents: String) -> String {
    """
    改好了：
    ```json
    {"operations":[{"action":"replace","fileID":"f1","contents":\(jsonString(contents)),"note":"改文字"}]}
    ```
    """
}

func jsonString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
}

/// runner 调用记录（引用语义，避免 noncopyable 作函数参数）。
final class AssistantRunLog: Sendable {
    private let box = Mutex<[[Diagnostic]]>([])
    func append(_ diags: [Diagnostic]) { box.withLock { $0.append(diags) } }
    var count: Int { box.withLock { $0.count } }
}

@MainActor
func makeAssistantSession(driverSteps: [AssistantScriptStep],
                          runs: AssistantRunLog? = nil,
                          autoRun: Bool = false,
                          initialPrompt: String = "") async -> (AssistantSession, FakeAssistantProject) {
    let project = FakeAssistantProject()
    let coordinator = RunCoordinator(engine: RecordingEngine())
    let broker = ModelBroker(drivers: [ScriptedAssistantDriver(driverSteps)], consent: assistantConsent())
    let session = AssistantSession(project: project, coordinator: coordinator, library: nil,
                                   initialPrompt: initialPrompt, broker: broker,
                                   settings: isolatedSettings(),
                                   validator: AssistantTestValidator(),
                                   runner: { _ in
                                       runs?.append([])
                                       return []
                                   })
    session.autoRunOnValidated = autoRun
    return (session, project)
}

/// agent 路径假件：回放固定输出（模拟 proposeChanges 累计后的结果）。
final class FakeAgentRunner: AgentPerforming, @unchecked Sendable {
    let output: AgentTurnOutput

    init(finalText: String, operations: [ProposedOperation]) {
        output = AgentTurnOutput(finalText: finalText, proposedOperations: operations)
    }

    func run(prompt: String, context: AgentTurnContext,
             onEvent: @escaping @Sendable (String) async -> Void) async throws -> AgentTurnOutput {
        await onEvent("已提交 \(output.proposedOperations.count) 个操作（测试）")
        return output
    }
}

func hasPendingCard(_ messages: [AssistantMessage]) -> Bool {
    messages.contains {
        if case .change(_, .pending) = $0.kind { return true }
        return false
    }
}

// MARK: - 测试

@Suite("助手会话")
struct AssistantSessionTests {
    @Test("发送→变更卡片出现")
    @MainActor func sendShowsChangeCard() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"你好\")\n    }\n}"
        let (session, _) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))])
        session.inputDraft = "把文字改成你好"
        session.send()
        let appeared = await waitUntil { hasPendingCard(session.messages) }
        #expect(appeared)
        #expect(session.isResponding == false)
    }

    @Test("autoRun 开时校验通过即应用（runner 收到新程序）")
    @MainActor func autoRunApplies() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Go\")\n    }\n}"
        let runs = AssistantRunLog()
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))],
                                                            runs: runs, autoRun: true)
        session.inputDraft = "改"
        session.send()
        let done = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case .change(_, .applied) = $0.kind { return true }
                return false
            }
        }
        #expect(done)
        #expect(await project.appliedCount == 1)
        #expect(runs.count == 1)
        let contents = await project.snapshotValue.files.first?.contents
        #expect(contents == fixed)
    }

    @Test("取消后迟到结果不建卡、不落盘")
    @MainActor func cancelDropsLateResult() async {
        let (session, project) = await makeAssistantSession(driverSteps: [.hang])
        session.inputDraft = "改"
        session.send()
        _ = await waitUntil { session.isResponding }
        session.cancel()
        #expect(session.isResponding == false)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!hasPendingCard(session.messages))
        #expect(await project.appliedCount == 0)
    }

    @Test("initialPrompt 自动填入输入框并提示发送")
    @MainActor func initialPromptPrefills() async {
        let (session, _) = await makeAssistantSession(driverSteps: [], initialPrompt: "做个计数器")
        #expect(session.inputDraft == "做个计数器")
        #expect(session.messages.contains {
            if case .system = $0.kind { return true }
            return false
        })
    }

    @Test("agent 工具路径：proposeChanges 累计的操作走同一闭环并 autoRun")
    @MainActor func agentPathAppliesChanges() async {
        let runs = AssistantRunLog()
        let project = FakeAssistantProject()
        let coordinator = RunCoordinator(engine: RecordingEngine())
        let broker = ModelBroker(drivers: [ScriptedAssistantDriver([])], consent: assistantConsent())
        let newFile = "import SwiftUI\nstruct Greeting: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"
        let agent = FakeAgentRunner(finalText: "已创建 Greeting 视图。", operations: [
            ProposedOperation(action: "create", path: "Sources/Greeting.swift",
                              contents: newFile, note: "新建"),
        ])
        let session = AssistantSession(project: project, coordinator: coordinator, library: nil,
                                       broker: broker, settings: isolatedSettings(),
                                       validator: AssistantTestValidator(),
                                       runner: { _ in runs.append([]); return [] },
                                       agent: agent)
        session.autoRunOnValidated = true
        session.inputDraft = "新建一个 Greeting 视图"
        session.send()
        let done = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case .change(_, .applied) = $0.kind { return true }
                return false
            }
        }
        #expect(done)
        #expect(await project.appliedCount == 1)
        #expect(runs.count == 1)
        let paths = await project.snapshotValue.files.map(\.path)
        #expect(paths.contains("Sources/Greeting.swift"))
    }

    @Test("自动续作：[[MORE]] 后自动发送继续并完成变更")
    @MainActor func autoContinueCompletes() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"你好\")\n    }\n}"
        let (session, project) = await makeAssistantSession(driverSteps: [
            .text("计划：分两步，本轮先总结 [[MORE]]"),
            .text(replaceJSON(contents: fixed)),
        ], autoRun: true)
        session.inputDraft = "分步改"
        session.send()
        let done = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case .change(_, .applied) = $0.kind { return true }
                return false
            }
        }
        #expect(done)
        #expect(await project.appliedCount == 1)
    }

    @Test("自动续作上限：3 轮后停止并提示手动继续")
    @MainActor func autoContinueCapped() async {
        let (session, _) = await makeAssistantSession(driverSteps: [
            .text("[[MORE]] 第1步"), .text("[[MORE]] 第2步"), .text("[[MORE]] 第3步"), .text("[[MORE]] 第4步"),
        ], autoRun: true)
        session.inputDraft = "做多文件项目"
        session.send()
        let capped = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case let .system(text) = $0.kind, text.contains("手动") { return true }
                return false
            }
        }
        #expect(capped)
        #expect(session.isResponding == false)
    }

    @Test("openRouter 后端：授权后走同一管线完成变更")
    @MainActor func openRouterPathAppliesChanges() async {
        let runs = AssistantRunLog()
        let project = FakeAssistantProject()
        let coordinator = RunCoordinator(engine: RecordingEngine())
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Go\")\n    }\n}"
        let consent = OpenRouterConsentStore(suiteName: "fairy.tests.or.session.\(UUID().uuidString)")
        consent.grantConsent()
        let settings = AssistantSettingsModel(defaults: UserDefaults(suiteName: "fairy.tests.or.settings.\(UUID().uuidString)")!,
                                              openRouterConsent: consent)
        settings.setOpenRouterEnabled(true)
        let broker = ModelBroker(
            drivers: [ScriptedAssistantDriver([.text(replaceJSON(contents: fixed))], backend: .openRouter)],
            consent: assistantConsent(), openRouterConsent: consent)
        let session = AssistantSession(project: project, coordinator: coordinator, library: nil,
                                       broker: broker, consent: assistantConsent(),
                                       settings: settings,
                                       validator: AssistantTestValidator(),
                                       runner: { _ in runs.append([]); return [] })
        session.autoRunOnValidated = true
        session.backend = .openRouter
        session.inputDraft = "改文字"
        session.send()
        let done = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case .change(_, .applied) = $0.kind { return true }
                return false
            }
        }
        #expect(done)
        #expect(await project.appliedCount == 1)
        let contents = await project.snapshotValue.files.first?.contents
        #expect(contents == fixed)
    }

    @Test("openRouter 未授权：发送被阻止且无变更")
    @MainActor func openRouterBlockedWithoutConsent() async {
        let project = FakeAssistantProject()
        let coordinator = RunCoordinator(engine: RecordingEngine())
        let broker = ModelBroker(
            drivers: [ScriptedAssistantDriver([.text("不应到达")], backend: .openRouter)],
            consent: assistantConsent(),
            openRouterConsent: OpenRouterConsentStore(suiteName: "fairy.tests.or.blocked.\(UUID().uuidString)"))
        let session = AssistantSession(project: project, coordinator: coordinator, library: nil,
                                       broker: broker, consent: assistantConsent(),
                                       settings: isolatedSettings(),
                                       validator: AssistantTestValidator(),
                                       runner: { _ in [] })
        session.backend = .openRouter
        session.inputDraft = "改文字"
        session.send()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await project.appliedCount == 0)
        #expect(session.messages.contains {
            if case let .system(text) = $0.kind { return text.contains("OpenRouter") }
            return false
        })
    }

    // MARK: - P2/P3：更新策略 / 仅讨论 / 恢复上一版 / 任务串行化

    @Test("更新策略 paused：候选就绪但不应用")
    @MainActor func pausedStrategyKeepsRunningVersion() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))], autoRun: false)
        session.updateStrategy = .paused
        session.inputDraft = "改"
        session.send()
        let ready = await waitUntil { session.updateState == .ready }
        #expect(ready)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await project.appliedCount == 0, "暂停更新不应用候选")
        #expect(session.runningVersion == nil, "运行版本保持未记录（原实例未变）")
    }

    @Test("仅讨论：模型建议的修改不建卡不应用")
    @MainActor func discussionModeIgnoresChanges() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"X\")\n    }\n}"
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))], autoRun: true)
        session.discussionOnly = true
        session.inputDraft = "为什么会这样？"
        session.send()
        let done = await waitUntil { session.generationState == .idle }
        #expect(done)
        #expect(await project.appliedCount == 0, "仅讨论不落盘")
        #expect(!session.messages.contains { if case .change = $0.kind { return true }; return false })
        #expect(session.messages.contains {
            if case let .assistant(text, _) = $0.kind { return text.contains("仅讨论") }
            return false
        })
    }

    @Test("恢复上一版：源码回滚、修订推进、业务不受影响")
    @MainActor func restorePreviousVersionRollsBackCode() async {
        let original = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"
        let changed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Go\")\n    }\n}"
        let runs = AssistantRunLog()
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: changed))], runs: runs, autoRun: true)
        session.inputDraft = "改"
        session.send()
        let applied = await waitUntil(timeout: .seconds(5)) { session.updateState == .applied }
        #expect(applied)
        #expect(await project.snapshotValue.files.first?.contents == changed)

        let recordID = session.appliedRecords.last?.id
        #expect(recordID != nil)
        session.restorePreviousVersion(recordID: recordID!)
        let restored = await waitUntil(timeout: .seconds(5)) {
            session.messages.contains {
                if case let .system(text) = $0.kind { return text.contains("已恢复上一版源码") }
                return false
            }
        }
        #expect(restored)
        #expect(await project.snapshotValue.files.first?.contents == original, "源码回到上一版")
        #expect(await project.snapshotValue.revision.rawValue > 3, "恢复经事务产生新修订，不是悄悄改历史")
        #expect(runs.count == 2, "恢复后的程序重新运行（原 1 次 + 恢复 1 次）")
    }

    @Test("任务串行化：进行中再发送得到提示且不竞争")
    @MainActor func busySendGetsHint() async {
        let (session, project) = await makeAssistantSession(driverSteps: [.hang])
        session.inputDraft = "第一个任务"
        session.send()
        _ = await waitUntil { session.isResponding }
        session.inputDraft = "第二个任务"
        session.send()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(session.messages.contains {
            if case let .system(text) = $0.kind { return text.contains("已有任务进行中") }
            return false
        })
        #expect(await project.appliedCount == 0)
    }

    /// 设备端工具循环的前置：工具 schema 在会话构造时生成，非法 schema 会在这一步暴露
    /// （而不是留到实机发消息时崩）。不需要模型可用性，模拟器即可跑。
    @Test("agent 会话与工具 schema 可构造")
    @MainActor func agentSessionSchemaConstructs() async {
        let project = FakeAssistantProject()
        let snapshot = await project.snapshot()
        let context = AgentTurnContext(snapshot: snapshot, catalogEntries: SwiftRuntimeEngine.catalog.entries,
                                       diagnosticsSummary: "")
        let (session, accumulator) = FoundationModelsAgentRunner.makeSession(context: context, onEvent: { _ in })
        #expect(!session.isResponding)
        #expect(accumulator.all.isEmpty)
    }
}


@MainActor
@Suite("Audit: precommit candidate isolation", .serialized)
struct AuditCandidateIsolationTests {
    @Test func candidateStartupFailureNeverCommits() async throws {
        let project = FakeAssistantProject()
        let before = await project.snapshot()
        let driver = ScriptedAssistantDriver([.text(replaceJSON(contents: "bad candidate"))])
        let session = AssistantSession(project: project, coordinator: RunCoordinator(engine: RecordingEngine()),
            library: nil, broker: ModelBroker(drivers: [driver], consent: assistantConsent()),
            settings: isolatedSettings(), validator: AssistantTestValidator(), runner: { _ in [] },
            preflight: { _ in [Diagnostic(kind: .runtimeTrap, message: "candidate trap")] })
        session.autoRunOnValidated = true
        session.inputDraft = "change"
        session.send()
        #expect(await waitUntil { !session.isResponding })
        #expect(await project.appliedCount == 0)
        #expect(await project.snapshot() == before)
        #expect(session.runningVersion == nil)
    }

    @Test func cancellationDuringPreflightNeverCommits() async throws {
        let project = FakeAssistantProject()
        let entered = CurrentGeneration()
        let sentinel = UUID()
        let driver = ScriptedAssistantDriver([.text(replaceJSON(contents: "candidate"))])
        let session = AssistantSession(project: project, coordinator: RunCoordinator(engine: RecordingEngine()),
            library: nil, broker: ModelBroker(drivers: [driver], consent: assistantConsent()),
            settings: isolatedSettings(), validator: AssistantTestValidator(), runner: { _ in [] },
            preflight: { _ in
                entered.set(sentinel)
                try await Task.sleep(for: .seconds(10))
                return []
            })
        session.autoRunOnValidated = true
        session.inputDraft = "change"
        session.send()
        #expect(await waitUntil { entered.get() == sentinel })
        session.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await project.appliedCount == 0)
        #expect(session.runningVersion == nil)
    }
}
