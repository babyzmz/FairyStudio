import Testing
import Foundation
import RuntimeContracts
@testable import Fairy_Studio

import DevFixtures

/// RunCoordinator 行为（使用夹具引擎；M0-C 起夹具只链接进本测试目标，App 任何配置都不含）。
/// 串行执行：泄漏检测依赖全局存活实例计数。
@MainActor
@Suite("RunCoordinator", .serialized)
struct RunCoordinatorTests {
    @Test("计数器：运行 → Count: 0 → action → Count: 1（revision+1）→ 停止")
    func counterFlow() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .counter))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.state == .running && coordinator.tree != nil })
        #expect(text(of: "counter.label", in: coordinator.tree) == "Count: 0")
        let firstRevision = coordinator.tree?.revision ?? 0

        coordinator.send(.action(ActionID("counter.increment")))
        #expect(await waitUntil { text(of: "counter.label", in: coordinator.tree) == "Count: 1" })
        #expect(coordinator.tree?.revision == firstRevision + 1)

        await coordinator.stop().value
        #expect(coordinator.state == .stopped)
        #expect(coordinator.exitReason == .stoppedByUser)
        #expect(coordinator.isActive == false)
        // 停止后输入被忽略。
        coordinator.send(.action(ActionID("counter.increment")))
        #expect(text(of: "counter.label", in: coordinator.tree) == "Count: 1")
    }

    @Test("丢弃不属于当前 RunID 的事件（含上一次运行的迟到事件）")
    func dropsForeignRunEvents() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .counter))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.tree != nil })
        let oldRunID = try! #require(coordinator.displayedRunID)

        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.tree?.runID != nil && coordinator.tree?.runID != oldRunID })
        let newRunID = try! #require(coordinator.displayedRunID)
        #expect(newRunID != oldRunID)

        let dropped = coordinator.droppedEventCount
        let staleTree = RenderTree(runID: oldRunID, revision: 99, root: RenderNode(id: NodeID("stale"), kind: .text("旧实例", style: nil)))
        coordinator.receive(RuntimeEventEnvelope(runID: oldRunID, sequence: 10_000, event: .render(staleTree)))
        coordinator.receive(RuntimeEventEnvelope(runID: RunID(), sequence: 10_001, event: .stateChanged(.failed)))
        #expect(coordinator.droppedEventCount == dropped + 2)
        #expect(coordinator.tree?.runID == newRunID)
        #expect(coordinator.state == .running)
        await coordinator.stop().value
    }

    @Test("丢弃 sequence 倒退的事件与 revision 倒退的 RenderTree")
    func dropsRegressions() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .counter))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.tree != nil })
        let runID = try! #require(coordinator.displayedRunID)
        let dropped = coordinator.droppedEventCount

        coordinator.receive(RuntimeEventEnvelope(runID: runID, sequence: 1, event: .console(.stdout, "倒退的事件")))
        #expect(coordinator.droppedEventCount == dropped + 1)
        #expect(!coordinator.console.contains { $0.text == "倒退的事件" })

        let oldTree = RenderTree(runID: runID, revision: 0, root: RenderNode(id: NodeID("old"), kind: .emptyView))
        coordinator.receive(RuntimeEventEnvelope(runID: runID, sequence: 50_000, event: .render(oldTree)))
        #expect(coordinator.droppedEventCount == dropped + 2)
        #expect(text(of: "counter.label", in: coordinator.tree) == "Count: 0")
        await coordinator.stop().value
    }

    @Test("重新运行：先校验候选，再停止旧实例并启动新实例")
    func rerunStopsBeforeStart() async {
        let engine = RecordingEngine()
        let coordinator = RunCoordinator(engine: engine)
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.state == .running })
        await coordinator.run(sampleProgram).value
        #expect(engine.entries == ["validate", "run:1", "validate", "stop-begin:1", "stop-end:1", "run:2"])
        await coordinator.stop().value
        #expect(engine.entries.suffix(2) == ["stop-begin:2", "stop-end:2"])
    }

    @Test("连续 30 次 run/stop 后夹具实例全部释放")
    func noLeakAfterThirtyCycles() async {
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 0 })
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .counter))
        for _ in 0..<30 {
            await coordinator.run(sampleProgram).value
            coordinator.send(.action(ActionID("counter.increment")))
            await coordinator.stop().value
            #expect(coordinator.state == .stopped)
        }
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 0 }, "存活实例：\(FixtureEngine.liveHandleCount)")
    }

    @Test("连续 30 次直接重新运行（不先点停止）后也只剩当前实例")
    func rerunWithoutStopKeepsOneInstance() async {
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 0 })
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .form))
        for _ in 0..<30 {
            await coordinator.run(sampleProgram).value
        }
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 1 }, "存活实例：\(FixtureEngine.liveHandleCount)")
        await coordinator.stop().value
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 0 })
    }

    @Test("预算超限：诊断 + interrupted（来自引擎事件），实例自动释放")
    func budgetExceeded() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .budgetExceeded))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.state == .interrupted })
        #expect(coordinator.diagnostics.contains { $0.kind == .budgetExceeded })
        #expect(coordinator.exitReason == .budgetExceeded("maxSteps"))
        #expect(await waitUntil { !coordinator.isActive })
        #expect(await waitUntil { FixtureEngine.liveHandleCount == 0 })
    }

    @Test("不支持的节点：树中保留 unsupported 节点并产生 unsupportedAPI 诊断")
    func unsupportedNode() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .unsupported))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.diagnostics.contains { $0.kind == .unsupportedAPI } })
        let node = coordinator.tree.flatMap { findNode("unsupported.canvas", in: $0.root) }
        #expect(node?.kind == .unsupported(symbol: "Canvas", capabilityID: "view.Canvas"))
        await coordinator.stop().value
    }

    @Test("表单：setBinding 回写后 revision 增加、文本同步")
    func formBinding() async {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .form))
        await coordinator.run(sampleProgram).value
        #expect(await waitUntil { coordinator.tree != nil })
        coordinator.send(.setBinding(BindingID("form.name"), .string("你好世界")))
        #expect(await waitUntil { text(of: "form.greeting", in: coordinator.tree) == "你好，你好世界" })
        coordinator.send(.action(ActionID("form.reverse")))
        #expect(await waitUntil {
            coordinator.tree.flatMap { findNode("form.list", in: $0.root) }?.children.first?.id == NodeID("form.list/durian")
        })
        await coordinator.stop().value
    }

    @Test("夹具引擎：丢弃错误 RunID 与乱序的输入")
    func fixtureRejectsBadInputs() async throws {
        let engine = FixtureEngine(scenario: .counter)
        let handle = try await engine.run(sampleProgram, entry: .rootView(symbol: "x"), budget: .default,
                                          options: RunOptions(runtimeVersion: engine.runtimeVersion))
        await handle.send(RuntimeInputEnvelope(runID: RunID(), sequence: 1, input: .action(ActionID("counter.increment"))))
        await handle.send(RuntimeInputEnvelope(runID: handle.runID, sequence: 2, input: .action(ActionID("counter.increment"))))
        await handle.send(RuntimeInputEnvelope(runID: handle.runID, sequence: 1, input: .action(ActionID("counter.increment"))))
        await handle.stop()
        var lastCount: String?
        var consoleLines: [String] = []
        for await envelope in handle.events {
            switch envelope.event {
            case let .render(tree): lastCount = text(of: "counter.label", in: tree)
            case let .console(_, line): consoleLines.append(line)
            default: break
            }
        }
        #expect(lastCount == "Count: 1")
        #expect(consoleLines.contains { $0.contains("不属于本实例") })
        #expect(consoleLines.contains { $0.contains("乱序") })
    }
}


@MainActor
@Suite("Audit: startup readiness", .serialized)
struct AuditStartupReadinessTests {
    @Test func interactiveWorkDoesNotWaitForTermination() async throws {
        let coordinator = RunCoordinator(engine: FixtureEngine(scenario: .counter))
        let clock = ContinuousClock(), start = ContinuousClock.now
        await coordinator.run(sampleProgram).value
        let diagnostics = try await coordinator.waitUntilReady(timeout: .seconds(2))
        #expect(!diagnostics.contains { $0.severity == .error })
        #expect(coordinator.state == .running)
        #expect(clock.now - start < .seconds(2))
        await coordinator.stop().value
    }

    @Test func cancelledReadinessWaitExitsImmediately() async throws {
        let coordinator = RunCoordinator(engine: RecordingEngine())
        await coordinator.run(sampleProgram).value // No render event in this test engine.
        let task = Task { try await coordinator.waitUntilReady(timeout: .seconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await coordinator.stop().value
    }
}
