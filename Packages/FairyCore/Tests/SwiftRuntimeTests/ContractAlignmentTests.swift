import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// M0-C：按 docs/CONTRACT_CHANGES.md 的裁决对齐运行时行为。
/// - CR-1 / B-7：每个终止都先发 stateChanged（按固定映射），再发 finished，finished 是最后一个事件；stop() 返回前事件流已 finish。
/// - B-5 / CR-2：.appear/.disappear(NodeID) 只记账，不执行用户代码；闭包只由 .action(ActionID) 执行。
@Suite("契约对齐（M0-C）", .timeLimit(.minutes(2)))
struct ContractAlignmentTests {
    /// 契约中 ExitReason → 终止 RunState 的固定映射。
    static func expectedState(for reason: ExitReason) -> RunState {
        switch reason {
        case .completed, .stoppedByUser: .stopped
        case .budgetExceeded: .interrupted
        case .trap, .internalError, .validationFailed: .failed
        }
    }

    /// 检查一次运行的终止序列：恰有一个 finished，且是最后一个事件；其前一个事件是 stateChanged(期望状态)。
    static func checkTermination(_ out: RunOutcome, expected: ExitReason, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let finishedCount = out.envelopes.filter { if case .finished = $0.event { return true }; return false }.count
        #expect(finishedCount == 1, "finished 次数：\(finishedCount)", sourceLocation: sourceLocation)
        guard out.envelopes.count >= 2, case .finished(let reason) = out.envelopes[out.envelopes.count - 1].event else {
            Issue.record("最后一个事件不是 finished：\(String(describing: out.envelopes.last?.event))", sourceLocation: sourceLocation)
            return
        }
        #expect(reason == expected, sourceLocation: sourceLocation)
        guard case .stateChanged(let s) = out.envelopes[out.envelopes.count - 2].event else {
            Issue.record("finished 之前不是 stateChanged", sourceLocation: sourceLocation)
            return
        }
        #expect(s == expectedState(for: reason), "终止状态 \(s)，期望 \(expectedState(for: reason))", sourceLocation: sourceLocation)
        // sequence 严格递增
        let seqs = out.envelopes.map(\.sequence)
        #expect(zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 }, sourceLocation: sourceLocation)
    }

    @Test func everyTerminationHasStateChangedThenFinished() async throws {
        // 校验失败
        Self.checkTermination(try await runScript("let x: Int = \"a\""), expected: .validationFailed)
        // 正常结束
        Self.checkTermination(try await runScript("print(1)"), expected: .completed)
        // trap（除零）
        let trap = try await runScript("let z = 0\nprint(10 / z)")
        #expect(trap.isTrap)
        if case .trap(let m)? = trap.finished { Self.checkTermination(trap, expected: .trap(m)) }
        // 预算超限 → interrupted
        let budget = try await runScript("var i = 0\nwhile true { i += 1 }", budget: TestSupport.budget(maxSteps: 50_000))
        #expect(budget.isBudget)
        if case .budgetExceeded(let m)? = budget.finished { Self.checkTermination(budget, expected: .budgetExceeded(m)) }
        #expect(budget.states.last == .interrupted)
        // 入口无效 → validationFailed
        let engine = SwiftRuntimeEngine()
        let h = try await engine.runHandle(TestSupport.script("print(1)"), entry: .rootView(symbol: "Missing"))
        var entry = RunOutcome()
        for await e in h.events { entry.envelopes.append(e) }
        await h.stop()
        Self.checkTermination(entry, expected: .validationFailed)
        // 用户停止（UI 入口）
        let s = try await UISession.start(TestSupport.program(try TestSupport.loadDirectory("counter")), entry: .rootView(symbol: "ContentView"))
        await s.stop()
        Self.checkTermination(s.outcome, expected: .stoppedByUser)
        #expect(Array(s.outcome.states.suffix(2)) == [.stopping, .stopped])
    }

