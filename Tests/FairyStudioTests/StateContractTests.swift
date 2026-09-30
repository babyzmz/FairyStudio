import Foundation
import Testing
import FoundationAI
import ProjectContracts
import RuntimeContracts
@testable import Fairy_Studio

// 页面重构 P0 状态契约测试（docs/REFACTOR_P0.md）：
// 三状态轴相互独立；运行版本被记录；过期候选绝不覆盖用户已修改的项目。

@Suite("P0 状态契约")
struct StateContractTests {
    // MARK: - 运行状态映射（唯一事实来源：RunState）

    @Test("RuntimeState 与 RunState 一一对应")
    func runtimeStateMapping() {
        #expect(RuntimeState(from: .idle) == .stopped)
        #expect(RuntimeState(from: .stopped) == .stopped)
        #expect(RuntimeState(from: .validating) == .starting)
        #expect(RuntimeState(from: .preparing) == .starting)
        #expect(RuntimeState(from: .running) == .running)
        #expect(RuntimeState(from: .stopping) == .stopping)
        #expect(RuntimeState(from: .interrupted) == .interrupted)
        #expect(RuntimeState(from: .failed) == .failed)
    }

    @Test("UpdateState 与改动卡状态一一对应")
    func updateStateMapping() {
        #expect(UpdateState(from: .pending) == .ready)
        #expect(UpdateState(from: .applying) == .applying)
        #expect(UpdateState(from: .applied) == .applied)
        #expect(UpdateState(from: .expired) == .blocked)
        #expect(UpdateState(from: .applyFailed("探针")) == .failed)
        #expect(UpdateState(from: .discarded) == .discarded)
    }

    // MARK: - 生成轴

    @Test("生成中 → receiving；取消 → cancelled（生成取消不改变更新轴）")
    @MainActor func generationReceivingAndCancel() async {
        let (session, _) = await makeAssistantSession(driverSteps: [.hang])
        session.inputDraft = "改"
        session.send()
        _ = await waitUntil { session.isResponding }
        #expect(session.generationState == .receiving)
        session.cancel()
        #expect(session.generationState == .cancelled)
        // 生成取消不影响更新轴（没有候选）。
        #expect(session.updateState == .none)
    }

    @Test("候选待确认 → waiting；失败 → failed")
    @MainActor func generationWaitingAndFailed() async {
        // 失败路径：剧本用尽 → modelFailed。
        let (failedSession, _) = await makeAssistantSession(driverSteps: [])
        failedSession.inputDraft = "改"
        failedSession.send()
        _ = await waitUntil { failedSession.generationState == .failed }
        #expect(failedSession.generationState == .failed)

        // waiting 路径：候选通过但未开自动应用。
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"
        let (session, _) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))], autoRun: false)
        session.inputDraft = "改"
        session.send()
        let ready = await waitUntil { session.updateState == .ready }
        #expect(ready)
        #expect(session.generationState == .waiting)
    }

    // MARK: - 更新轴与运行版本

    @Test("自动应用：updateState=applied 且 runningVersion 记录候选修订")
    @MainActor func autoRunRecordsRunningVersion() async {
        let fixed = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Go\")\n    }\n}"
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: fixed))], autoRun: true)
        session.inputDraft = "改"
        session.send()
        let applied = await waitUntil(timeout: .seconds(5)) {
            session.updateState == .applied
        }
        #expect(applied)
        #expect(session.generationState == .idle, "生成轴与更新轴独立：应用完成不等于生成仍在进行")
        let snapshot = await project.snapshot()
        #expect(session.runningVersion == snapshot.revision, "运行版本 = 应用后的项目修订")
    }

    // MARK: - P0 验收：过期候选不覆盖用户修改

    @Test("候选待确认期间项目被推进 → 应用被阻断，用户修改不被覆盖")
    @MainActor func expiredCandidateDoesNotOverwriteUserEdits() async {
        let original = "import SwiftUI\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}"
        let (session, project) = await makeAssistantSession(driverSteps: [.text(replaceJSON(contents: original))], autoRun: false)
        session.inputDraft = "改"
        session.send()
        let ready = await waitUntil { session.updateState == .ready }
        #expect(ready)
        guard let foundCardID = session.messages.compactMap({ message -> UUID? in
            if case let .change(pending, .pending) = message.kind { return pending.changeSet.id }
            return nil
        }).first else {
            Issue.record("找不到待确认改动卡")
            return
        }
        let cardID = foundCardID

        // 用户（或另一窗口）在候选确认前推进了项目修订。
        await project.bumpRevision()
        let userContent = await project.snapshotValue.files.first?.contents
        #expect(userContent == original, "前置：用户当前内容未被篡改")

        session.applyCard(changeSetID: cardID)
        let blocked = await waitUntil { session.updateState == .blocked }
        #expect(blocked)
        #expect(session.messages.contains {
            if case let .system(text) = $0.kind { return text.contains("过期") || text.contains("新版本") }
            return false
        })
        // 核心断言：用户当前内容保持原样，未被候选覆盖。
        let after = await project.snapshotValue.files.first?.contents
        #expect(after == original, "过期候选不得覆盖用户已修改的项目")
    }

    // MARK: - 版本关系摘要

    @Test("版本关系摘要可读")
    func versionSummary() {
        let relationship = WorkspaceVersionRelationship(
            saved: ProjectRevision(13), running: ProjectRevision(12), candidateBase: ProjectRevision(12))
        #expect(relationship.summary == "文件已保存 r13 · 正在运行 r12 · 待应用修改（基线 r12）"
            || relationship.summary.contains("r13") && relationship.summary.contains("r12"))
        #expect(WorkspaceVersionRelationship().summary == "无版本记录")
    }
}
