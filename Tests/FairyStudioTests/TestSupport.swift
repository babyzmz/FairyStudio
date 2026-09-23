import Foundation
import Synchronization
import RuntimeContracts
@testable import Fairy_Studio

/// 在 MainActor 上轮询条件（真实等待异步事件，不伪造时间）。
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// 在 RenderNode 树中按 NodeID 查找节点。
func findNode(_ id: String, in node: RenderNode) -> RenderNode? {
    if node.id.rawValue == id { return node }
    for child in node.children {
        if let found = findNode(id, in: child) { return found }
    }
    return nil
}

func text(of id: String, in tree: RenderTree?) -> String? {
    guard let tree, let node = findNode(id, in: tree.root), case let .text(value, _) = node.kind else { return nil }
    return value
}

let sampleProgram = ProgramSource(moduleName: "Tests", files: [SourceFile(id: FileID("f"), path: "main.swift", contents: "")])

/// 测试专用引擎：记录 validate / run / stop 的顺序，验证「重新运行 = 先停旧再启新」。
final class RecordingEngine: RuntimeEngine {
    let log = Mutex<[String]>([])
    private let counter = Mutex(0)
    var runtimeVersion: RuntimeVersion { RuntimeVersion(0, 0, 1) }

    func validate(_ program: ProgramSource) async -> ValidationResult {
        log.withLock { $0.append("validate") }
        return ValidationResult(diagnostics: [], entryPoints: [.rootView(symbol: "Root")], referencedCapabilities: [])
    }

    func run(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget, options: RunOptions) async throws -> any RunHandle {
        let index = counter.withLock { value -> Int in
            value += 1
            return value
        }
        log.withLock { $0.append("run:\(index)") }
        return RecordingHandle(index: index, log: self)
    }

    var entries: [String] { log.withLock { $0 } }
}

actor RecordingHandle: RunHandle {
    nonisolated let runID = RunID()
    nonisolated let events: AsyncStream<RuntimeEventEnvelope>
    private let continuation: AsyncStream<RuntimeEventEnvelope>.Continuation
    private let index: Int
    private let engine: RecordingEngine

    init(index: Int, log engine: RecordingEngine) {
        self.index = index
        self.engine = engine
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEventEnvelope.self)
        self.events = stream
        self.continuation = continuation
        continuation.yield(RuntimeEventEnvelope(runID: runID, sequence: 1, event: .stateChanged(.running)))
    }

    func send(_ input: RuntimeInputEnvelope) async {}

    func stop() async {
        engine.log.withLock { $0.append("stop-begin:\(index)") }
        // 模拟需要时间的清理：新实例不得在此期间启动。
        try? await Task.sleep(for: .milliseconds(50))
        continuation.yield(RuntimeEventEnvelope(runID: runID, sequence: 2, event: .stateChanged(.stopped)))
        continuation.finish()
        engine.log.withLock { $0.append("stop-end:\(index)") }
    }
}
