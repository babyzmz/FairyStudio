import Foundation
import CryptoKit
import RuntimeContracts

/// 项目身份。复制作品默认生成新 ProjectID。
public struct ProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// 项目修订号：每次成功提交的 FileChangeSet 使其单调递增。
public struct ProjectRevision: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (a: ProjectRevision, b: ProjectRevision) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "r\(rawValue)" }
    public func next() -> ProjectRevision { ProjectRevision(rawValue + 1) }
}

/// 文件内容哈希（SHA-256 十六进制）。AI 补丁必须带 expectedBaseHash，不匹配即拒绝。
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(of contents: String) {
        let digest = SHA256.hash(data: Data(contents.utf8))
        self.rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }
    public var description: String { String(rawValue.prefix(12)) }
}

public struct ProjectFileSnapshot: Hashable, Sendable, Codable, Identifiable {
    public var id: FileID
    public var path: String          // 项目相对路径，如 Sources/Views/ContentView.swift
    public var contents: String
    public var hash: ContentHash
    public init(id: FileID, path: String, contents: String) {
        self.id = id; self.path = path; self.contents = contents; self.hash = ContentHash(of: contents)
    }
    public var isSwiftSource: Bool { path.hasSuffix(".swift") && path.hasPrefix("Sources/") }
}

public enum ProjectEntryKind: String, Sendable, Codable { case nativeSwift, web }

/// 某一修订下的项目只读快照。UI、AI 与运行时都只消费快照，写入必须经 FileChangeSet。
public struct ProjectSnapshot: Sendable, Hashable, Codable {
    public var projectID: ProjectID
    public var revision: ProjectRevision
    public var displayName: String
    public var moduleName: String
    public var entryKind: ProjectEntryKind
    public var entry: EntryPoint
    public var files: [ProjectFileSnapshot]
    public var modifiedAt: Date
    public init(projectID: ProjectID, revision: ProjectRevision, displayName: String, moduleName: String,
                entryKind: ProjectEntryKind = .nativeSwift, entry: EntryPoint, files: [ProjectFileSnapshot], modifiedAt: Date = Date()) {
        self.projectID = projectID; self.revision = revision; self.displayName = displayName; self.moduleName = moduleName
        self.entryKind = entryKind; self.entry = entry; self.files = files; self.modifiedAt = modifiedAt
    }
    public func file(id: FileID) -> ProjectFileSnapshot? { files.first { $0.id == id } }
    public func file(path: String) -> ProjectFileSnapshot? { files.first { $0.path == path } }
    /// 交给 SwiftRuntime 的程序：只含 Sources/ 下的 .swift。
    public var program: ProgramSource {
        ProgramSource(moduleName: moduleName, files: files.filter(\.isSwiftSource).map { SourceFile(id: $0.id, path: $0.path, contents: $0.contents) })
    }
}

/// 文件级写操作。带 expectedBaseHash 的操作在哈希不匹配时整个 ChangeSet 被拒绝（原子）。
public enum FileOperation: Sendable, Hashable, Codable {
    case create(path: String, contents: String)
    case replace(fileID: FileID, expectedBaseHash: ContentHash, contents: String)
    case rename(fileID: FileID, expectedBaseHash: ContentHash, newPath: String)
    case delete(fileID: FileID, expectedBaseHash: ContentHash)
}

public enum ChangeOrigin: Sendable, Hashable, Codable {
    case user
    case ai(backend: String)     // "onDevice" / "privateCloudCompute"
    case template(String)
    case importer
}

/// 一次原子提交。changeSetID 幂等：同一 ID 重复提交返回 alreadyApplied。
public struct FileChangeSet: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var baseRevision: ProjectRevision
    public var operations: [FileOperation]
    public var summary: String
    public var origin: ChangeOrigin
    public init(id: UUID = UUID(), baseRevision: ProjectRevision, operations: [FileOperation], summary: String, origin: ChangeOrigin) {
        self.id = id; self.baseRevision = baseRevision; self.operations = operations; self.summary = summary; self.origin = origin
    }
}

public enum ChangeSetError: Error, Sendable, Hashable {
    case revisionMismatch(expected: ProjectRevision, actual: ProjectRevision)
    case hashMismatch(fileID: FileID, expected: ContentHash, actual: ContentHash)
    case fileNotFound(FileID)
    case pathConflict(String)
    case invalidPath(String)
    case limitExceeded(String)         // 文件数、单文件大小、总大小
    case alreadyApplied(UUID)
    case storage(String)
}

