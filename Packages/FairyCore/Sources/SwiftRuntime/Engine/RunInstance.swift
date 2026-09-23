import Foundation
import RuntimeContracts
import Synchronization

/// 事件发射器：为事件分配单调递增的 sequence 并写入 AsyncStream。线程安全。
final class EventEmitter: Sendable {
    let runID: RunID
    private let state: Mutex<(seq: UInt64, cont: AsyncStream<RuntimeEventEnvelope>.Continuation?)>

    init(runID: RunID, continuation: AsyncStream<RuntimeEventEnvelope>.Continuation) {
        self.runID = runID
        self.state = Mutex((0, continuation))
    }

    func emit(_ e: RuntimeEvent) {
        state.withLock { s in
            guard let c = s.cont else { return }
            s.seq += 1
            c.yield(RuntimeEventEnvelope(runID: runID, sequence: s.seq, event: e))
        }
    }

    func finish() {
        state.withLock { s in
            s.cont?.finish()
            s.cont = nil
        }
    }

    var isFinished: Bool { state.withLock { $0.cont == nil } }
}

/// 一个运行实例。actor 运行在专用线程执行器上（非 MainActor）。
///
/// 事件顺序（严格按 RunState）：
/// - 成功：validating → preparing → running → [render/console…] → (stopping → stopped → finished(.completed | .stoppedByUser))
/// - 校验失败：validating → diagnostic… → failed（事件流结束，不发 finished；见 CONTRACT_REQUESTS.md）
/// - 运行错误：… → diagnostic(runtimeTrap/budgetExceeded…) → failed → finished(.trap | .budgetExceeded | .internalError)
actor RunInstance {
    nonisolated let executor: ThreadExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    let runID: RunID
    let emitter: EventEmitter
    let cancel: CancelToken
    let budget: ExecutionBudget
    let options: RunOptions
    let counters: RuntimeLiveCounters

    private var state: RunState = .idle
    private var terminal = false
    private var vm: VM?
    private var meter: BudgetMeter?
    private var evaluator: ViewEvaluator?
    private var store: StateStore?
    private var rootView: Value?
    private var revision: UInt64 = 0
    private var lastInputSequence: UInt64?
    private var isUIEntry = false

    init(runID: RunID, emitter: EventEmitter, cancel: CancelToken, budget: ExecutionBudget, options: RunOptions,
         executor: ThreadExecutor, counters: RuntimeLiveCounters) {
        self.runID = runID; self.emitter = emitter; self.cancel = cancel; self.budget = budget; self.options = options
        self.executor = executor; self.counters = counters
        counters.instanceCreated()
    }

    deinit { counters.instanceDestroyed() }

    private func setState(_ s: RunState) {
        state = s
        emitter.emit(.stateChanged(s))
    }

    private func diagnostic(_ kind: DiagnosticKind, _ message: String, range: SourceRange? = nil, capability: String? = nil,
                            severity: DiagnosticSeverity = .error) {
        emitter.emit(.diagnostic(Diagnostic(kind: kind, severity: severity, message: message, range: range, runID: runID,
                                            capabilityID: capability)))
    }

    private func becomeTerminal(state s: RunState, reason: ExitReason) {
        guard !terminal else { return }
        terminal = true
        if s == .stopped { setState(.stopping) }
        setState(s)
        emitter.emit(.finished(reason))
        emitter.finish()
        vm = nil
        evaluator = nil
        rootView = nil
        executor.requestShutdown()
    }

    // MARK: - 启动

    func start(program source: ProgramSource, entry: EntryPoint) async {
        if cancel.isCancelled { return }
        setState(.validating)
        let out = Compiler(source: source).compile()
        for var d in out.diagnostics {
            d.runID = runID
            emitter.emit(.diagnostic(d))
        }
        guard !out.hasErrors, let program = out.program else {
            terminal = true
            setState(.failed)
            emitter.finish()
            executor.requestShutdown()
            return
        }
        if cancel.isCancelled { return }
        setState(.preparing)
        let meter = BudgetMeter(budget: budget, cancel: cancel)
        let vm = VM(program: program, meter: meter)
        let emitter = self.emitter
        vm.console = { stream, text in emitter.emit(.console(stream, text)) }
        self.vm = vm
        self.meter = meter

        switch entry {
        case .script(let fid):
            guard let f = program.scriptFunction else {
                entryError("入口 .script(\(fid)) 无效：项目中没有 main.swift 顶层语句。")
                return
            }
            if !source.files.contains(where: { $0.id == fid }) {
                entryError("入口 .script(\(fid)) 无效：找不到该文件。")
                return
            }
            let expectedFile = program.functions[f].fileIndex
            let sortedFiles = source.files.sorted { ($0.path, $0.id.rawValue) < ($1.path, $1.id.rawValue) }
            if expectedFile < sortedFiles.count, sortedFiles[expectedFile].id != fid {
                entryError("入口 .script(\(fid)) 无效：顶层语句位于 \(sortedFiles[expectedFile].path)。")
                return
            }
            setState(.running)
            await runScript(function: f)
        case .rootView(let symbol):
            guard let tid = program.typeByName[symbol], program.types[tid].isView else {
                entryError("入口 .rootView(\(symbol)) 无效：找不到名为 '\(symbol)' 的 View。")
                return
            }
            setState(.running)
            startUI {
                let info = vm.program.types[tid]
                var rec = try vm.defaultRecord(tid)
                if let initFn = info.zeroArgInit {
                    guard case .record(let r) = try vm.invokeFunction(initFn, [.record(rec)]) else {
                        throw VMError.internalError("init 未返回记录")
                    }
                    rec = r
                } else if let missing = rec.fields.indices.first(where: {
                    if case .void = rec.fields[$0] { return true }; return false
                }) {
                    throw VMError.typeMismatch("根视图 '\(symbol)' 不能无参构造：属性 '\(info.fieldNames[missing])' 没有默认值。")
                }
                return .record(rec)
            }
        case .mainApp:
            guard let f = program.appRootFunction else {
                entryError("入口 .mainApp 无效：项目中没有 `@main struct …: App`（含 WindowGroup）。")
                return
            }
            setState(.running)
            startUI { try vm.invokeFunction(f, []) }
        }
    }

    private func entryError(_ message: String) {
        diagnostic(.typeCheck, message, capability: "syntax.mainApp")
        becomeTerminal(state: .failed, reason: .internalError(message))
    }

    private func runScript(function f: Int) async {
        guard let vm, let meter else { return }
        meter.startUnit(mode: .yield)
        do {
            try vm.startTopLevel(function: f)
            while true {
                switch try vm.resumeTopLevel() {
                case .returned:
                    becomeTerminal(state: .stopped, reason: .completed)
                    return
                case .yielded:
                    await Task.yield()
                    if cancel.isCancelled || terminal { return }
                }
            }
        } catch {
            handleFailure(error)
        }
    }

    private func startUI(makeRoot: () throws -> Value) {
        guard let vm, let meter else { return }
        isUIEntry = true
        let store = StateStore(program: vm.program)
        self.store = store
        let token = String(runID.rawValue.uuidString.prefix(8))
        evaluator = ViewEvaluator(vm: vm, store: store, runToken: token)
        meter.startUnit(mode: .abort)
        do {
            rootView = try makeRoot()
            try renderAndEmit()
        } catch {
            handleFailure(error)
        }
    }

    private func renderAndEmit() throws {
        guard let evaluator, let rootView else { return }
        let root = try evaluator.render(root: rootView)
        for w in evaluator.warnings { diagnostic(.typeCheck, w, severity: .warning) }
        revision += 1
        emitter.emit(.render(RenderTree(runID: runID, revision: revision, root: root)))
    }

    private func handleFailure(_ error: Error) {
        vm?.resetExecutionState()
        let failure: VMFailure
        if let f = error as? VMFailure { failure = f } else if let e = error as? VMError {
            failure = VMFailure(error: e, range: nil, functionName: nil)
        } else {
            failure = VMFailure(error: .internalError("\(error)"), range: nil, functionName: nil)
        }
        let whereText = failure.functionName.map { "（在 \($0) 中）" } ?? ""
        switch failure.error {
        case .cancelled:
            return  // stop() 负责后续事件
        case .trap(let msg):
            diagnostic(.runtimeTrap, "运行错误：\(msg)\(whereText)", range: failure.range)
            becomeTerminal(state: .failed, reason: .trap(msg))
        case .budget(let kind, let msg):
            diagnostic(.budgetExceeded, "预算超限（\(kind.rawValue)）：\(msg)", range: failure.range)
            becomeTerminal(state: .failed, reason: .budgetExceeded(msg))
        case .typeMismatch(let msg):
            diagnostic(.typeCheck, "运行时类型错误：\(msg)\(whereText)", range: failure.range)
            becomeTerminal(state: .failed, reason: .trap(msg))
        case .unsupported(let msg, let cap):
            diagnostic(.unsupportedAPI, "运行时尚不支持：\(msg)", range: failure.range, capability: cap)
            becomeTerminal(state: .failed, reason: .trap("运行时尚不支持：\(msg)"))
        case .internalError(let msg):
            diagnostic(.internalError, "解释器内部错误：\(msg)", range: failure.range)
            becomeTerminal(state: .failed, reason: .internalError(msg))
        }
    }

    // MARK: - 输入

    func handle(_ envelope: RuntimeInputEnvelope) async {
        guard envelope.runID == runID, !terminal, !cancel.isCancelled, isUIEntry, let evaluator, let meter else { return }
        if let last = lastInputSequence, envelope.sequence <= last { return }
        lastInputSequence = envelope.sequence
        meter.startUnit(mode: .abort)
        do {
            switch envelope.input {
            case .action(let aid):
                guard let f = evaluator.actions[aid.rawValue] else { return }
                _ = try evaluator.vm.invoke(f, [])
            case .setBinding(let bid, let value):
                guard let b = evaluator.bindings[bid.rawValue] else { return }
                let current = try b.get()
                let newValue = try TransferConvert.fromTransfer(value, matching: current)
                try b.set(newValue)
            case .appear(let nid):
                for f in evaluator.appearHandlers[nid.rawValue] ?? [] { _ = try evaluator.vm.invoke(f, []) }
            case .disappear(let nid):
                for f in evaluator.disappearHandlers[nid.rawValue] ?? [] { _ = try evaluator.vm.invoke(f, []) }
            case .navigationPop, .navigationPush, .dismissSheet, .capabilityResponse:
                return   // M0 未实现的输入：忽略
            }
            if store?.dirty == true { try renderAndEmit() }
        } catch {
            handleFailure(error)
        }
    }

    // MARK: - 停止

    func shutdown() {
        guard !terminal else { return }
        becomeTerminal(state: .stopped, reason: .stoppedByUser)
    }

    // MARK: - 测试/CLI 辅助（只读快照）

    func snapshot() -> (state: RunState, revision: UInt64, actionIDs: [String], bindingIDs: [String]) {
        (state, revision, evaluator.map { Array($0.actions.keys).sorted() } ?? [], evaluator.map { Array($0.bindings.keys).sorted() } ?? [])
    }
}

