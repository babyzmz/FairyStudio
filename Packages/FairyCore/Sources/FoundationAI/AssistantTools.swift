import Foundation
import ProjectContracts
import RuntimeContracts

// 助手工具层：本项目自定义的纯 Swift struct，供 prompt 组装与假 driver 回放。
// 不冒充 Apple FoundationModels `Tool` 协议；不做真实挂接（见 AssistantProposal.swift 说明）。
// 所有工具只读输入方给定的快照/诊断/目录数据，不持有文件句柄，不做网络调用。

// MARK: - ListFilesTool

/// 快照文件列表：path + hash 前缀 + 行数（预算 L1 下只留签名：path + hash 前缀）。
public enum ListFilesTool {
    public static func output(for snapshot: ProjectSnapshot, signaturesOnly: Bool = false) -> String {
        snapshot.files.map { file in
            let hash = String(file.hash.rawValue.prefix(12))
            if signaturesOnly { return "- \(file.path) [\(hash)]" }
            let lines = file.contents.components(separatedBy: "\n").count
            return "- \(file.path) id=\(file.id) [\(hash)] \(lines)行"
        }.joined(separator: "\n")
    }
}

// MARK: - ReadFileTool

/// 按 path 或 fileID 读取，可选行范围（1-based 闭区间）；返回内容时附带 hash 供 expectedBaseHash。
public enum ReadFileTool {
    public struct ReadResult: Sendable, Hashable {
        public var file: ProjectFileSnapshot
        public var excerpt: String
        public init(file: ProjectFileSnapshot, excerpt: String) {
            self.file = file; self.excerpt = excerpt
        }
    }

    public static func read(_ snapshot: ProjectSnapshot, path: String? = nil,
                            fileID: FileID? = nil, range: ClosedRange<Int>? = nil) -> ReadResult? {
        let file: ProjectFileSnapshot?
        if let fileID { file = snapshot.file(id: fileID) }
        else if let path { file = snapshot.file(path: path) }
        else { file = nil }
        guard let file else { return nil }
        guard let range else { return ReadResult(file: file, excerpt: file.contents) }
        let lines = file.contents.components(separatedBy: "\n")
        let lo = max(range.lowerBound, 1), hi = min(range.upperBound, lines.count)
        guard lo <= hi else { return ReadResult(file: file, excerpt: "") }
        return ReadResult(file: file, excerpt: lines[(lo - 1)..<hi].joined(separator: "\n"))
    }
}

// MARK: - SearchSymbolsTool

/// 对快照源码做简易符号扫描：struct / func / var / enum 名（正则单行匹配，不做语义解析）。
public enum SearchSymbolsTool {
    public struct Hit: Sendable, Hashable {
        public var symbol: String
        public var kind: String
        public var path: String
        public var line: Int
        public init(symbol: String, kind: String, path: String, line: Int) {
            self.symbol = symbol; self.kind = kind; self.path = path; self.line = line
        }
    }

    static let pattern = #"(?:^|\s)(struct|func|var|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    public static func search(_ snapshot: ProjectSnapshot, query: String) -> [Hit] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let needle = query.lowercased()
        var hits: [Hit] = []
        for file in snapshot.files where file.isSwiftSource {
            let lines = file.contents.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let ns = line as NSString
                for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let kind = ns.substring(with: m.range(at: 1))
                    let name = ns.substring(with: m.range(at: 2))
                    if needle.isEmpty || name.lowercased().contains(needle) {
                        hits.append(Hit(symbol: name, kind: kind, path: file.path, line: index + 1))
                    }
                }
            }
        }
        return hits
    }

    public static func output(_ hits: [Hit], limit: Int = 40) -> String {
        hits.prefix(limit).map { "- \($0.kind) \($0.symbol)（\($0.path):\($0.line)）" }.joined(separator: "\n")
    }
}

// MARK: - ReadCapabilityTool

/// 从能力目录取子集摘要。目录条目由调用方（App 层经 `SwiftRuntimeEngine.catalog`）注入，
/// FoundationAI 不依赖 SwiftRuntime。
public enum ReadCapabilityTool {
    public static func summary(entries: [CapabilityEntry], topics: [String] = [], lineLimit: Int = 60) -> String {
        let filtered: [CapabilityEntry]
        if topics.isEmpty {
            filtered = entries
        } else {
            let needles = topics.map { $0.lowercased() }
            filtered = entries.filter { e in
                let hay = "\(e.id) \(e.displayName) \(e.category.rawValue)".lowercased()
                return needles.contains { hay.contains($0) }
            }
        }
        // supported / partial 在前，unsupported 兜底只列 id。
        let ordered = filtered.sorted {
            rank($0.level) < rank($1.level) || (rank($0.level) == rank($1.level) && $0.id < $1.id)
        }
        let lines = ordered.prefix(lineLimit).map { e -> String in
            var s = "- \(e.id)：\(e.displayName)（\(e.level.rawValue)）"
            if let sig = e.signature, e.level != .unsupported { s += " \(sig)" }
            if let notes = e.notes { s += "；\(notes)" }
            return s
        }
        return lines.joined(separator: "\n")
    }

    private static func rank(_ level: SupportLevel) -> Int {
        switch level {
        case .supported: 0
        case .partial: 1
        case .unsupported: 2
        }
    }
}

// MARK: - ReadDiagnosticsTool

