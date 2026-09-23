import Foundation

/// 源位置：行列为 1-based，utf8Offset 为文件内 UTF-8 偏移。编辑器负责换算为 UTF-16 范围。
public struct SourceLocation: Hashable, Sendable, Codable {
    public var fileID: FileID
    public var line: Int
    public var column: Int
    public var utf8Offset: Int
    public init(fileID: FileID, line: Int, column: Int, utf8Offset: Int) {
        self.fileID = fileID; self.line = line; self.column = column; self.utf8Offset = utf8Offset
    }
}

public struct SourceRange: Hashable, Sendable, Codable {
    public var start: SourceLocation
    public var end: SourceLocation
    public init(start: SourceLocation, end: SourceLocation) { self.start = start; self.end = end }
}

public enum DiagnosticSeverity: String, Sendable, Codable { case error, warning, note }

/// 诊断类别必须区分：解析错误 / 尚不支持的语法 / 能力不可用 / 权限拒绝 / 运行异常 / 预算超限 / AI 失败。
public enum DiagnosticKind: String, Sendable, Codable {
    case parse
    case unsupportedSyntax        // 合法 Swift，但运行时尚不支持（不是用户写错）
    case unsupportedAPI           // 合法调用，但桥接/能力目录未实现
    case nameResolution
    case typeCheck
    case runtimeTrap              // 溢出、除零、越界、强制解包 nil 等受控运行错误
    case budgetExceeded           // 步数/栈深/分配/时间预算
    case cancelled
    case capabilityUnavailable
    case permissionDenied
    case aiFailure
    case internalError
}

public struct Diagnostic: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var kind: DiagnosticKind
    public var severity: DiagnosticSeverity
    public var message: String
    public var range: SourceRange?
    public var suggestion: String?
    public var runID: RunID?
    /// 与 capability catalog 的条目 ID 关联（unsupportedSyntax / unsupportedAPI / capabilityUnavailable 必填）。
    public var capabilityID: String?
    public init(id: UUID = UUID(), kind: DiagnosticKind, severity: DiagnosticSeverity = .error, message: String,
                range: SourceRange? = nil, suggestion: String? = nil, runID: RunID? = nil, capabilityID: String? = nil) {
        self.id = id; self.kind = kind; self.severity = severity; self.message = message
        self.range = range; self.suggestion = suggestion; self.runID = runID; self.capabilityID = capabilityID
    }
}
