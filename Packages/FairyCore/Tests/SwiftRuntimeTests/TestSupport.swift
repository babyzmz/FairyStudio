import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// 测试辅助：夹具加载、运行事件收集、UI 会话。
enum TestSupport {
    static var fixturesURL: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    /// 加载夹具目录（相对路径作为 FileID 与 path）。
    static func loadDirectory(_ name: String) throws -> [SourceFile] {
        let base = fixturesURL.appendingPathComponent(name).standardizedFileURL
        let fm = FileManager.default
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [SourceFile] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let full = url.standardizedFileURL.path
            let rel = String(full.dropFirst(base.path.count + 1))
            out.append(SourceFile(id: FileID(rel), path: rel, contents: try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func files(_ pairs: [(String, String)]) -> [SourceFile] {
        pairs.map { SourceFile(id: FileID($0.0), path: $0.0, contents: $0.1) }
    }

    static func program(_ files: [SourceFile], module: String = "main") -> ProgramSource {
        ProgramSource(moduleName: module, files: files)
    }

    static func script(_ code: String) -> ProgramSource {
        program(files([("main.swift", code)]))
    }

    static func budget(maxSteps: Int = 5_000_000, maxCallDepth: Int = 512, maxHeap: Int = 64 << 20,
                       maxElements: Int = 1_000_000, maxString: Int = 4 << 20,
                       slice: Duration = .seconds(5)) -> ExecutionBudget {
        ExecutionBudget(maxSteps: maxSteps, maxCallDepth: maxCallDepth, maxHeapBytesApprox: maxHeap,
                        maxCollectionElements: maxElements, maxStringLength: maxString, sliceWallClock: slice)
    }
}

/// 一次运行的完整事件记录。
struct RunOutcome {
    var envelopes: [RuntimeEventEnvelope] = []
    var console: String {
        envelopes.compactMap { if case .console(_, let t) = $0.event { return t }; return nil }.joined()
    }
    var diagnostics: [Diagnostic] {
        envelopes.compactMap { if case .diagnostic(let d) = $0.event { return d }; return nil }
    }
    var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    var states: [RunState] {
        envelopes.compactMap { if case .stateChanged(let s) = $0.event { return s }; return nil }
    }
    var finished: ExitReason? {
        for e in envelopes.reversed() { if case .finished(let r) = e.event { return r } }
        return nil
    }
    var renders: [RenderTree] {
        envelopes.compactMap { if case .render(let t) = $0.event { return t }; return nil }
    }
    var isTrap: Bool { if case .trap? = finished { return true }; return false }
    var isBudget: Bool { if case .budgetExceeded? = finished { return true }; return false }
}

/// 运行脚本直至事件流结束。
func runScript(_ program: ProgramSource, budget: ExecutionBudget = TestSupport.budget(),
               engine: SwiftRuntimeEngine = SwiftRuntimeEngine()) async throws -> RunOutcome {
    let fid = program.files.first { $0.path.hasSuffix("main.swift") }?.id ?? program.files[0].id
    let h = try await engine.runHandle(program, entry: .script(fid), budget: budget)
    var out = RunOutcome()
    for await e in h.events { out.envelopes.append(e) }
    await h.stop()
    return out
}

func runScript(_ code: String, budget: ExecutionBudget = TestSupport.budget()) async throws -> RunOutcome {
    try await runScript(TestSupport.script(code), budget: budget)
}

/// 校验（编译）并返回诊断。
func validate(_ program: ProgramSource) async -> ValidationResult {
    await SwiftRuntimeEngine().validate(program)
}

/// UI 运行会话：等待渲染、发送输入。
final class UISession {
    let handle: SwiftRunHandle
    private var iterator: AsyncStream<RuntimeEventEnvelope>.AsyncIterator
    private(set) var outcome = RunOutcome()
    private(set) var lastTree: RenderTree?
    private var seq: UInt64 = 0

    private init(handle: SwiftRunHandle) {
        self.handle = handle
        self.iterator = handle.events.makeAsyncIterator()
    }

    static func start(_ program: ProgramSource, entry: EntryPoint, engine: SwiftRuntimeEngine = SwiftRuntimeEngine(),
                      budget: ExecutionBudget = TestSupport.budget()) async throws -> UISession {
        let h = try await engine.runHandle(program, entry: entry, budget: budget)
        let s = UISession(handle: h)
        _ = await s.nextRender()
        return s
    }

    /// 读取事件直到下一次渲染；若运行结束则返回 nil。
    @discardableResult
    func nextRender() async -> RenderTree? {
        var it = iterator
        defer { iterator = it }
        while let e = await it.next() {
            outcome.envelopes.append(e)
            switch e.event {
            case .render(let t):
                lastTree = t
                return t
            case .finished:
                return nil
            case .stateChanged(.failed):
                // 校验失败时没有 finished：继续读到流结束
                continue
            default:
                continue
            }
        }
        return nil
    }

    /// 读完剩余事件。
    func drain() async {
        var it = iterator
        defer { iterator = it }
        while let e = await it.next() { outcome.envelopes.append(e) }
    }

    func send(_ input: RuntimeInput, runID: RunID? = nil) async {
        seq += 1
        await handle.send(RuntimeInputEnvelope(runID: runID ?? handle.runID, sequence: seq, input: input))
    }

    /// 点击指定标题的按钮并等待重新渲染。
    func tap(_ label: String) async throws -> RenderTree? {
        let tree = try #require(lastTree)
        let b = try #require(tree.root.button(labeled: label), "找不到按钮 \(label)")
        guard case .button(let aid, _) = b.kind else { return nil }
        await send(.action(aid))
        return await nextRender()
    }

    func stop() async {
        await handle.stop()
        await drain()
    }
}

extension RenderNode {
    var allNodes: [RenderNode] { [self] + children.flatMap(\.allNodes) }

    var texts: [String] {
        allNodes.compactMap { if case .text(let s, _) = $0.kind { return s }; return nil }
    }

    func button(labeled label: String) -> RenderNode? {
        allNodes.first { n in
            if case .button = n.kind { return n.texts.contains(label) }
            return false
        }
    }

    var textFields: [RenderNode] {
        allNodes.filter { if case .textField = $0.kind { return true }; return false }
    }

    var toggles: [RenderNode] {
        allNodes.filter { if case .toggle = $0.kind { return true }; return false }
    }

    func node(withText s: String) -> RenderNode? {
        allNodes.first { if case .text(let t, _) = $0.kind { return t == s }; return false }
    }
}

/// 规范化 RenderTree（去掉每次运行不同的 runID/token），用于比较两次运行。
func normalizedJSON(_ tree: RenderTree) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let token = String(tree.runID.rawValue.uuidString.prefix(8))
    var s = String(data: try! enc.encode(tree.root), encoding: .utf8)!
    s = s.replacingOccurrences(of: token, with: "RUN")
    return "rev\(tree.revision):" + s
}
