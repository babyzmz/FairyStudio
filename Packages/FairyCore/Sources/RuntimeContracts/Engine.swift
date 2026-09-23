import Foundation

public struct SourceFile: Sendable, Hashable, Codable {
    public var id: FileID
    public var path: String        // 项目相对路径，如 Sources/Views/ContentView.swift
    public var contents: String
    public init(id: FileID, path: String, contents: String) { self.id = id; self.path = path; self.contents = contents }
}

/// 一次运行的完整输入。文件顺序不得影响结果：运行时先收集全部声明再解析引用。
public struct ProgramSource: Sendable, Hashable, Codable {
    public var moduleName: String
    public var files: [SourceFile]
    public init(moduleName: String, files: [SourceFile]) { self.moduleName = moduleName; self.files = files }
}

public enum EntryPoint: Sendable, Hashable, Codable {
    case script(FileID)                       // main.swift 顶层语句
    case rootView(symbol: String)             // manifest 指定的根 View 类型名
    case mainApp                              // 受限适配的 @main App + WindowGroup；解析出根 View 后交给宿主场景
}

public struct RunOptions: Sendable, Hashable, Codable {
    public var runtimeVersion: RuntimeVersion
    /// 候选运行（AI 验证）：只读/隔离数据副本，不触发外部副作用。
    public var isCandidate: Bool
    public var enableTracing: Bool
    public init(runtimeVersion: RuntimeVersion, isCandidate: Bool = false, enableTracing: Bool = false) {
        self.runtimeVersion = runtimeVersion; self.isCandidate = isCandidate; self.enableTracing = enableTracing
    }
}

public struct ValidationResult: Sendable, Hashable, Codable {
    public var diagnostics: [Diagnostic]
    public var entryPoints: [EntryPoint]
    /// 该程序引用到的能力目录条目（供权限预检、AI 上下文和文档使用）。
    public var referencedCapabilities: [String]
    public var isRunnable: Bool { !diagnostics.contains { $0.severity == .error } }
    public init(diagnostics: [Diagnostic], entryPoints: [EntryPoint], referencedCapabilities: [String]) {
        self.diagnostics = diagnostics; self.entryPoints = entryPoints; self.referencedCapabilities = referencedCapabilities
    }
}

/// 一个运行实例。stop() 是协作式取消：返回时所有计时器、任务、桥接句柄必须已失效，且 events 流已结束（finish）。
/// 终止约定（CR-1 / B-7）：所有运行都以 .finished(reason) 作为统一终止事件，并且在其之前发出对应的 stateChanged
/// （completed / stoppedByUser → .stopped；budgetExceeded → .interrupted；trap / internalError / validationFailed → .failed）。
/// 宿主仍以“事件流结束”作为兜底终止判定。
public protocol RunHandle: Sendable {
    var runID: RunID { get }
    var events: AsyncStream<RuntimeEventEnvelope> { get }
    func send(_ input: RuntimeInputEnvelope) async
    func stop() async
}

/// 解释器对外唯一入口。实现不得依赖 SwiftUI 页面代码。
public protocol RuntimeEngine: Sendable {
    var runtimeVersion: RuntimeVersion { get }
    func validate(_ program: ProgramSource) async -> ValidationResult
    func run(_ program: ProgramSource, entry: EntryPoint, budget: ExecutionBudget, options: RunOptions) async throws -> any RunHandle
}