/// RunHandle 实现。
public final class SwiftRunHandle: RunHandle {
    public let runID: RunID
    public let events: AsyncStream<RuntimeEventEnvelope>
    let emitter: EventEmitter
    let cancel: CancelToken
    let executor: ThreadExecutor
    let instance: RunInstance
    let counters: RuntimeLiveCounters
    private let startTask = Mutex<Task<Void, Never>?>(nil)
    private let stopped = Mutex<Bool>(false)

    init(budget: ExecutionBudget, options: RunOptions, counters: RuntimeLiveCounters) {
        let runID = RunID()
        self.runID = runID
        let (stream, continuation) = AsyncStream<RuntimeEventEnvelope>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.emitter = EventEmitter(runID: runID, continuation: continuation)
        self.cancel = CancelToken()
        self.counters = counters
        self.executor = ThreadExecutor(name: "FairyRuntime.run.\(runID.rawValue.uuidString.prefix(8))", counters: counters)
        self.instance = RunInstance(runID: runID, emitter: emitter, cancel: cancel, budget: budget, options: options,
                                    executor: executor, counters: counters)
    }

    func start(program: ProgramSource, entry: EntryPoint) {
        let instance = self.instance
        let counters = self.counters
        counters.taskStarted()
        let t = Task {
            await instance.start(program: program, entry: entry)
            counters.taskEnded()
        }
        startTask.withLock { $0 = t }
    }

    public func send(_ input: RuntimeInputEnvelope) async {
        guard input.runID == runID, !stopped.withLock({ $0 }) else { return }
        await instance.handle(input)
    }

    /// 协作式停止：设置取消标志 → 等待启动任务结束 → 发出 stopping/stopped/finished → 执行线程退出后返回。
    public func stop() async {
        cancel.cancel()
        let t = startTask.withLock { $0 }
        await t?.value
        await instance.shutdown()
        executor.requestShutdown()
        await executor.join()
        stopped.withLock { $0 = true }
    }

    /// 等待启动阶段（校验 + 初次运行/渲染）完成。
    public func waitUntilStarted() async {
        let t = startTask.withLock { $0 }
        await t?.value
    }

    /// 当前可用的 ActionID / BindingID（CLI 与测试用）。
    public func currentActionIDs() async -> [ActionID] { await instance.snapshot().actionIDs.map(ActionID.init) }
    public func currentBindingIDs() async -> [BindingID] { await instance.snapshot().bindingIDs.map(BindingID.init) }
}
