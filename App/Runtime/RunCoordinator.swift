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

    init(engine: any RuntimeEngine) {
        self.engine = engine
    }

    var isActive: Bool { activeRunID != nil }

    /// 预览区是否接受交互输入。
    var acceptsInput: Bool { activeRunID != nil && state == .running }

    // MARK: - 串行操作

    /// 运行（若已有实例则先停止）。返回的任务完成时，新实例已启动或已失败。
    @discardableResult
    func run(_ program: ProgramSource, budget: ExecutionBudget = .default) -> Task<Void, Never> {
        enqueue { coordinator in
            await coordinator.performRun(program, budget: budget)
        }
    }

    /// 停止当前实例。返回的任务完成时，实例的 stop() 已返回、事件流已排空。
    @discardableResult
    func stop() -> Task<Void, Never> {
        enqueue { coordinator in
            await coordinator.performStop(reason: "用户停止")
        }
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
            state = newState
        case let .render(newTree):
            apply(newTree)
        case let .diagnostic(diagnostic):
            diagnostics.append(diagnostic)
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
            if !state.isTerminal { state = Self.terminalState(for: reason) }
        }
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
        tree = newTree
    }

    // MARK: - 生命周期

    private func performRun(_ program: ProgramSource, budget: ExecutionBudget) async {
        await performStop(reason: "重新运行")
        tree = nil
        diagnostics = []
        exitReason = nil
        displayedRunID = nil

        state = .validating
        let validation = await engine.validate(program)
        diagnostics = validation.diagnostics
        guard validation.isRunnable else {
            state = .failed
            appendConsole(.stderr, "校验未通过：\(validation.diagnostics.filter { $0.severity == .error }.count) 个错误", runID: nil)
            return
        }

        state = .preparing
        let entry = validation.entryPoints.first ?? .rootView(symbol: "ContentView")
        do {
            let newHandle = try await engine.run(program, entry: entry, budget: budget,
                                                 options: RunOptions(runtimeVersion: engine.runtimeVersion))
            attach(newHandle)
        } catch {
            diagnostics.append(Diagnostic(kind: .internalError, message: "启动运行失败：\(error)"))
            state = .failed
        }
    }

    private func attach(_ newHandle: any RunHandle) {
        let runID = newHandle.runID
        handle = newHandle
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
        if !state.isTerminal { state = .stopping }

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
            state = .stopped
            appendConsole(.debug, "引擎未报告停止状态，以 stop() 返回为准", runID: runID)
        }
        activeRunID = nil
        handle = nil
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

    static func terminalState(for reason: ExitReason) -> RunState {
        switch reason {
        case .completed, .stoppedByUser: .stopped
        case .budgetExceeded: .interrupted
        case .trap, .internalError: .failed
        }
    }

    static func describe(_ reason: ExitReason) -> String {
        switch reason {
        case .completed: "正常结束"
        case .stoppedByUser: "用户停止"
        case let .budgetExceeded(detail): "超出预算（\(detail)）"
        case let .trap(detail): "运行时错误（\(detail)）"
        case let .internalError(detail): "内部错误（\(detail)）"
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
