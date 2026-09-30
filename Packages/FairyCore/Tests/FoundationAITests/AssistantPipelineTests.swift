import Foundation
import Synchronization
import Testing
import ProjectContracts
import RuntimeContracts
@testable import FoundationAI

// 助手闭环的假 driver 回放测试：哈希拒绝、取消迟到不落盘、两轮上限、校验失败回喂、上下文退避。

// MARK: - 假件

/// 内存 ProjectAccess：apply 经 ChangeSetPreview.apply 演算后存下（含修订递增与哈希校验）。
actor FakeProject: ProjectAccess {
    let projectID = ProjectID()
    var snapshotValue: ProjectSnapshot
    var appliedCount = 0

    init(files: [(path: String, id: String, contents: String)]) {
        snapshotValue = AssistantTestSupport.makeSnapshot(files: files)
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
}

enum ScriptStep: Sendable {
    case text(String)
    case fail(ModelTaskFailure)
    case hang
}

/// 按队列回放的假模型：记录收到的 prompt 供断言（含修复回喂内容与预算裁剪）。
final class ScriptedModel: Sendable {
    private let steps: Mutex<[ScriptStep]>
    private let _prompts: Mutex<[String]> = Mutex([])

    init(_ steps: [ScriptStep]) { self.steps = Mutex(steps) }

    var prompts: [String] { _prompts.withLock { $0 } }
    var remainingSteps: Int { steps.withLock { $0.count } }

    func perform(_ prompt: String) async throws -> String {
        _prompts.withLock { $0.append(prompt) }
        let step = steps.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch step {
        case .text(let t): return t
        case .fail(let f): throw f
        case .hang:
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        case nil: throw ModelTaskFailure.systemError("剧本用尽")
        }
    }
}

struct FakeValidator: AssistantValidating, Sendable {
    let handler: @Sendable (ProgramSource) async -> ValidationResult
    func validate(_ program: ProgramSource) async -> ValidationResult {
        await handler(program)
    }
}

func okValidation() -> ValidationResult {
    ValidationResult(diagnostics: [], entryPoints: [.rootView(symbol: "ContentView")], referencedCapabilities: [])
}

func errorValidation(_ messages: [String]) -> ValidationResult {
    ValidationResult(diagnostics: messages.map { Diagnostic(kind: .typeCheck, message: $0) },
                     entryPoints: [], referencedCapabilities: [])
}

enum AssistantTestSupport {
    static func makeSnapshot(files: [(path: String, id: String, contents: String)],
                             revision: UInt64 = 7) -> ProjectSnapshot {
        ProjectSnapshot(
            projectID: ProjectID(), revision: ProjectRevision(revision),
            displayName: "Test", moduleName: "Test",
            entry: .rootView(symbol: "ContentView"),
            files: files.map { ProjectFileSnapshot(id: FileID($0.id), path: $0.path, contents: $0.contents) })
    }

    static func json(_ ops: [[String: String]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["operations": ops])
        return "改好了：\n```json\n" + String(data: data, encoding: .utf8)! + "\n```"
    }
}

let demoFiles = [
    (path: "Sources/ContentView.swift", id: "f1", contents: "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"),
]

// MARK: - 测试

@Suite("助手闭环 pipeline")
struct AssistantPipelineTests {
    @Test("模型省略 expectedBaseHash 时自动填入读取时哈希，演算一次通过")
    func hashAutoFilled() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"你好\")\n    }\n}"
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": fixed, "note": "改按钮文字",
        ]])
        let model = ScriptedModel([.text(reply)])
        let input = AssistantTurnInput(userPrompt: "把文字改成你好", snapshot: snapshot, backendName: "onDevice",
                                       selectedPath: "Sources/ContentView.swift")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case let .proposed(pending) = outcome.result else {
            Issue.record("期望 proposed，实际 \(outcome.result)")
            return
        }
        // 哈希已自动填入且与快照一致。
        if case let .replace(_, expected, _) = pending.changeSet.operations.first {
            #expect(expected == snapshot.file(path: "Sources/ContentView.swift")!.hash)
        } else {
            Issue.record("期望 replace 操作")
        }
        #expect(pending.candidate.file(id: FileID("f1"))?.contents == fixed)
        #expect(pending.repairRoundsUsed == 0)
        #expect(outcome.contextTrimmed == false)
        // diff 行数：改了一行。
        #expect(pending.files.first?.addedLines == 1)
        #expect(pending.files.first?.removedLines == 1)
        // pipeline 本身不落盘。
        #expect(await project.appliedCount == 0)
    }

    @Test("基于旧哈希的补丁被拒绝并提示重新读取")
    func hashMismatchRejected() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let stale = String(repeating: "0", count: 64)
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "expectedBaseHash": stale,
            "contents": "new", "note": "旧补丁",
        ]])
        let model = ScriptedModel([.text(reply)])
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case let .failed(.previewFailed(message)) = outcome.result else {
            Issue.record("期望 previewFailed，实际 \(outcome.result)")
            return
        }
        #expect(message.contains("重新读取"))
        #expect(await project.appliedCount == 0)
    }

    @Test("取消后迟到结果不落盘：pipeline 抛 CancellationError，不做校验")
    func cancelledLateResultDropped() async {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let validated = Mutex(false)
        let model = ScriptedModel([.hang])
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let task = Task {
            try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                  validator: FakeValidator { _ in
                                                      validated.withLock { $0 = true }
                                                      return okValidation()
                                                  })
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(validated.withLock { $0 } == false)
        #expect(await project.appliedCount == 0)
    }

    @Test("校验失败回喂修复成功：第二轮带诊断重提并通过")
    func validationFailureRepaired() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let bad = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": "BAD SYNTAX ((((", "note": "第一版",
        ]])
        let goodContents = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"OK\")\n    }\n}"
        let good = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": goodContents, "note": "修复版",
        ]])
        let model = ScriptedModel([.text(bad), .text(good)])
        let validator = FakeValidator { program in
            if program.files.first?.contents.contains("BAD") == true {
                return errorValidation(["第 1 行：unexpected token"])
            }
            return okValidation()
        }
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform, validator: validator)
        guard case let .proposed(pending) = outcome.result else {
            Issue.record("期望 proposed，实际 \(outcome.result)")
            return
        }
        #expect(pending.repairRoundsUsed == 1)
        #expect(pending.candidate.file(id: FileID("f1"))?.contents == goodContents)
        // 修复 prompt 回喂了诊断。
        #expect(model.prompts.count == 2)
        #expect(model.prompts[1].contains("unexpected token"))
    }

    @Test("错误签名相同即停：只用 1 轮修复")
    func sameSignatureStops() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": "STILL BAD", "note": "反复",
        ]])
        let model = ScriptedModel([.text(reply), .text(reply), .text(reply)])
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(
            input, perform: model.perform,
            validator: FakeValidator { _ in errorValidation(["同一错误一直存在"]) })
        guard case let .failed(.repairExhausted(remaining)) = outcome.result else {
            Issue.record("期望 repairExhausted，实际 \(outcome.result)")
            return
        }
        #expect(remaining.contains("同一错误一直存在"))
        #expect(model.prompts.count == 2, "相同签名第二轮后即停，只调用模型 2 次")
        #expect(model.remainingSteps == 1)
    }

    @Test("两轮上限：错误持续变化时初始 + 2 轮后停止")
    func twoRoundLimit() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": "X", "note": "改",
        ]])
        let model = ScriptedModel([.text(reply), .text(reply), .text(reply), .text(reply)])
        let round = Mutex(0)
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(
            input, perform: model.perform,
            validator: FakeValidator { _ in
                let n = round.withLock { i -> Int in i += 1; return i }
                return errorValidation(["第 \(n) 个不同错误"])
            })
        guard case .failed(.repairExhausted) = outcome.result else {
            Issue.record("期望 repairExhausted，实际 \(outcome.result)")
            return
        }
        #expect(model.prompts.count == 3, "初始 1 次 + 修复 2 轮，共 3 次模型调用")
    }

    @Test("上下文超限退避：先缩签名、再去旧轮次，并标记已裁剪")
    func contextOverflowBackoff() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let good = AssistantTestSupport.json([[
            "action": "create", "path": "Sources/NewView.swift",
            "contents": "import SwiftUI\nstruct NewView: View {\n    var body: some View { Text(\"N\") }\n}",
            "note": "新建",
        ]])
        let model = ScriptedModel([
            .fail(.exceededContextWindowSize("too long")),
            .fail(.exceededContextWindowSize("still long")),
            .text(good),
        ])
        let history = (1...6).map { TurnMessage(role: .user, text: "旧问题 \($0)") }
        let input = AssistantTurnInput(
            userPrompt: "新建一个 View", snapshot: snapshot, backendName: "onDevice",
            selectedPath: "Sources/ContentView.swift", capabilitySummary: "cap",
            diagnosticsSummary: "- [error] typeCheck：旧错", history: history)
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case let .proposed(pending) = outcome.result else {
            Issue.record("期望 proposed，实际 \(outcome.result)")
            return
        }
        #expect(outcome.contextTrimmed == true)
        #expect(pending.contextTrimmed == true)
        #expect(model.prompts.count == 3)
        #expect(model.prompts[0].contains("## 最近对话"))
        #expect(!model.prompts[1].contains("行数"), "第二轮文件列表只留签名")
        #expect(!model.prompts[2].contains("## 最近对话"), "第三轮去掉旧轮次")
    }

    @Test("超限且无法再退时报 contextOverflow")
    func contextOverflowExhausted() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let model = ScriptedModel([
            .fail(.exceededContextWindowSize("1")),
            .fail(.exceededContextWindowSize("2")),
            .fail(.exceededContextWindowSize("3")),
        ])
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case .failed(.contextOverflow) = outcome.result else {
            Issue.record("期望 contextOverflow，实际 \(outcome.result)")
            return
        }
        #expect(outcome.contextTrimmed == true)
    }

    @Test("纯文本回答不建卡片")
    func plainTextAnswer() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let model = ScriptedModel([.text("Text 只能显示静态文本，不能响应点击。")])
        let input = AssistantTurnInput(userPrompt: "Text 能点吗", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case let .noChange(text) = outcome.result else {
            Issue.record("期望 noChange，实际 \(outcome.result)")
            return
        }
        #expect(text.contains("Text"))
    }

    // MARK: - 输出截断与续写（端上模型 4K 上下文装不下长输出时）

    @Test("looksTruncated：裸 JSON / 闭合块 / 未闭合块 / 纯文本")
    func truncationDetection() {
        #expect(AssistantPipeline.looksTruncated("{\"operations\":[{\"action\""))
        #expect(!AssistantPipeline.looksTruncated("{\"operations\":[]}"))
        #expect(AssistantPipeline.looksTruncated("改好了：\n```json\n{\"operations\":["))
        #expect(!AssistantPipeline.looksTruncated("改好了：\n```json\n{\"operations\":[]}\n```"))
        // 内容已完整、只缺闭合围栏：不算截断。
        #expect(!AssistantPipeline.looksTruncated("改好了：\n```json\n{\"operations\":[]}"))
        // 纯文本 / swift 代码块不是 JSON 输出，不算截断。
        #expect(!AssistantPipeline.looksTruncated("纯文本回答，没有代码块"))
        #expect(!AssistantPipeline.looksTruncated("示例：\n```swift\nlet a = 1\n```"))
    }

    @Test("输出中途截断：自动续写一次补齐并建卡")
    func continuationCompletes() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let truncated = "改好了：\n```json\n{\"operations\":[{\"action\":\"create\",\"path\":\"Sources/A.swift\",\"contents\":\"struct A {"
        let remainder = "}\"}]}"   // 直接接在 "struct A {" 之后，补完字符串与 JSON 结构
        let model = ScriptedModel([.text(truncated), .text(remainder)])
        let input = AssistantTurnInput(userPrompt: "新建一个 A", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case let .proposed(pending) = outcome.result else {
            Issue.record("期望 proposed，实际 \(outcome.result)")
            return
        }
        #expect(pending.files.first?.path == "Sources/A.swift")
        #expect(pending.candidate.file(path: "Sources/A.swift")?.contents == "struct A {}")
        // 续写提示自带被截断的全文（每次请求都是新会话，模型无记忆）。
        #expect(model.prompts.count == 2)
        #expect(model.prompts[1].contains("续写"))
        #expect(model.prompts[1].contains("struct A {"))
    }

    @Test("续写无进展即停：报 outputTruncated")
    func continuationNoProgress() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let truncated = "改好了：\n```json\n{\"operations\":["
        let model = ScriptedModel([.text(truncated), .text("```")])   // 续写只回围栏，剥掉后无内容
        let input = AssistantTurnInput(userPrompt: "改动", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case .failed(.outputTruncated) = outcome.result else {
            Issue.record("期望 outputTruncated，实际 \(outcome.result)")
            return
        }
        #expect(model.prompts.count == 2)
    }

    @Test("连续续写到上限仍不完整：报 outputTruncated")
    func continuationExhausted() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let truncated = "改好了：\n```json\n{\"operations\":["
        let model = ScriptedModel([.text(truncated), .text("{\"action"), .text(":\"create\"")])
        let input = AssistantTurnInput(userPrompt: "大改动", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case .failed(.outputTruncated) = outcome.result else {
            Issue.record("期望 outputTruncated，实际 \(outcome.result)")
            return
        }
        #expect(model.prompts.count == 3)   // 初始 + 2 轮续写
    }

    @Test("modelTail 透传：[[MORE]] 续作标记随结果返回")
    func modelTailCarried() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}", "note": "第一步",
        ]]) + "\n[[MORE]]"
        let model = ScriptedModel([.text(reply)])
        let input = AssistantTurnInput(userPrompt: "分步改", snapshot: snapshot, backendName: "onDevice")
        let outcome = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                            validator: FakeValidator { _ in okValidation() })
        guard case .proposed = outcome.result else {
            Issue.record("期望 proposed，实际 \(outcome.result)")
            return
        }
        #expect(outcome.modelTail.contains("[[MORE]]"))
    }

    @Test("阶段回调：awaitingModel → modelComplete → candidateReady")
    func phaseCallbacksFired() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let reply = AssistantTestSupport.json([[
            "action": "replace", "fileID": "f1", "contents": "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}", "note": "改",
        ]])
        let model = ScriptedModel([.text(reply)])
        var phases: [AssistantPipeline.Phase] = []
        let lock = Mutex<[AssistantPipeline.Phase]>([])
        let input = AssistantTurnInput(userPrompt: "改", snapshot: snapshot, backendName: "onDevice")
        _ = try await AssistantPipeline().runTurn(input, perform: model.perform,
                                                  validator: FakeValidator { _ in okValidation() },
                                                  onPhase: { phase in lock.withLock { $0.append(phase) } })
        phases = lock.withLock { $0 }
        #expect(phases == [.awaitingModel, .modelComplete, .candidateReady])
    }

    @Test("工具：符号扫描 / 文件读取 / 诊断摘要")
    func tools() async throws {
        let project = FakeProject(files: demoFiles)
        let snapshot = await project.snapshot()
        let list = ListFilesTool.output(for: snapshot)
        #expect(list.contains("Sources/ContentView.swift"))
        #expect(list.contains("id=f1"))
        let sigs = ListFilesTool.output(for: snapshot, signaturesOnly: true)
        #expect(!sigs.contains("行数") && !sigs.contains("行"))
        let hits = SearchSymbolsTool.search(snapshot, query: "content")
        #expect(hits.contains { $0.symbol == "ContentView" && $0.kind == "struct" })
        let read = ReadFileTool.read(snapshot, path: "Sources/ContentView.swift", range: 1...2)
        #expect(read?.excerpt.contains("import SwiftUI") == true)
        #expect(read?.file.hash == snapshot.file(path: "Sources/ContentView.swift")!.hash)
        let diag = ReadDiagnosticsTool.summary(
            diagnostics: [Diagnostic(kind: .typeCheck, message: "错")], consoleTail: ["print 1"])
        #expect(diag.contains("错") && diag.contains("print 1"))
        let caps = ReadCapabilityTool.summary(entries: [
            CapabilityEntry(id: "view.Text", category: .view, displayName: "Text",
                            signature: nil, level: .supported, minRuntimeVersion: RuntimeVersion(0, 1, 0),
                            testIDs: [], notes: nil),
        ])
        #expect(caps.contains("view.Text"))
    }
}