public struct ChangeSetResult: Sendable, Hashable, Codable {
    public var changeSetID: UUID
    public var revision: ProjectRevision
    public var createdFileIDs: [FileID]
    public var affectedFileIDs: [FileID]
    public init(changeSetID: UUID, revision: ProjectRevision, createdFileIDs: [FileID], affectedFileIDs: [FileID]) {
        self.changeSetID = changeSetID; self.revision = revision; self.createdFileIDs = createdFileIDs; self.affectedFileIDs = affectedFileIDs
    }
}

/// 工程保护上限（策略，不是性能保证）。超出时明确报错，不截断后继续。
public struct ProjectLimits: Sendable, Hashable, Codable {
    public var maxSourceFiles: Int
    public var maxFileBytes: Int
    public var maxTotalSourceBytes: Int
    public init(maxSourceFiles: Int = 50, maxFileBytes: Int = 256 << 10, maxTotalSourceBytes: Int = 1 << 20) {
        self.maxSourceFiles = maxSourceFiles; self.maxFileBytes = maxFileBytes; self.maxTotalSourceBytes = maxTotalSourceBytes
    }
    public static let `default` = ProjectLimits()
}

/// 单个项目的读写入口。ProjectCore 的 ProjectStore（actor）实现它；AI 层只通过它读快照、提交 ChangeSet，
/// 不持有文件句柄。模型只能"提出"变更，授权、校验与原子提交都在实现方。
public protocol ProjectAccess: Sendable {
    var projectID: ProjectID { get }
    func snapshot() async -> ProjectSnapshot
    func apply(_ changeSet: FileChangeSet) async throws -> ChangeSetResult
    /// 每次修订变化推送最新快照（含其他窗口/AI 的提交）。
    func snapshots() async -> AsyncStream<ProjectSnapshot>
}

/// 便捷：把一份快照与 ChangeSet 在内存中演算出候选快照（用于 diff 预览与候选校验，不落盘）。
public enum ChangeSetPreview {
    public static func apply(_ changeSet: FileChangeSet, to base: ProjectSnapshot, limits: ProjectLimits = .default) throws -> ProjectSnapshot {
        guard changeSet.baseRevision == base.revision else {
            throw ChangeSetError.revisionMismatch(expected: changeSet.baseRevision, actual: base.revision)
        }
        var files = base.files
        for op in changeSet.operations {
            switch op {
            case let .create(path, contents):
                try validatePath(path)
                if files.contains(where: { $0.path == path }) { throw ChangeSetError.pathConflict(path) }
                files.append(ProjectFileSnapshot(id: FileID(UUID().uuidString), path: path, contents: contents))
            case let .replace(fileID, expected, contents):
                let i = try index(of: fileID, in: files, expecting: expected)
                files[i] = ProjectFileSnapshot(id: fileID, path: files[i].path, contents: contents)
            case let .rename(fileID, expected, newPath):
                try validatePath(newPath)
                let i = try index(of: fileID, in: files, expecting: expected)
                if files.contains(where: { $0.path == newPath && $0.id != fileID }) { throw ChangeSetError.pathConflict(newPath) }
                files[i] = ProjectFileSnapshot(id: fileID, path: newPath, contents: files[i].contents)
            case let .delete(fileID, expected):
                let i = try index(of: fileID, in: files, expecting: expected)
                files.remove(at: i)
            }
        }
        let sources = files.filter(\.isSwiftSource)
        if sources.count > limits.maxSourceFiles { throw ChangeSetError.limitExceeded("源码文件数超过 \(limits.maxSourceFiles)") }
        if let big = files.first(where: { $0.contents.utf8.count > limits.maxFileBytes }) { throw ChangeSetError.limitExceeded("文件过大：\(big.path)") }
        if sources.reduce(0, { $0 + $1.contents.utf8.count }) > limits.maxTotalSourceBytes { throw ChangeSetError.limitExceeded("源码总量超过上限") }
        var next = base
        next.files = files
        next.revision = base.revision.next()
        next.modifiedAt = Date()
        return next
    }

    static func index(of fileID: FileID, in files: [ProjectFileSnapshot], expecting hash: ContentHash) throws -> Int {
        guard let i = files.firstIndex(where: { $0.id == fileID }) else { throw ChangeSetError.fileNotFound(fileID) }
        guard files[i].hash == hash else { throw ChangeSetError.hashMismatch(fileID: fileID, expected: hash, actual: files[i].hash) }
        return i
    }

    /// 只允许项目相对的规范路径：无 ..、无绝对路径、无空段、无控制字符。
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ChangeSetError.invalidPath(path)
        }
    }
}