    @Test func stopFinishesEventStreamBeforeReturning() async throws {
        let engine = SwiftRuntimeEngine()
        let files = try TestSupport.loadDirectory("counter")
        // UI 入口运行中停止；脚本入口无限循环中停止；校验失败后停止（已终止）
        let cases: [(ProgramSource, EntryPoint, ExecutionBudget)] = [
            (TestSupport.program(files), .rootView(symbol: "ContentView"), TestSupport.budget()),
            (TestSupport.script("var i = 0\nwhile true { i &+= 1 }"), .script(FileID("main.swift")),
             TestSupport.budget(maxSteps: Int.max / 2, slice: .seconds(3600))),
            (TestSupport.script("let x: Int = \"a\""), .script(FileID("main.swift")), TestSupport.budget()),
        ]
        for (program, entry, budget) in cases {
            let h = try await engine.runHandle(program, entry: entry, budget: budget)
            // 读到 running 或 failed（脚本入口的启动任务会一直执行到脚本结束，不能用 waitUntilStarted 等待）。
            var out = RunOutcome()
            var it = h.events.makeAsyncIterator()
            while let e = await it.next() {
                out.envelopes.append(e)
                if case .stateChanged(let s) = e.event, s == .running || s == .failed { break }
            }
            await h.stop()
            #expect(h.isEventStreamFinished, "stop() 返回时事件流必须已 finish")
            // 事件流已结束：迭代必然终止（不会挂起），且以 finished 结尾。
            while let e = await it.next() { out.envelopes.append(e) }
            if case .finished? = out.envelopes.last?.event {} else { Issue.record("流未以 finished 结尾：\(entry)") }
        }
        #expect(engine.liveCounters.liveThreads == 0)
        #expect(engine.liveCounters.liveTasks == 0)
    }

    @Test func appearAndDisappearOnlyRecordLifecycle() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var appeared = 0
            @State private var gone = 0
            var body: some View {
                VStack {
                    Text("appeared \\(appeared) gone \\(gone)")
                        .onAppear { appeared += 1 }
                        .onDisappear { gone += 1 }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let tree = try #require(s.lastTree)
        let node = try #require(tree.root.allNodes.first { n in n.modifiers.contains { if case .onAppear = $0 { return true }; return false } })
        guard case .onAppear(let appearAction)? = node.modifiers.first(where: { if case .onAppear = $0 { return true }; return false }),
              case .onDisappear(let disappearAction)? = node.modifiers.first(where: { if case .onDisappear = $0 { return true }; return false })
        else { Issue.record("缺少生命周期 modifier"); return }

        // 1) 只发 .appear / .disappear：记账，不执行闭包，不重新渲染。
        await s.send(.appear(node.id))
        var lc = await s.handle.lifecycleSnapshot()
        #expect(lc.appeared == [node.id])
        #expect(lc.appearCount == 1)
        await s.send(.disappear(node.id))
        lc = await s.handle.lifecycleSnapshot()
        #expect(lc.appeared.isEmpty)
        #expect(lc.disappearCount == 1)
        #expect(await s.handle.instance.snapshot().revision == tree.revision, "只记账的输入不应触发重新渲染")

        // 2) .action(onAppear) 才执行闭包：恰好 +1（不会因为之前的 .appear 再执行一次）。
        await s.send(.appear(node.id))
        await s.send(.action(appearAction))
        let t1 = await s.nextRender()
        #expect(t1?.root.texts.contains("appeared 1 gone 0") == true, "\(t1?.root.texts ?? [])")
        await s.send(.action(disappearAction))
        let t2 = await s.nextRender()
        #expect(t2?.root.texts.contains("appeared 1 gone 1") == true, "\(t2?.root.texts ?? [])")
        await s.stop()
        // 全程没有额外的渲染：初次 + 两次 action = 3 次
        #expect(s.outcome.renders.count == 3)
    }
}