/// 最近诊断 + 控制台尾部摘要（只读调用方传入的数据）。
public enum ReadDiagnosticsTool {
    public static func summary(diagnostics: [Diagnostic], consoleTail: [String] = [],
                               consoleLimit: Int = 20) -> String {
        var parts: [String] = []
        if diagnostics.isEmpty {
            parts.append("诊断：无")
        } else {
            let lines = diagnostics.map { d -> String in
                var s = "- [\(d.severity)] \(d.kind)：\(d.message)"
                if let r = d.range { s += "（\(r.start.fileID):\(r.start.line)）" }
                if let sug = d.suggestion { s += " 建议：\(sug)" }
                return s
            }
            parts.append("诊断：\n" + lines.joined(separator: "\n"))
        }
        if !consoleTail.isEmpty {
            parts.append("控制台尾部：\n" + consoleTail.suffix(consoleLimit).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - ProposeChangesTool

/// 解析模型输出的 FileChangeSet JSON：先找 ```json 代码块，找不到则整体按 JSON 解析。
/// 组装提交时 expectedBaseHash 由工具侧自动填入读取时的哈希（模型可省略）。
public enum ProposeChangesTool {
    /// 文本中不含 JSON 块（纯文本回答，不算解析失败）。
    public struct NoBlockFound: Error {}

    public static func parse(from text: String) throws -> ProposedChangeSet {
        if let block = extractJSONBlock(from: text) {
            return try decode(block)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return try decode(trimmed)
        }
        // ```json 围栏未闭合（输出被截断在闭合标记之前）：取首个围栏之后的内容兜底解析。
        if let start = text.range(of: "```json") {
            let body = String(text[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{") {
                return try decode(body)
            }
        }
        throw NoBlockFound()
    }

    public static func buildChangeSet(from proposed: ProposedChangeSet, base: ProjectSnapshot,
                                      backendName: String, summary: String) throws -> FileChangeSet {
        guard !proposed.operations.isEmpty else { throw AssistantProposalError.emptyOperations }
        var ops: [FileOperation] = []
        for op in proposed.operations {
            switch op.action.lowercased() {
            case "create":
                guard let path = op.path, !path.isEmpty else { throw AssistantProposalError.missingPath("create") }
                guard let contents = op.contents else { throw AssistantProposalError.missingContents(path) }
                ops.append(.create(path: path, contents: contents))
            case "replace":
                let file = try resolve(op, in: base)
                guard let contents = op.contents else { throw AssistantProposalError.missingContents(file.path) }
                ops.append(.replace(fileID: file.id, expectedBaseHash: hash(op.expectedBaseHash, or: file.hash), contents: contents))
            case "rename":
                let file = try resolve(op, in: base)
                guard let newPath = op.newPath, !newPath.isEmpty else { throw AssistantProposalError.missingNewPath(file.path) }
                ops.append(.rename(fileID: file.id, expectedBaseHash: hash(op.expectedBaseHash, or: file.hash), newPath: newPath))
            case "delete":
                let file = try resolve(op, in: base)
                ops.append(.delete(fileID: file.id, expectedBaseHash: hash(op.expectedBaseHash, or: file.hash)))
            case let other:
                throw AssistantProposalError.unknownAction(other)
            }
        }
        return FileChangeSet(baseRevision: base.revision, operations: ops, summary: summary,
                             origin: .ai(backend: backendName))
    }

    // MARK: - 内部

    static func extractJSONBlock(from text: String) -> String? {
        // ```json ... ``` 优先，其次通用 ``` ... ```（内容以 { 开头）。
        if let block = block(in: text, marker: "```json"), !block.isEmpty { return block }
        if let block = block(in: text, marker: "```"), block.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return block
        }
        return nil
    }

    private static func block(in text: String, marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```") else { return nil }
        return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ json: String) throws -> ProposedChangeSet {
        do {
            return try JSONDecoder().decode(ProposedChangeSet.self, from: Data(json.utf8))
        } catch {
            throw AssistantTurnError.parseFailed("变更 JSON 解析失败：\(error.localizedDescription)")
        }
    }

    private static func resolve(_ op: ProposedOperation, in base: ProjectSnapshot) throws -> ProjectFileSnapshot {
        if let id = op.fileID, !id.isEmpty, let f = base.file(id: FileID(id)) { return f }
        if let path = op.path, !path.isEmpty, let f = base.file(path: path) { return f }
        throw AssistantProposalError.unknownFile(op.fileID?.isEmpty == false ? op.fileID! : (op.path ?? "?"))
    }

    private static func hash(_ override: String?, or current: ContentHash) -> ContentHash {
        guard let override, !override.isEmpty else { return current }
        return ContentHash(rawValue: override)
    }
}

// MARK: - 错误签名（修复轮次的停止条件）

/// 错误签名 = error 级诊断的 kind + message 前 80 字符集合（排序拼接）。
/// 相同签名再次出现或无进展即停。
public enum AssistantRepair {
    public static func signature(of diagnostics: [Diagnostic]) -> String {
        let errors = diagnostics.filter { $0.severity == .error }
        if errors.isEmpty { return "no-errors" }
        return errors.map { "\($0.kind.rawValue):\($0.message.prefix(80))" }.sorted().joined(separator: "|")
    }
}

/// 修复计数器：最多 2 轮；相同错误签名或无进展即停。
public struct RepairTracker: Sendable {
    public static let maxRounds = 2
    public private(set) var usedRounds: Int
    public private(set) var lastSignature: String?

    public init(usedRounds: Int = 0, lastSignature: String? = nil) {
        self.usedRounds = usedRounds; self.lastSignature = lastSignature
    }

    /// 本轮是否允许继续修复（调用后计数；拒绝时不计数）。
    public mutating func shouldRepair(signature: String) -> Bool {
        guard usedRounds < Self.maxRounds, signature != lastSignature else { return false }
        lastSignature = signature
        usedRounds += 1
        return true
    }
}
