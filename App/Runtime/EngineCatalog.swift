import Foundation
import RuntimeContracts
import SwiftRuntime
#if FAIRY_VERIFY_BUILD && DEBUG
import DevFixtures
#endif

/// App 可选的执行引擎。
/// - `swiftRuntime`：正式路径（SwiftRuntime 解释器），M0-C 集成时接入；
/// - `fixture`：夹具引擎，仅在 FAIRY_VERIFY_BUILD && DEBUG 构建中存在，界面必须显示「夹具引擎：非真实执行」横幅。
enum EngineChoice: Hashable, Identifiable {
    case swiftRuntime
    #if FAIRY_VERIFY_BUILD && DEBUG
    case fixture(FixtureScenario)
    #endif

    var id: String {
        switch self {
        case .swiftRuntime: "swiftRuntime"
        #if FAIRY_VERIFY_BUILD && DEBUG
        case let .fixture(scenario): "fixture.\(scenario.rawValue)"
        #endif
        }
    }

    var displayName: String {
        switch self {
        case .swiftRuntime: "SwiftRuntime 解释器"
        #if FAIRY_VERIFY_BUILD && DEBUG
        case let .fixture(scenario): "夹具：\(scenario.displayName)"
        #endif
        }
    }

    var isFixture: Bool {
        switch self {
        case .swiftRuntime: false
        #if FAIRY_VERIFY_BUILD && DEBUG
        case .fixture: true
        #endif
        }
    }

    static var allChoices: [EngineChoice] {
        var choices: [EngineChoice] = [.swiftRuntime]
        #if FAIRY_VERIFY_BUILD && DEBUG
        choices += FixtureScenario.allCases.map { .fixture($0) }
        #endif
        return choices
    }

    /// 启动参数 `-fairy.engine <id>`（仅用于 UI 测试选择夹具；正式构建只识别 swiftRuntime）。
    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> EngineChoice? {
        guard let index = arguments.firstIndex(of: "-fairy.engine"), arguments.indices.contains(index + 1) else { return nil }
        let id = arguments[index + 1]
        return allChoices.first { $0.id == id }
    }

    func makeEngine() -> any RuntimeEngine {
        switch self {
        case .swiftRuntime:
            PendingSwiftRuntimeEngine()
        #if FAIRY_VERIFY_BUILD && DEBUG
        case let .fixture(scenario):
            FixtureEngine(scenario: scenario)
        #endif
        }
    }
}

/// SwiftRuntime 在 M0-B 时仍是占位（M0-A 并行实现）。这里如实报告「尚未接入」，
/// 不伪造运行结果。M0-C 集成时替换为 SwiftRuntime 提供的 RuntimeEngine 实现。
struct PendingSwiftRuntimeEngine: RuntimeEngine {
    var runtimeVersion: RuntimeVersion { RuntimeVersion(0, 0, 0) }

    func validate(_ program: ProgramSource) async -> ValidationResult {
        ValidationResult(
            diagnostics: [Diagnostic(kind: .internalError, severity: .error,
                                     message: "SwiftRuntime 解释器尚未接入 App（M0-C 集成后可用）",
                                     suggestion: "验证构建中可在引擎菜单选择夹具引擎检查渲染与协调器")],
            entryPoints: [],
            referencedCapabilities: []
        )
    }

    func run(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget, options: RunOptions) async throws -> any RunHandle {
        throw PendingEngineError.notIntegrated
    }

    enum PendingEngineError: Error, CustomStringConvertible {
        case notIntegrated
        var description: String { "SwiftRuntime 尚未接入" }
    }
}
