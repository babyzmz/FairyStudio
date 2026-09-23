import Testing
import Foundation
import RuntimeContracts
import SwiftRuntime
@testable import Fairy_Studio

/// 正式路径：RunCoordinator + 真实 SwiftRuntime 解释器 + App 包内的 Counter 模板（M0-C 端到端，不经过 UI）。
@MainActor
@Suite("SwiftRuntime 接入（真实引擎）", .serialized)
struct SwiftRuntimeIntegrationTests {
    private func counterTemplate() throws -> ProjectTemplate {
        try ProjectTemplate.load(named: "Counter")
    }

    private func program(_ template: ProjectTemplate, reversed: Bool = false) -> ProgramSource {
        ProgramSource(moduleName: "Experiment", files: reversed ? template.files.reversed() : template.files)
    }

    private func texts(_ tree: RenderTree?) -> [String] {
        guard let tree else { return [] }
        func walk(_ node: RenderNode) -> [String] {
            var out: [String] = []
            if case let .text(value, _) = node.kind { out.append(value) }
            for child in node.children { out += walk(child) }
            return out
        }
        return walk(tree.root)
    }

    private func button(labeled label: String, in tree: RenderTree?) -> ActionID? {
        guard let tree else { return nil }
        func walk(_ node: RenderNode) -> ActionID? {
            if case let .button(action, _) = node.kind, texts(RenderTree(runID: tree.runID, revision: 0, root: node)).contains(label) {
                return action
            }
            for child in node.children { if let found = walk(child) { return found } }
            return nil
        }
        return walk(tree.root)
    }

    @Test("EngineCatalog 的正式引擎就是 SwiftRuntimeEngine（无夹具选项）")
    func catalogUsesRealEngine() {
        #expect(EngineChoice.allCases == [.swiftRuntime])
        #expect(EngineChoice.swiftRuntime.makeEngine() is SwiftRuntimeEngine)
    }

    @Test("Counter 模板从 App 包加载：两个文件、入口 rootView(ContentView)")
    func templateLoads() throws {
        let template = try counterTemplate()
        #expect(template.entry == .rootView(symbol: "ContentView"))
        #expect(template.files.map(\.path) == ["Sources/Models/Counter.swift", "Sources/Views/ContentView.swift"])
        #expect(template.files.allSatisfy { !$0.contents.isEmpty })
        let studio = StudioModel()
        #expect(studio.files.count == 2)
        #expect(studio.coordinator.engine is SwiftRuntimeEngine)
    }

    @Test("运行 → Count: 0 → Increment ×2 → Count: 2 → 停止；状态与终止原因来自真实事件")
    func counterFlow() async throws {
        let template = try counterTemplate()
        let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
        await coordinator.run(program(template), entry: template.entry).value
        #expect(await waitUntil { coordinator.state == .running && coordinator.tree != nil })
        #expect(texts(coordinator.tree).contains("Count: 0"))
        let increment = try #require(button(labeled: "Increment", in: coordinator.tree))
        coordinator.send(.action(increment))
        #expect(await waitUntil { texts(coordinator.tree).contains("Count: 1") })
        coordinator.send(.action(increment))
        #expect(await waitUntil { texts(coordinator.tree).contains("Count: 2") })
        #expect(coordinator.lastStartLatency != nil)
        await coordinator.stop().value
        #expect(coordinator.state == .stopped)
        #expect(coordinator.exitReason == .stoppedByUser)
        #expect(coordinator.activeInstanceCount == 0)
        #expect(coordinator.lastStopLatency != nil)
    }

    @Test("文件顺序交换后 RenderTree（去掉 runID）一致")
    func fileOrderIndependence() async throws {
        let template = try counterTemplate()
        var normalized: [String] = []
        for reversed in [false, true] {
            let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
            await coordinator.run(program(template, reversed: reversed), entry: template.entry).value
            #expect(await waitUntil { coordinator.tree != nil })
            let tree = try #require(coordinator.tree)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(tree.root), as: UTF8.self)
                .replacingOccurrences(of: String(tree.runID.rawValue.uuidString.prefix(8)), with: "RUN")
            normalized.append(json)
            await coordinator.stop().value
        }
        #expect(normalized[0] == normalized[1])
    }

    @Test("修改源码（初始值 10、按钮文字）后重新运行，界面随之变化")
    func editedSourceChangesUI() async throws {
        let template = try counterTemplate()
        var files = template.files
        files[0].contents = files[0].contents.replacingOccurrences(of: "private(set) var count: Int = 0", with: "private(set) var count: Int = 10")
        files[1].contents = files[1].contents.replacingOccurrences(of: "Button(\"Increment\")", with: "Button(\"Add One\")")
        let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
        await coordinator.run(ProgramSource(moduleName: "Experiment", files: files), entry: template.entry).value
        #expect(await waitUntil { coordinator.tree != nil })
        #expect(texts(coordinator.tree).contains("Count: 10"))
        #expect(button(labeled: "Add One", in: coordinator.tree) != nil)
        #expect(button(labeled: "Increment", in: coordinator.tree) == nil)
        await coordinator.stop().value
    }

