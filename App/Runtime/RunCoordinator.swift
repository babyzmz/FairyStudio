import Foundation
import Observation
import RuntimeContracts

/// 一次运行的控制台输出行。
struct ConsoleEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let runID: RunID?
    let stream: ConsoleStream
    let text: String
}

/// 运行协调器：持有引擎、管理运行实例生命周期，把事件转成 UI 状态，把 UI 输入转成带 RunID + sequence 的信封。
///
/// - UI 状态只来自真实步骤与引擎事件：validating / preparing 是协调器真正在执行的步骤，
///   running / stopped / failed / interrupted 来自引擎事件（stateChanged / finished）；
/// - 丢弃不属于当前 RunID 的事件、sequence 未递增的事件、以及 revision 倒退的 RenderTree；
/// - 重新运行 = 先 `await stop()` 旧实例，再启动新实例；所有运行/停止操作串行执行；
/// - 输入经单一队列按 sequence 顺序送达引擎。
@MainActor
@Observable
final class RunCoordinator {
    static let consoleLimit = 2_000

    private(set) var state: RunState = .idle
    /// 当前（或最近一次）运行的 RunID；仅用于显示。
    private(set) var displayedRunID: RunID?
    private(set) var tree: RenderTree?
    private(set) var console: [ConsoleEntry] = []
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var exitReason: ExitReason?
    /// 被丢弃的事件数（旧 RunID / sequence 倒退 / revision 倒退）。
    private(set) var droppedEventCount = 0
    private(set) var engine: any RuntimeEngine

    // MARK: 诊断指标（只读；界面只在 DEBUG 构建显示）
    /// 协调器当前持有的运行实例数（0 或 1）。停止/结束后必须回到 0。
    private(set) var activeInstanceCount = 0
    /// 最近一次「请求运行 → 首个 RenderTree 应用到界面」的耗时（进入运行耗时，含校验与编译）。
    private(set) var lastStartLatency: Duration?
    /// 最近一次校验（engine.validate）耗时。
    private(set) var lastValidationDuration: Duration?
    /// 最近一次「请求停止 → 状态变为终态（stopped / interrupted / failed）」的耗时。
    private(set) var lastStopLatency: Duration?
    /// 最近一次「请求停止 → 实例 stop() 返回且事件流排空、句柄释放」的耗时。
    private(set) var lastStopCompletionLatency: Duration?
    /// 本协调器发起的运行次数与完成释放的实例数。
    private(set) var startedRunCount = 0
    private(set) var releasedInstanceCount = 0
    /// 最近一次刷新的引擎存活计数与进程内存（`refreshMetrics()`；每次释放实例后自动刷新）。
    private(set) var engineLiveCounts: EngineLiveCounts?
    private(set) var memory: ProcessMemorySnapshot?
    /// 最近一次运行（从请求运行开始）经历的状态序列。
    private(set) var stateHistory: [RunState] = []

    /// 接受事件与输入的运行实例。停止后置 nil，迟到事件全部丢弃。
    private var activeRunID: RunID?
    @ObservationIgnored private var handle: (any RunHandle)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputContinuation: AsyncStream<RuntimeInputEnvelope>.Continuation?
    @ObservationIgnored private var inputSequence: UInt64 = 0
    @ObservationIgnored private var lastEventSequence: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var nextConsoleID = 0
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var runRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var stopRequestedAt: ContinuousClock.Instant?

    init(engine: any RuntimeEngine) {
        self.engine = engine
    }

    var isActive: Bool { activeRunID != nil }

    /// 预览区是否接受交互输入。
    var acceptsInput: Bool { activeRunID != nil && state == .running }

    // MARK: - 串行操作

    /// 运行（若已有实例则先停止）。返回的任务完成时，新实例已启动或已失败。
    /// - entry：项目声明的入口（M1 起来自 manifest）；nil 时取校验结果中的第一个入口。
    @discardableResult
    func run(_ program: ProgramSource, entry: EntryPoint? = nil, budget: ExecutionBudget = .default) -> Task<Void, Never> {
        runRequestedAt = clock.now
        return enqueue { coordinator in
            await coordinator.performRun(program, entry: entry, budget: budget)
        }
    }

    /// 停止当前实例。返回的任务完成时，实例的 stop() 已返回、事件流已排空。
    @discardableResult
    func stop() -> Task<Void, Never> {
        let requestedAt = clock.now
        if isActive && !state.isTerminal { stopRequestedAt = requestedAt }
        return enqueue { coordinator in
            let hadInstance = coordinator.handle != nil
            await coordinator.performStop(reason: "用户停止")
            if hadInstance { coordinator.lastStopCompletionLatency = coordinator.clock.now - requestedAt }
        }
    }

