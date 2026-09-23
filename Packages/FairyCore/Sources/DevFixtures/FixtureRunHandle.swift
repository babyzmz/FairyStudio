import Foundation
import RuntimeContracts
import Synchronization

/// 夹具脚本产生的一步输出。
enum FixtureOutput: Sendable {
    case console(ConsoleStream, String)
    case diagnostic(Diagnostic)
    /// 以当前脚本状态重新渲染（revision + 1）。
    case rerender
    /// 结束运行：发出 finished 与对应状态后关闭事件流。
    case finish(ExitReason, RunState)
}

/// 一个夹具脚本：纯值状态机，由 FixtureRunHandle 串行驱动。
protocol FixtureScript: Sendable {
    var scenario: FixtureScenario { get }
    /// 首帧渲染之后的启动输出。
    mutating func start() -> [FixtureOutput]
    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput]
    func render() -> RenderNode
}

/// 夹具运行实例。actor 保证输入按顺序处理；stop() 返回时事件流已关闭。
public actor FixtureRunHandle: RunHandle {
    static let liveCount = Mutex<Int>(0)

    public nonisolated let runID: RunID
    public nonisolated let events: AsyncStream<RuntimeEventEnvelope>
    private let continuation: AsyncStream<RuntimeEventEnvelope>.Continuation
    private var script: any FixtureScript
    private var eventSequence: UInt64 = 0
    private var lastInputSequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var isFinished = false

    init(script: any FixtureScript) {
        self.runID = RunID()
        self.script = script
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEventEnvelope.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
        Self.liveCount.withLock { $0 += 1 }
    }

    deinit {
        continuation.finish()
        Self.liveCount.withLock { $0 -= 1 }
    }

    func start() {
        emit(.stateChanged(.running))
        emit(.console(.debug, "夹具引擎启动：\(script.scenario.displayName)（非真实执行）"))
        emit(.render(nextTree()))
        apply(script.start())
    }

    public func send(_ input: RuntimeInputEnvelope) async {
        guard !isFinished else { return }
        guard input.runID == runID else {
            emit(.console(.debug, "丢弃不属于本实例的输入 #\(input.sequence)"))
            return
        }
        guard input.sequence > lastInputSequence else {
            emit(.console(.debug, "丢弃乱序输入 #\(input.sequence)（已处理到 #\(lastInputSequence)）"))
            return
        }
        lastInputSequence = input.sequence
        apply(script.handle(input.input))
    }

    public func stop() async {
        guard !isFinished else { return }
        finish(.stoppedByUser, state: .stopped)
    }

    private func apply(_ outputs: [FixtureOutput]) {
        for output in outputs {
            guard !isFinished else { return }
            switch output {
            case let .console(stream, text):
                emit(.console(stream, text))
            case let .diagnostic(diagnostic):
                var stamped = diagnostic
                stamped.runID = runID
                emit(.diagnostic(stamped))
            case .rerender:
                emit(.render(nextTree()))
            case let .finish(reason, state):
                finish(reason, state: state)
            }
        }
    }

    private func finish(_ reason: ExitReason, state: RunState) {
        isFinished = true
        emit(.finished(reason))
        emit(.stateChanged(state))
        continuation.finish()
    }

    private func nextTree() -> RenderTree {
        revision += 1
        return RenderTree(runID: runID, revision: revision, root: script.render())
    }

    private func emit(_ event: RuntimeEvent) {
        eventSequence += 1
        continuation.yield(RuntimeEventEnvelope(runID: runID, sequence: eventSequence, event: event))
    }
}

enum FixtureScripts {
    static func make(_ scenario: FixtureScenario) -> any FixtureScript {
        switch scenario {
        case .counter: CounterScript()
        case .form: FormScript()
        case .unsupported: UnsupportedScript()
        case .budgetExceeded: BudgetScript()
        case .gallery: GalleryScript()
        }
    }
}
