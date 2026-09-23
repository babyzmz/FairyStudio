import Foundation
import RuntimeContracts

/// SwiftRuntime 对外入口：实现 `RuntimeEngine`。
///
/// 执行链路：SwiftParser 解析 → 每文件 source map → 跨文件声明索引 → 名称解析与语义检查 → 槽位化 IR → VM → RenderTree。
public struct SwiftRuntimeEngine: RuntimeEngine {
    public static let version = RuntimeVersion(0, 1, 0)
    public var runtimeVersion: RuntimeVersion { Self.version }
    /// 活跃实例/线程/任务计数（每个引擎独立）。
    public let liveCounters: RuntimeLiveCounters

    public init() { liveCounters = RuntimeLiveCounters() }

    public func validate(_ program: ProgramSource) async -> ValidationResult {
        let out = await BigStack.run { Compiler(source: program).compile() }
        return ValidationResult(diagnostics: out.diagnostics, entryPoints: out.entryPoints, referencedCapabilities: out.capabilities)
    }

    public func run(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget, options: RunOptions) async throws -> any RunHandle {
        try await runHandle(program, entry: entry, budget: budget, options: options)
    }

    /// 与 run 相同，但返回具体类型（提供 CLI/测试辅助方法）。
    public func runHandle(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget = .default,
                          options: RunOptions = RunOptions(runtimeVersion: SwiftRuntimeEngine.version)) async throws -> SwiftRunHandle {
        let h = SwiftRunHandle(budget: budget, options: options, counters: liveCounters)
        h.start(program: program, entry: entry)
        return h
    }

    /// machine-readable capability catalog。
    public static var catalog: CapabilityCatalog { CapabilityCatalogData.catalog }
}