    /// 重新读取引擎存活计数与进程内存。
    func refreshMetrics() {
        engineLiveCounts = (engine as? any LiveCountReporting)?.liveCounts
        memory = ProcessMemorySnapshot.current()
    }

    /// 更换引擎（先停止当前实例）。
    @discardableResult
    func replaceEngine(_ newEngine: any RuntimeEngine) -> Task<Void, Never> {
        enqueue { coordinator in
            await coordinator.performStop(reason: "切换引擎")
            coordinator.engine = newEngine
            coordinator.tree = nil
            coordinator.state = .idle
        }
    }

    private func enqueue(_ body: @escaping @MainActor (RunCoordinator) async -> Void) -> Task<Void, Never> {
        let previous = operation
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await body(self)
        }
        operation = task
        return task
    }

    // MARK: - 输入

    /// 由 RenderTreeView 调用：补 RunID 与递增 sequence 后按顺序送达引擎。
    func send(_ input: RuntimeInput) {
        guard let runID = activeRunID, let inputContinuation, state == .running else { return }
        inputSequence += 1
        inputContinuation.yield(RuntimeInputEnvelope(runID: runID, sequence: inputSequence, input: input))
    }

    // MARK: - 事件

    /// 处理一个引擎事件（同时是测试注入点）。
    func receive(_ envelope: RuntimeEventEnvelope) {
        guard let activeRunID, envelope.runID == activeRunID else {
            droppedEventCount += 1
            return
        }
        guard envelope.sequence > lastEventSequence else {
            droppedEventCount += 1
            return
        }
        lastEventSequence = envelope.sequence

        switch envelope.event {
        case let .stateChanged(newState):
            // 引擎启动时会再次报告 validating / preparing（它内部重新编译）。协调器此时已处于 preparing，
            // 状态机只前进不回退：忽略这两个重复的前置状态，其余状态照实应用。
            if state == .preparing && (newState == .validating || newState == .preparing) { break }
            // 协调器在调用 stop() 前已进入 stopping；引擎随后报告的 stopping 不重复记录。
            if newState == state { break }
            setState(newState)
        case let .render(newTree):
            apply(newTree)
        case let .diagnostic(diagnostic):
            // 引擎启动时会重新编译并再次报告校验阶段已有的诊断（如警告），去重后再显示。
            if !diagnostics.contains(where: { Self.sameContent($0, diagnostic) }) {
                diagnostics.append(diagnostic)
            }
        case let .console(stream, text):
            appendConsole(stream, text, runID: envelope.runID)
        case let .capabilityRequest(request):
            // M0 宿主尚未接入 CapabilityKit：如实拒绝并记录诊断。
            diagnostics.append(Diagnostic(kind: .capabilityUnavailable, severity: .warning,
                                          message: "宿主尚未接入能力 \(request.capabilityID)（M2 CapabilityKit）",
                                          runID: envelope.runID, capabilityID: request.capabilityID))
            send(.capabilityResponse(request.id, .unavailable(reason: "M0 宿主尚未接入 CapabilityKit")))
        case let .finished(reason):
            exitReason = reason
            appendConsole(.debug, "运行结束：\(Self.describe(reason))", runID: envelope.runID)
            if !state.isTerminal { setState(Self.terminalState(for: reason)) }
        }
    }

    /// 状态写入的唯一入口：顺带记录停止延迟（请求停止 → 进入终态）。
    private func setState(_ newState: RunState) {
        state = newState
        stateHistory.append(newState)
        if newState.isTerminal, let requestedAt = stopRequestedAt {
            lastStopLatency = clock.now - requestedAt
            stopRequestedAt = nil
        }
    }

    private static func sameContent(_ a: Diagnostic, _ b: Diagnostic) -> Bool {
        a.kind == b.kind && a.severity == b.severity && a.message == b.message && a.range == b.range && a.capabilityID == b.capabilityID
    }

    private func apply(_ newTree: RenderTree) {
        guard newTree.runID == activeRunID else {
            droppedEventCount += 1
            return
        }
        if let current = tree, current.runID == newTree.runID, newTree.revision <= current.revision {
            droppedEventCount += 1
            return
        }
        if tree == nil, let requestedAt = runRequestedAt {
            lastStartLatency = clock.now - requestedAt
            runRequestedAt = nil
        }
        tree = newTree
    }

    // MARK: - 生命周期

    private func performRun(_ program: ProgramSource, entry preferredEntry: EntryPoint?, budget: ExecutionBudget) async {
        await performStop(reason: "重新运行")
        tree = nil
        diagnostics = []
        exitReason = nil
        displayedRunID = nil
        lastStartLatency = nil
        if runRequestedAt == nil { runRequestedAt = clock.now }
        stateHistory = [state]

        setState(.validating)
        let validationStart = clock.now
        let validation = await engine.validate(program)
        lastValidationDuration = clock.now - validationStart
        diagnostics = validation.diagnostics
        guard validation.isRunnable else {
            // 与引擎内的校验失败一致（CR-1）：状态 failed，终止原因 validationFailed。
            setState(.failed)
            exitReason = .validationFailed
            runRequestedAt = nil
            appendConsole(.stderr, "校验未通过：\(validation.diagnostics.filter { $0.severity == .error }.count) 个错误", runID: nil)
            return
        }

        setState(.preparing)
        let entry = preferredEntry ?? validation.entryPoints.first ?? .rootView(symbol: "ContentView")
        do {
            let newHandle = try await engine.run(program, entry: entry, budget: budget,
                                                 options: RunOptions(runtimeVersion: engine.runtimeVersion))
            startedRunCount += 1
            attach(newHandle)
        } catch {
            diagnostics.append(Diagnostic(kind: .internalError, message: "启动运行失败：\(error)"))
            setState(.failed)
            runRequestedAt = nil
        }
    }

    private func attach(_ newHandle: any RunHandle) {
        let runID = newHandle.runID
        handle = newHandle
        activeInstanceCount = 1
        activeRunID = runID
        displayedRunID = runID
        inputSequence = 0
        lastEventSequence = 0

        let (inputs, continuation) = AsyncStream.makeStream(of: RuntimeInputEnvelope.self, bufferingPolicy: .unbounded)
        inputContinuation = continuation
        inputTask = Task {
            for await envelope in inputs {
                await newHandle.send(envelope)
            }
        }

        let events = newHandle.events
        eventTask = Task { @MainActor [weak self] in
            for await envelope in events {
                self?.receive(envelope)
            }
            self?.eventsEnded(for: runID)
        }
    }

    /// 事件流自然结束（引擎完成、预算中断等）：释放实例。
    private func eventsEnded(for runID: RunID) {
        guard activeRunID == runID else { return }
        enqueue { coordinator in
            guard coordinator.activeRunID == runID else { return }
            await coordinator.performStop(reason: "运行已结束")
        }
    }

    private func performStop(reason: String) async {
        guard let currentHandle = handle else { return }
        let runID = currentHandle.runID
        if !state.isTerminal { setState(.stopping) }

        inputContinuation?.finish()
        inputContinuation = nil
        await currentHandle.stop()
        await inputTask?.value
        inputTask = nil

        if let eventTask {
            let drained = await Self.wait(for: eventTask, timeout: .seconds(1))
            if !drained {
                eventTask.cancel()
                diagnostics.append(Diagnostic(kind: .internalError, severity: .warning,
                                              message: "引擎在 stop() 返回后 1 秒内未关闭事件流", runID: runID))
            }
        }
        eventTask = nil

        if state == .stopping {
            // 引擎未通过事件报告终态：以 stop() 已返回（契约：返回时所有任务已失效）为准。
            setState(.stopped)
            appendConsole(.debug, "引擎未报告停止状态，以 stop() 返回为准", runID: runID)
        }
        activeRunID = nil
        handle = nil
        activeInstanceCount = 0
        releasedInstanceCount += 1
        stopRequestedAt = nil
        refreshMetrics()
        appendConsole(.debug, "实例已释放（\(reason)）", runID: runID)
    }

    private static func wait(for task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - 辅助

    private func appendConsole(_ stream: ConsoleStream, _ text: String, runID: RunID?) {
        nextConsoleID += 1
        console.append(ConsoleEntry(id: nextConsoleID, runID: runID, stream: stream, text: text))
        if console.count > Self.consoleLimit {
            console.removeFirst(console.count - Self.consoleLimit)
        }
    }

    func clearConsole() {
        console.removeAll()
    }

    /// 宿主自身的错误（例如模板加载失败）：作为 internalError 诊断显示。
    func reportHostError(_ message: String) {
        diagnostics.append(Diagnostic(kind: .internalError, message: message))
    }

    static func terminalState(for reason: ExitReason) -> RunState {
        switch reason {
        case .completed, .stoppedByUser: .stopped
        case .budgetExceeded: .interrupted
        case .trap, .internalError, .validationFailed: .failed
        }
    }

    static func describe(_ reason: ExitReason) -> String {
        switch reason {
        case .completed: "正常结束"
        case .stoppedByUser: "用户停止"
        case let .budgetExceeded(detail): "超出预算（\(detail)）"
        case let .trap(detail): "运行时错误（\(detail)）"
        case let .internalError(detail): "内部错误（\(detail)）"
        case .validationFailed: "校验未通过"
        }
    }
}

extension RunState {
    var isTerminal: Bool {
        switch self {
        case .idle, .stopped, .failed, .interrupted: true
        case .validating, .preparing, .running, .stopping: false
        }
    }

    var displayName: String {
        switch self {
        case .idle: "空闲"
        case .validating: "校验中"
        case .preparing: "准备中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .stopped: "已停止"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
}
