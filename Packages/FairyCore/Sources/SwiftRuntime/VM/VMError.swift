import Foundation
import RuntimeContracts
import Synchronization

enum BudgetKind: String, Sendable {
    case steps, callDepth, heap, collection, stringLength, wallClock, hostReentry
}

/// VM 内部错误。所有运行错误都在 VM 中以受控方式抛出，绝不触发宿主进程的原生 trap。
enum VMError: Error {
    /// 用户程序运行错误：整数溢出、除零、越界、强制解包 nil…（→ DiagnosticKind.runtimeTrap）
    case trap(String)
    case budget(BudgetKind, String)
    case cancelled
    /// 静态检查未能发现的动态类型错误（→ DiagnosticKind.typeCheck）
    case typeMismatch(String)
    case unsupported(String, capabilityID: String)
    case internalError(String)
}

/// 带位置的 VM 失败。
struct VMFailure: Error {
    var error: VMError
    var range: SourceRange?
    var functionName: String?
}

/// 协作式取消令牌。stop() 在任意线程设置，VM 在检查点读取。
final class CancelToken: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .releasing) }
    var isCancelled: Bool { flag.load(ordering: .acquiring) }
}

/// 预算计量。每个"执行单元"（脚本主体 / 一次事件处理 + 重新渲染 / 一次渲染）调用 startUnit 重置步数与时钟。
final class BudgetMeter {
    enum SliceMode { case abort, yield }
    let budget: ExecutionBudget
    let cancel: CancelToken
    var steps = 0
    var sliceMode: SliceMode = .abort
    private var sliceStart = ContinuousClock.now
    private let clock = ContinuousClock()
    /// 最近一次近似堆扫描的结果（字节）。
    var lastHeapEstimate = 0

    init(budget: ExecutionBudget, cancel: CancelToken) { self.budget = budget; self.cancel = cancel }

    func startUnit(mode: SliceMode) {
        steps = 0
        sliceMode = mode
        sliceStart = clock.now
    }

    func restartSlice() { sliceStart = clock.now }

    /// 返回 true 表示当前时间片已用完（yield 模式下由调用方让出）。
    func sliceExpired() -> Bool { clock.now - sliceStart > budget.sliceWallClock }

    func checkCancel() throws {
        if cancel.isCancelled { throw VMError.cancelled }
    }

    func checkSteps() throws {
        if steps > budget.maxSteps {
            throw VMError.budget(.steps, "执行步数超过预算（maxSteps = \(budget.maxSteps)）。可能存在无限循环。")
        }
    }

    func checkCollection(_ count: Int) throws {
        if count > budget.maxCollectionElements {
            throw VMError.budget(.collection, "集合元素数超过预算（maxCollectionElements = \(budget.maxCollectionElements)）。")
        }
    }

    func checkString(_ s: String) throws {
        if s.utf8.count > budget.maxStringLength {
            throw VMError.budget(.stringLength, "字符串长度超过预算（maxStringLength = \(budget.maxStringLength) 字节）。")
        }
    }
}
