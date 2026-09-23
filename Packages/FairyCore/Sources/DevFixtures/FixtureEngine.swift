import Foundation
import RuntimeContracts
import Synchronization

// 夹具引擎：按脚本回放 RenderTree 与事件，不解析、不执行用户源码。
// 只允许链接进测试目标与 FairyStudio-Verify 的 Debug 构建；界面必须显示「夹具引擎：非真实执行」横幅。
// M0-C 集成阶段会把它从 App 正式路径移除。

/// 可回放的夹具场景。
public enum FixtureScenario: String, CaseIterable, Sendable, Identifiable, Hashable {
    /// 计数器：Text + Button，收到 action 后 revision+1、数字+1。
    case counter
    /// 表单：TextField / Toggle / List + ForEach 重排。
    case form
    /// 含一个运行时尚不支持的节点。
    case unsupported
    /// 渲染一次后发出 budgetExceeded 诊断并结束。
    case budgetExceeded
    /// 覆盖全部 RenderKind（导航、sheet、alert 等），用于人工与 UI 层核对。
    case gallery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .counter: "计数器"
        case .form: "表单与列表重排"
        case .unsupported: "不支持节点"
        case .budgetExceeded: "预算超限"
        case .gallery: "组件总览"
        }
    }
}

public struct FixtureEngine: RuntimeEngine {
    public let scenario: FixtureScenario
    public var runtimeVersion: RuntimeVersion { RuntimeVersion(0, 0, 0) }

    public init(scenario: FixtureScenario) {
        self.scenario = scenario
    }

    /// 当前存活的运行实例数（用于检测 run/stop 泄漏）。
    public static var liveHandleCount: Int { FixtureRunHandle.liveCount.withLock { $0 } }

    public func validate(_ program: ProgramSource) async -> ValidationResult {
        // 夹具引擎不解析源码：如实给出 note，而不是假装校验通过。
        let note = Diagnostic(
            kind: .internalError,
            severity: .note,
            message: "夹具引擎不解析源码（忽略 \(program.files.count) 个文件），回放场景：\(scenario.displayName)"
        )
        return ValidationResult(
            diagnostics: [note],
            entryPoints: [.rootView(symbol: "Fixture.\(scenario.rawValue)")],
            referencedCapabilities: []
        )
    }

    public func run(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget, options: RunOptions) async throws -> any RunHandle {
        let handle = FixtureRunHandle(script: FixtureScripts.make(scenario))
        await handle.start()
        return handle
    }
}
