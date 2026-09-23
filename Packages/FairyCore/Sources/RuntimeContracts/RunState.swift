import Foundation

/// 运行状态机：idle → validating → preparing → running → stopping → stopped；另有 failed / interrupted。
/// UI 状态只能来自真实事件，不允许定时器伪造。
public enum RunState: String, Sendable, Codable {
    case idle, validating, preparing, running, stopping, stopped, failed, interrupted
}

public enum ExitReason: Sendable, Codable, Hashable {
    case completed                 // 脚本自然结束
    case stoppedByUser
    case budgetExceeded(String)
    case trap(String)
    case internalError(String)
}

/// 执行预算：VM 在指令循环、调用、循环回边和大集合操作处检查。CPU 预算与异步等待预算分开。
public struct ExecutionBudget: Sendable, Codable, Hashable {
    public var maxSteps: Int
    public var maxCallDepth: Int
    public var maxHeapBytesApprox: Int
    public var maxCollectionElements: Int
    public var maxStringLength: Int
    /// 单次同步执行片段（一个事件处理或一次 body 求值）允许的墙钟时间；超过则 yield 或中断。
    public var sliceWallClock: Duration
    /// 异步 I/O 等待总预算（与 CPU 步数分开）。
    public var asyncWaitLimit: Duration
    public init(maxSteps: Int = 5_000_000, maxCallDepth: Int = 512, maxHeapBytesApprox: Int = 64 << 20,
                maxCollectionElements: Int = 1_000_000, maxStringLength: Int = 4 << 20,
                sliceWallClock: Duration = .milliseconds(200), asyncWaitLimit: Duration = .seconds(30)) {
        self.maxSteps = maxSteps; self.maxCallDepth = maxCallDepth; self.maxHeapBytesApprox = maxHeapBytesApprox
        self.maxCollectionElements = maxCollectionElements; self.maxStringLength = maxStringLength
        self.sliceWallClock = sliceWallClock; self.asyncWaitLimit = asyncWaitLimit
    }
    public static let `default` = ExecutionBudget()
}