    @Test("合法但不支持的 Swift（class 继承）→ unsupportedSyntax + capability ID，不是名称错误；终止原因 validationFailed")
    func unsupportedSyntax() async throws {
        let template = try counterTemplate()
        var files = template.files
        files[0].contents += "\nclass Base {}\nclass Derived: Base {}\n"
        let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
        await coordinator.run(ProgramSource(moduleName: "Experiment", files: files), entry: template.entry).value
        #expect(coordinator.state == .failed)
        #expect(coordinator.exitReason == .validationFailed)
        let diagnostic = try #require(coordinator.diagnostics.first { $0.kind == .unsupportedSyntax })
        #expect(diagnostic.capabilityID == "syntax.class")
        #expect(diagnostic.message.contains("尚不支持"))
        #expect(!coordinator.diagnostics.contains { $0.kind == .nameResolution })
        #expect(coordinator.tree == nil)
    }

    @Test("按钮触发除零 → runtimeTrap 诊断、状态 failed、实例释放")
    func divideByZeroTrap() async throws {
        let template = try counterTemplate()
        var files = template.files
        files[0].contents = files[0].contents.replacingOccurrences(of: "count += step", with: "count += 10 / (step - step)")
        let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
        await coordinator.run(ProgramSource(moduleName: "Experiment", files: files), entry: template.entry).value
        #expect(await waitUntil { coordinator.state == .running && coordinator.tree != nil })
        let increment = try #require(button(labeled: "Increment", in: coordinator.tree))
        coordinator.send(.action(increment))
        #expect(await waitUntil { coordinator.state == .failed })
        #expect(coordinator.diagnostics.contains { $0.kind == .runtimeTrap })
        if case .trap? = coordinator.exitReason {} else { Issue.record("exitReason = \(String(describing: coordinator.exitReason))") }
        #expect(await waitUntil { !coordinator.isActive && coordinator.activeInstanceCount == 0 })
    }

    @Test("按钮里的无限循环：长预算下用户停止 ≤250ms；默认预算下被 sliceWallClock 中断为 interrupted")
    func infiniteLoopStop() async throws {
        let template = try counterTemplate()
        var files = template.files
        files[0].contents = files[0].contents.replacingOccurrences(of: "count += step", with: "while true { count += step }")
        let source = ProgramSource(moduleName: "Experiment", files: files)

        // 1) 长预算：只有用户停止能结束它。
        let coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
        let long = StudioModel.budget(from: ["app", "-fairy.budget", "long"]).0
        await coordinator.run(source, entry: template.entry, budget: long).value
        #expect(await waitUntil { coordinator.state == .running && coordinator.tree != nil })
        coordinator.send(.action(try #require(button(labeled: "Increment", in: coordinator.tree))))
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.state == .running)
        let clock = ContinuousClock()
        let t0 = clock.now
        await coordinator.stop().value
        let elapsed = clock.now - t0
        #expect(coordinator.state == .stopped)
        #expect(coordinator.exitReason == .stoppedByUser)
        let stopLatency = try #require(coordinator.lastStopLatency)
        print("[FAIRY-M0C] coordinator stop latency=\(stopLatency) completion=\(elapsed)")
        #expect(stopLatency < .milliseconds(250))

        // 2) 默认预算：UI 事件的单片墙钟 200ms 是硬上限。
        await coordinator.run(source, entry: template.entry, budget: .default).value
        #expect(await waitUntil { coordinator.state == .running && coordinator.tree != nil })
        coordinator.send(.action(try #require(button(labeled: "Increment", in: coordinator.tree))))
        #expect(await waitUntil(timeout: .seconds(5)) { coordinator.state == .interrupted })
        #expect(coordinator.diagnostics.contains { $0.kind == .budgetExceeded })
        #expect(await waitUntil { !coordinator.isActive })
    }

    @Test("连续 30 次 run/stop：协调器与引擎都无残留实例 / 线程 / 任务")
    func thirtyCyclesLeaveNothing() async throws {
        let template = try counterTemplate()
        let engine = SwiftRuntimeEngine()
        let coordinator = RunCoordinator(engine: engine)
        coordinator.refreshMetrics()
        let before = try #require(coordinator.memory)
        for index in 0..<30 {
            await coordinator.run(program(template, reversed: index % 2 == 1), entry: template.entry).value
            #expect(await waitUntil { coordinator.tree != nil })
            if index % 3 == 0, let increment = button(labeled: "Increment", in: coordinator.tree) {
                coordinator.send(.action(increment))
                #expect(await waitUntil { texts(coordinator.tree).contains("Count: 1") })
            }
            await coordinator.stop().value
            #expect(coordinator.state == .stopped)
        }
        #expect(coordinator.activeInstanceCount == 0)
        #expect(await waitUntil { engine.liveCounters.liveInstances == 0 && engine.liveCounters.liveThreads == 0 && engine.liveCounters.liveTasks == 0 },
                "引擎存活：\(engine.liveCounts)")
        coordinator.refreshMetrics()
        let after = try #require(coordinator.memory)
        #expect(coordinator.startedRunCount == 30)
        #expect(coordinator.releasedInstanceCount == 30)
        print(String(format: "[FAIRY-M0C] 30 cycles: engine=%@ resident %.1f→%.1f MB footprint %.1f→%.1f MB",
                     "\(engine.liveCounts)", before.residentMB, after.residentMB, before.footprintMB, after.footprintMB))
    }
}
