import Foundation
import RuntimeContracts
import ProjectContracts

/// 单个 `.mojoproject` 文档包的读写入口（actor，`ProjectAccess` 实现）。
/// - 打开：读 `project.json` + 文件内容建快照；manifest 高版本拒绝；
/// - 提交：revision 匹配 → `ChangeSetPreview.apply` 内存演算 → 原子写
///   （全新临时目录写所有文件 + manifest → `replaceItemAt` 整体替换）→ revision+1；
/// - 幂等：`appliedChangeSets` 保留最近 500 个 changeSetID；
/// - 写前把旧 manifest + 被覆盖文件内容记到 `snapshotsRoot/<projectID>/r<rev>/`；
/// - `fileID` 稳定：改名只改 manifest 路径；`entryFile` 改名同步跟随。
public actor ProjectStore: ProjectAccess {
    public nonisolated let projectID: ProjectID

    private let packageURL: URL
    private let snapshotsRoot: URL
    private let limits: ProjectLimits
    private var manifest: ProjectManifest
    private var current: ProjectSnapshot
    private var continuations: [UUID: AsyncStream<ProjectSnapshot>.Continuation] = [:]

    public enum OpenError: Error, Sendable {
        case missingManifest
        case unreadableManifest(any Error)
        case unsupportedSchemaVersion(Int)
        case missingFile(String)
    }

    /// 打开已存在的文档包（不存在或 manifest 非法即抛）。
    public init(packageURL: URL, snapshotsRoot: URL, limits: ProjectLimits = .default) async throws {
        self.packageURL = packageURL
        self.snapshotsRoot = snapshotsRoot
        self.limits = limits
        let manifestURL = packageURL.appendingPathComponent(ProjectLayout.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw OpenError.missingManifest }
        let manifest: ProjectManifest
        do {
            manifest = try ProjectManifest.decode(Data(contentsOf: manifestURL))
        } catch {
            throw OpenError.unreadableManifest(error)
        }
        guard manifest.schemaVersion <= ProjectManifest.currentSchemaVersion else {
            throw OpenError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.files.count <= limits.maxSourceFiles * 2 else { throw ChangeSetError.limitExceeded("项目文件数超限") }
        var fileIDs: Set<FileID> = [], paths: Set<String> = []
        var bytes = 0
        var files: [ProjectFileSnapshot] = []
        for record in manifest.files {
            try ChangeSetPreview.validateContentPath(record.path)
            guard fileIDs.insert(record.id).inserted, paths.insert(ChangeSetPreview.pathKey(record.path)).inserted else {
                throw ChangeSetError.pathConflict(record.path)
            }
            let url = packageURL.appendingPathComponent(record.path)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                throw OpenError.missingFile(record.path)
            }
            guard contents.utf8.count <= limits.maxFileBytes else { throw ChangeSetError.limitExceeded("单文件超限") }
            bytes += contents.utf8.count
            guard bytes <= limits.maxTotalSourceBytes * 2 else { throw ChangeSetError.limitExceeded("项目总量超限") }
            files.append(ProjectFileSnapshot(id: record.id, path: record.path, contents: contents))
        }
        self.manifest = manifest
        self.projectID = manifest.projectID
        self.current = ProjectSnapshot(projectID: manifest.projectID, revision: manifest.revision,
                                       displayName: manifest.displayName, moduleName: manifest.moduleName,
                                       entryKind: manifest.entryKind, entry: manifest.entryPoint,
                                       files: files, modifiedAt: manifest.modifiedAt)
    }

    /// 内部打开：Library 刚写好的包免一次磁盘重读（文件内容已在手）。
    init(packageURL: URL, snapshotsRoot: URL, limits: ProjectLimits, manifest: ProjectManifest, files: [ProjectFileSnapshot]) {
        self.packageURL = packageURL
        self.snapshotsRoot = snapshotsRoot
        self.limits = limits
        self.manifest = manifest
        self.projectID = manifest.projectID
        self.current = ProjectSnapshot(projectID: manifest.projectID, revision: manifest.revision,
                                       displayName: manifest.displayName, moduleName: manifest.moduleName,
                                       entryKind: manifest.entryKind, entry: manifest.entryPoint,
                                       files: files, modifiedAt: manifest.modifiedAt)
    }

    public func snapshot() async -> ProjectSnapshot { current }

    /// 当前清单副本（工作区显示入口说明、兼容性、entryFile 诊断用）。
    public func manifestSnapshot() async -> ProjectManifest { manifest }

    public func snapshots() async -> AsyncStream<ProjectSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ProjectSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropContinuation(id) }
        }
        continuation.yield(current)
        return stream
    }

    private func dropContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)?.finish()
    }

    public func apply(_ changeSet: FileChangeSet) async throws -> ChangeSetResult {
        // Cancellation is observed in the actor before the synchronous commit section begins.
        try Task.checkCancellation()
        if manifest.appliedChangeSets.contains(changeSet.id) { throw ChangeSetError.alreadyApplied(changeSet.id) }
        // 内存演算：revision / 哈希 / 路径 / 上限一次验清，失败则不碰磁盘。
        var next = try ChangeSetPreview.apply(changeSet, to: current, limits: limits)
        // 新建操作的 fileID：按路径在演算结果中找回（路径唯一已由演算保证）。
        var created: [FileID] = []
        for op in changeSet.operations {
            if case let .create(path, _) = op, let f = next.files.first(where: { $0.path == path }) {
                created.append(f.id)
            }
        }
        var newManifest = manifest
        newManifest.files = next.files.map { ProjectManifest.FileRecord(id: $0.id, path: $0.path) }
        newManifest.revision = next.revision
        newManifest.modifiedAt = next.modifiedAt
        // entryFile 改名同步：同 fileID 的新路径。
        if let oldEntry = manifest.entryFile,
           let record = manifest.files.first(where: { $0.path == oldEntry }),
           let renamed = next.files.first(where: { $0.id == record.id })?.path {
            newManifest.entryFile = renamed
        }
        newManifest.appliedChangeSets.append(changeSet.id)
        if newManifest.appliedChangeSets.count > ProjectManifest.appliedChangeSetLimit {
            newManifest.appliedChangeSets.removeFirst(newManifest.appliedChangeSets.count - ProjectManifest.appliedChangeSetLimit)
        }
        next.entry = newManifest.entryPoint
        try Task.checkCancellation()
        try Self.writeRollbackRecord(snapshotsRoot: snapshotsRoot, manifest: manifest, base: current, next: next)
        try Task.checkCancellation()
        try Self.atomicWrite(packageURL: packageURL, manifest: newManifest, files: next.files)
        manifest = newManifest
        current = next
        for continuation in continuations.values { continuation.yield(next) }
        let affected = Set(changeSet.operations.map(\.fileIDHint) + created).compactMap { $0 }
        return ChangeSetResult(changeSetID: changeSet.id, revision: next.revision,
                               createdFileIDs: created, affectedFileIDs: Array(affected))
    }

    // MARK: - 磁盘

    /// 原子写：全新临时目录写所有文件 + manifest，同卷 `replaceItemAt` 整体替换。
    static func atomicWrite(packageURL: URL, manifest: ProjectManifest, files: [ProjectFileSnapshot]) throws {
        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for root in ProjectLayout.contentRoots {
                try fm.createDirectory(at: staging.appendingPathComponent(root, isDirectory: true), withIntermediateDirectories: true)
            }
            try manifest.encoded().write(to: staging.appendingPathComponent(ProjectLayout.manifestFileName),
                                         options: .atomic)
            var paths: Set<String> = [], ids: Set<FileID> = []
            for file in files {
                try ChangeSetPreview.validateContentPath(file.path)
                guard paths.insert(ChangeSetPreview.pathKey(file.path)).inserted, ids.insert(file.id).inserted else {
                    throw ChangeSetError.pathConflict(file.path)
                }
                let url = staging.appendingPathComponent(file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            }
            // 同卷替换：包存在则整体替换，否则直接移入。
            if fm.fileExists(atPath: packageURL.path) {
                var resulting: NSURL?
                try fm.replaceItem(at: packageURL, withItemAt: staging, backupItemName: nil,
                                   options: [], resultingItemURL: &resulting)
            } else {
                try fm.moveItem(at: staging, to: packageURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw ChangeSetError.storage("\(error)")
        }
    }

    /// 最小回滚记录：旧 manifest + 本次被覆盖/改名/删除文件的旧内容。
    static func writeRollbackRecord(snapshotsRoot: URL, manifest: ProjectManifest,
                                    base: ProjectSnapshot, next: ProjectSnapshot) throws {
        let fm = FileManager.default
        let dir = snapshotsRoot.appendingPathComponent(manifest.projectID.description, isDirectory: true)
            .appendingPathComponent("r\(manifest.revision.rawValue)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest.encoded().write(to: dir.appendingPathComponent(ProjectLayout.manifestFileName), options: .atomic)
            let nextByID = Dictionary(uniqueKeysWithValues: next.files.map { ($0.id, $0) })
            for old in base.files {
                // 新快照中同 ID 缺失或内容/路径变化 → 旧内容值得保留。
                if let n = nextByID[old.id], n.contents == old.contents { continue }
                let url = dir.appendingPathComponent(old.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try old.contents.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            throw ChangeSetError.storage("回滚记录写入失败：\(error)")
        }
    }
}

private extension FileOperation {
    /// 操作涉及的已有 fileID（create 无）。
    var fileIDHint: FileID? {
        switch self {
        case .create: nil
        case let .replace(id, _, _): id
        case let .rename(id, _, _): id
        case let .delete(id, _): id
        }
    }
}

/// One in-process writer per canonical document URL. Pending opens are also shared.
actor ProjectStoreRegistry {
    static let shared = ProjectStoreRegistry()
    private final class WeakStore: @unchecked Sendable {
        weak var value: ProjectStore?
        init(_ value: ProjectStore) { self.value = value }
    }
    private var stores: [String: WeakStore] = [:]
    private var pending: [String: Task<ProjectStore, any Error>] = [:]

    func open(packageURL: URL, snapshotsRoot: URL, limits: ProjectLimits) async throws -> ProjectStore {
        let key = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        if let store = stores[key]?.value { return store }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await ProjectStore(packageURL: packageURL, snapshotsRoot: snapshotsRoot, limits: limits) }
        pending[key] = task
        do {
            let store = try await task.value
            stores[key] = WeakStore(store); pending[key] = nil
            return store
        } catch { pending[key] = nil; throw error }
    }
}
