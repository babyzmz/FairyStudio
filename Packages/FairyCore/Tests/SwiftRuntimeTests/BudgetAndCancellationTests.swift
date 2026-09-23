import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("预算与取消", .timeLimit(.minutes(3)))
struct BudgetAndCancellationTests {
    // MARK: 预算

    @Test func infiniteLoopStopsAtMaxSteps() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let out = try await runScript("var i = 0\nwhile true { i += 1 }", budget: TestSupport.budget(maxSteps: 200_000))
        let elapsed = clock.now - start
        #expect(out.isBudget)
        #expect(out.errors.contains { $0.kind == .budgetExceeded && $0.message.contains("maxSteps") })
        #expect(elapsed < .seconds(10))
    }

    @Test func deepRecursionStopsAtMaxCallDepth() async throws {
        let out = try await runScript("""
        func down(_ n: Int) -> Int { down(n + 1) + 1 }
        print("start")
        print(down(0))
        """, budget: TestSupport.budget(maxCallDepth: 300))
        #expect(out.console == "start\n")
        #expect(out.isBudget)
        let d = try #require(out.errors.first { $0.kind == .budgetExceeded })
        #expect(d.message.contains("maxCallDepth"))
        #expect(d.range?.start.line == 1)
    }

    @Test func hugeArrayAppendStopsAtMaxCollectionElements() async throws {
        let out = try await runScript("var a: [Int] = []\nwhile true { a.append(1) }",
                                      budget: TestSupport.budget(maxElements: 10_000))
        #expect(out.isBudget)
        #expect(out.errors.contains { $0.message.contains("maxCollectionElements") })
    }

    @Test func stringGrowthStopsAtMaxStringLength() async throws {
        let out = try await runScript("var s = \"ab\"\nwhile true { s += s }", budget: TestSupport.budget(maxString: 10_000))
        #expect(out.isBudget)
        #expect(out.errors.contains { $0.message.contains("maxStringLength") })
    }

    @Test func heapGrowthStopsAtMaxHeapBytesApprox() async throws {
        let out = try await runScript("""
        var rows: [[String]] = []
        while true {
            rows.append(["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"])
        }
        """, budget: TestSupport.budget(maxHeap: 512 << 10))
        #expect(out.isBudget)
        #expect(out.errors.contains { $0.message.contains("maxHeapBytesApprox") })
    }

    @Test func uiActionInfiniteLoopHitsSliceWallClock() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State var n = 0
            var body: some View {
                Button("Spin") {
                    while true { n += 1 }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"),
                                          budget: TestSupport.budget(maxSteps: Int.max / 2, slice: .milliseconds(100)))
        let t = try await s.tap("Spin")
        #expect(t == nil)
        await s.stop()
        #expect(s.outcome.isBudget)
        #expect(s.outcome.errors.contains { $0.kind == .budgetExceeded && $0.message.contains("sliceWallClock") })
    }

    /// 宿主保护：各种会让原生 Swift 进程崩溃或耗尽栈/内存的写法，都必须变成受控诊断。
    static let pathological: [String: String] = [
        "hugeRange": "let r = Int.min..<Int.max\nprint(r.count)\nprint(r.map { $0 }.count)",
        "hugeRepeat": "let s = String(repeating: \"ab\", count: Int.max / 2)\nprint(s.count)",
        "hugeArrayRepeat": "let a = Array(repeating: 0, count: Int.max)\nprint(a.count)",
        "negateIntMin": "let m = Int.min\nprint(-m)",
        "doubleToIntOverflow": "let d = 1e300\nprint(Int(d))",
        "strideZero": "for i in stride(from: 0, to: 10, by: 0) { print(i) }",
    ]

    @Test(arguments: pathological.keys.sorted())
    func hostIsProtectedFromPathologicalPrograms(name: String) async throws {
        let code = try #require(Self.pathological[name])
        let out = try await runScript(code)
        #expect(out.isTrap || out.isBudget, "\(String(describing: out.finished)) \(out.console)")
    }

    @Test func deeplyNestedValueIsStoppedBeforeHostStackOverflow() async throws {
        let program = TestSupport.program(TestSupport.files([("main.swift", """
        struct Node { var next: [Node] }
        var head = Node(next: [])
        while true {
            head = Node(next: [head])
        }
        """)]))
        let out = try await runScript(program, budget: TestSupport.budget(maxSteps: Int.max / 2, slice: .seconds(60)))
        #expect(out.isBudget)
        #expect(out.errors.contains { $0.message.contains("嵌套") })
    }

    /// 脚本入口在时间片用完时让出执行线程，之后从同一条指令继续（结果不受让出次数影响）。
    @Test func scriptYieldsAtSliceBoundaryAndResumesCorrectly() async throws {
        let out = try await runScript("""
        var total = 0
        var items: [Int] = []
        for i in 0..<300_000 {
            total &+= i % 7
            if i % 1000 == 0 { items.append(i) }
        }
        print(total, items.count, items.last ?? -1)
        """, budget: TestSupport.budget(maxSteps: 100_000_000, slice: .milliseconds(1)))
        #expect(out.errors.isEmpty)
        #expect(out.console == "899997 300 299000\n")
        #expect(out.finished == .completed)
    }

    // MARK: 取消

    /// 实测 stop() 延迟：从调用到返回（所有内部任务与执行线程已结束）。
    @Test func stopInfiniteLoopWithin250ms() async throws {
        let engine = SwiftRuntimeEngine()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<5 {
            let h = try await engine.runHandle(TestSupport.script("var i = 0\nwhile true { i &+= 1 }"), entry: .script(FileID("main.swift")),
                                               budget: TestSupport.budget(maxSteps: Int.max / 2, slice: .seconds(3600)))
            var it = h.events.makeAsyncIterator()
            while let e = await it.next() {
                if case .stateChanged(.running) = e.event { break }
            }
            try await Task.sleep(for: .milliseconds(80))
            let t0 = clock.now
            await h.stop()
            let dt = clock.now - t0
            samples.append(dt)
            var rest: [RuntimeEventEnvelope] = []
            while let e = await it.next() { rest.append(e) }
            #expect(rest.contains { if case .finished(.stoppedByUser) = $0.event { return true }; return false })
            #expect(dt < .milliseconds(250))
        }
        let ms = samples.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
        print("[M0-A] stop() 延迟（ms）：\(ms.map { String(format: "%.3f", $0) }.joined(separator: ", "))；最大 \(String(format: "%.3f", ms.max() ?? 0))")
        #expect(engine.liveCounters.liveThreads == 0)
        #expect(engine.liveCounters.liveTasks == 0)
    }

    @Test func thirtyRunStopCyclesReleaseEverything() async throws {
        let engine = SwiftRuntimeEngine()
        let files = try TestSupport.loadDirectory("counter")
        var weakHandles: [WeakBox<SwiftRunHandle>] = []
        var weakInstances: [WeakBox<RunInstance>] = []
        for i in 0..<30 {
            let s = try await UISession.start(TestSupport.program(files), entry: .rootView(symbol: "ContentView"), engine: engine)
            if i % 2 == 0 { _ = try await s.tap("Increment") }
            weakHandles.append(WeakBox(s.handle))
            weakInstances.append(WeakBox(s.handle.instance))
            await s.stop()
        }
        // 所有强引用已随会话离开作用域
        for _ in 0..<50 where weakInstances.contains(where: { $0.value != nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakHandles.allSatisfy { $0.value == nil })
        #expect(weakInstances.allSatisfy { $0.value == nil })
        #expect(engine.liveCounters.liveInstances == 0)
        #expect(engine.liveCounters.liveThreads == 0)
        #expect(engine.liveCounters.liveTasks == 0)
        print("[M0-A] 30 次 run/stop 后：instances=\(engine.liveCounters.liveInstances) threads=\(engine.liveCounters.liveThreads) tasks=\(engine.liveCounters.liveTasks)")
    }

    @Test func lateInputsFromOldRunDoNotAffectNewRun() async throws {
        let engine = SwiftRuntimeEngine()
        let program = TestSupport.program(try TestSupport.loadDirectory("counter"))
        let old = try await UISession.start(program, entry: .rootView(symbol: "ContentView"), engine: engine)
        guard case .button(let oldAction, _)? = old.lastTree?.root.button(labeled: "Increment")?.kind else {
            Issue.record("找不到按钮"); return
        }
        let oldRunID = old.handle.runID
        await old.stop()

        let fresh = try await UISession.start(program, entry: .rootView(symbol: "ContentView"), engine: engine)
        // 1) 旧 runID 的输入发给新实例 → 丢弃
        await fresh.send(.action(oldAction), runID: oldRunID)
        // 2) 新 runID 但携带旧实例的 ActionID → 找不到动作，丢弃
        await fresh.send(.action(oldAction))
        // 3) 迟到输入发给已停止的旧句柄 → 忽略
        await old.handle.send(RuntimeInputEnvelope(runID: oldRunID, sequence: 99, input: .action(oldAction)))
        // 真实点击：revision 应为 2 且计数为 1（之前的迟到输入都没有生效）
        let t = try await fresh.tap("Increment")
        #expect(t?.revision == 2)
        #expect(t?.root.texts.contains("Count: 1") == true)
        await fresh.stop()
    }

    @Test func outOfOrderInputSequenceIsDropped() async throws {
        let program = TestSupport.program(try TestSupport.loadDirectory("counter"))
        let s = try await UISession.start(program, entry: .rootView(symbol: "ContentView"))
        guard case .button(let aid, _)? = s.lastTree?.root.button(labeled: "Increment")?.kind else { return }
        await s.handle.send(RuntimeInputEnvelope(runID: s.handle.runID, sequence: 10, input: .action(aid)))
        let t1 = await s.nextRender()
        await s.handle.send(RuntimeInputEnvelope(runID: s.handle.runID, sequence: 5, input: .action(aid)))
        await s.handle.send(RuntimeInputEnvelope(runID: s.handle.runID, sequence: 11, input: .action(aid)))
        let t2 = await s.nextRender()
        #expect(t1?.root.texts.contains("Count: 1") == true)
        #expect(t2?.root.texts.contains("Count: 2") == true)
        await s.stop()
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ v: T) { value = v }
}
