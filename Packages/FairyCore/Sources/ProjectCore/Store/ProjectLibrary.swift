import Foundation
import RuntimeContracts
import ProjectContracts

/// 作品库：`Documents/Projects` 下枚举 `.mojoproject` 文档包。
/// 所有写操作同步落盘（文件小，主线程 `.task` 中调用即可）。
public struct ProjectLibrary: Sendable {
    /// 作品摘要（列表卡片用）。
    public struct Summary: Sendable, Hashable {
        public var projectID: ProjectID
        public var displayName: String
        public var modifiedAt: Date
        public var runtimeVersion: String
        public var entryDescription: String
        public var sourceFileCount: Int
        public init(projectID: ProjectID, displayName: String, modifiedAt: Date, runtimeVersion: String,
                    entryDescription: String, sourceFileCount: Int) {
            self.projectID = projectID; self.displayName = displayName; self.modifiedAt = modifiedAt
            self.runtimeVersion = runtimeVersion; self.entryDescription = entryDescription
            self.sourceFileCount = sourceFileCount
        }
    }

    /// 从模板创建时传入的模板内容（App 侧 `ProjectTemplate` 映射而来）。
    public struct TemplateFiles: Sendable, Hashable {
        public var templateID: String
        public var entrySymbol: String?
        public var files: [(path: String, contents: String)]
        public init(templateID: String, entrySymbol: String?, files: [(path: String, contents: String)]) {
            self.templateID = templateID; self.entrySymbol = entrySymbol; self.files = files
        }
        public static func == (a: Self, b: Self) -> Bool {
            a.templateID == b.templateID && a.entrySymbol == b.entrySymbol
                && a.files.map(\.path) == b.files.map(\.path) && a.files.map(\.contents) == b.files.map(\.contents)
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(templateID); hasher.combine(entrySymbol)
            for f in files { hasher.combine(f.path); hasher.combine(f.contents) }
        }
    }

    public enum LibraryError: Error, Sendable {
        case notFound
        case unreadableManifest(String)
        case invalidImport(String)
        case storage(String)
    }

    /// ZIP 导入限制（由 `ProjectLimits.default` 派生：源码上限管 Sources，其余目录留配额）。
    public struct ZipImportLimits: Sendable {
        public var maxFiles: Int
        public var maxFileBytes: Int
        public var maxTotalBytes: Int
        public static func derived(from limits: ProjectLimits) -> ZipImportLimits {
            ZipImportLimits(maxFiles: limits.maxSourceFiles * 2,
                            maxFileBytes: limits.maxFileBytes,
                            maxTotalBytes: limits.maxTotalSourceBytes * 2)
        }
    }

    public let documentsURL: URL
    public let currentRuntimeVersion: String
    public let limits: ProjectLimits

    public init(documentsURL: URL, currentRuntimeVersion: String, limits: ProjectLimits = .default) {
        self.documentsURL = documentsURL
        self.currentRuntimeVersion = currentRuntimeVersion
        self.limits = limits
    }

    public var projectsURL: URL { documentsURL.appendingPathComponent("Projects", isDirectory: true) }
    public var snapshotsRoot: URL { documentsURL.appendingPathComponent(".snapshots", isDirectory: true) }
    public func dataDir(for id: ProjectID) -> URL {
        documentsURL.appendingPathComponent("Data", isDirectory: true).appendingPathComponent(id.description, isDirectory: true)
    }
    public func storeURL(for id: ProjectID) -> URL {
        projectsURL.appendingPathComponent("\(id.description).\(ProjectLayout.packageExtension)")
    }

    // MARK: - 枚举与打开

    /// 按 modifiedAt 倒序列举作品（manifest 损坏的包跳过，不挡列表）。
    public func list() -> [Summary] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil) else { return [] }
        var out: [Summary] = []
        for url in items where url.pathExtension == ProjectLayout.packageExtension {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(ProjectLayout.manifestFileName)),
                  let manifest = try? ProjectManifest.decode(data),
                  manifest.schemaVersion <= ProjectManifest.currentSchemaVersion else { continue }
            out.append(Summary(projectID: manifest.projectID, displayName: manifest.displayName,
                               modifiedAt: manifest.modifiedAt, runtimeVersion: manifest.runtimeVersion,
                               entryDescription: manifest.entryDescription,
                               sourceFileCount: manifest.files.filter { $0.path.hasPrefix(ProjectLayout.sources + "/") }.count))
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func openStore(_ id: ProjectID) async throws -> ProjectStore {
        try await ProjectStore(packageURL: storeURL(for: id), snapshotsRoot: snapshotsRoot, limits: limits)
    }

    // MARK: - 新建 / 模板 / 复制 / 删除 / 重命名

    @discardableResult
    public func createBlank(displayName: String) throws -> ProjectID {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = [(path: "\(ProjectLayout.sources)/ContentView.swift", contents: blankContent(name: name.isEmpty ? "未命名作品" : name))]
        return try writeNewProject(displayName: name.isEmpty ? "未命名作品" : name, entrySymbol: "ContentView",
                                   templateID: nil, files: files)
    }

    @discardableResult
    public func createFromTemplate(_ template: TemplateFiles, displayName: String? = nil) throws -> ProjectID {
        for file in template.files { try ChangeSetPreview.validatePath(file.path) }
        return try writeNewProject(displayName: displayName ?? template.templateID, entrySymbol: template.entrySymbol,
                                   templateID: template.templateID, files: template.files)
    }

    /// 复制：新 projectID + 显示名 + " 副本"；修订与幂等记录清零（新作品独立演进）。
    @discardableResult
    public func duplicate(_ id: ProjectID) throws -> ProjectID {
        let (manifest, files) = try readPackage(id)
        let newID = ProjectID()
        var newManifest = manifest
        newManifest.projectID = newID
        newManifest.displayName = manifest.displayName + " 副本"
        newManifest.moduleName = ModuleNaming.moduleName(for: newManifest.displayName)
        newManifest.createdAt = Date(); newManifest.modifiedAt = Date()
        newManifest.revision = ProjectRevision(0)
        newManifest.appliedChangeSets = []
        try ProjectStore.atomicWrite(packageURL: storeURL(for: newID), manifest: newManifest, files: files)
        return newID
    }

    /// 删除：连同 `.snapshots/<projectID>` 回滚记录与 `Data/<projectID>` 数据目录一起移除。
    public func delete(_ id: ProjectID) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: storeURL(for: id))
        try? fm.removeItem(at: snapshotsRoot.appendingPathComponent(id.description))
        try? fm.removeItem(at: dataDir(for: id))
    }

    public func rename(_ id: ProjectID, displayName: String) throws {
        let (manifest, _) = try readPackage(id)
        var updated = manifest
        updated.displayName = displayName
        updated.modifiedAt = Date()
        try updated.encoded().write(to: storeURL(for: id).appendingPathComponent(ProjectLayout.manifestFileName), options: .atomic)
    }

    // MARK: - 导入单个 .swift（复制进托管包，不碰原文件）

    @discardableResult
    public func importSwiftFile(displayName: String, sourceURL: URL) throws -> ProjectID {
        guard sourceURL.pathExtension.lowercased() == "swift" else {
            throw LibraryError.invalidImport("只接受 .swift 文件")
        }
        let contents: String
        do { contents = try String(contentsOf: sourceURL, encoding: .utf8) }
        catch { throw LibraryError.invalidImport("源文件不可读：\(error)") }
        guard contents.utf8.count <= limits.maxFileBytes else {
            throw LibraryError.invalidImport("文件超过单文件上限")
        }
        let fileName = sanitizeFileName(sourceURL.lastPathComponent)
        // 入口：首个 `struct X: View`，找不到则 ContentView（用户可在工作区改）。
        let entry = firstRootView(in: contents) ?? "ContentView"
        return try writeNewProject(displayName: displayName, entrySymbol: entry, templateID: nil,
                                   files: [(path: "\(ProjectLayout.sources)/\(fileName)", contents: contents)])
    }

    // MARK: - 导入 / 导出 ZIP

    /// 导入 ZIP：拒绝路径穿越 / 绝对路径 / 符号链接 / 大小写冲突，限制文件数 / 单文件 / 总量。
    /// 含 `project.json` 则按项目包导入（换新 projectID 防碰撞）；缺失则按“裸源码包”导入。
    @discardableResult
    public func importZIP(_ data: Data, displayName: String? = nil) throws -> ProjectID {
        let entries: [ZipArchive.Entry]
        do { entries = try ZipArchive.decode(data) }
        catch { throw LibraryError.invalidImport("ZIP 无法解析：\(error)") }
        let files = entries.filter { !$0.isDirectory }
        for entry in files {
            if entry.isSymlink { throw LibraryError.invalidImport("拒绝符号链接：\(entry.name)") }
            do { try ChangeSetPreview.validatePath(entry.name) }
            catch { throw LibraryError.invalidImport("拒绝非法路径：\(entry.name)") }
        }
        // 大小写冲突（大小写不敏感文件系统上会互相覆盖）。
        var lowered: Set<String> = []
        for entry in files {
            let key = entry.name.lowercased()
            if !lowered.insert(key).inserted { throw LibraryError.invalidImport("大小写冲突：\(entry.name)") }
        }
        let bounds = ZipImportLimits.derived(from: limits)
        guard files.count <= bounds.maxFiles else { throw LibraryError.invalidImport("文件数超过 \(bounds.maxFiles)") }
        var total = 0
        for entry in files {
            guard entry.data.count <= bounds.maxFileBytes else { throw LibraryError.invalidImport("单文件过大：\(entry.name)") }
            total += entry.data.count
        }
        guard total <= bounds.maxTotalBytes else { throw LibraryError.invalidImport("总量超过上限") }

        if let manifestEntry = files.first(where: { $0.name == ProjectLayout.manifestFileName }),
           let manifest = try? ProjectManifest.decode(manifestEntry.data) {
            guard manifest.schemaVersion <= ProjectManifest.currentSchemaVersion else {
                throw LibraryError.invalidImport("manifest 版本过高（schema \(manifest.schemaVersion)）")
            }
            // 项目包导入：UTF-8 文本文件落盘；换新 projectID。
            let newID = ProjectID()
            var newManifest = manifest
            newManifest.projectID = newID
            if let displayName { newManifest.displayName = displayName }
            newManifest.moduleName = ModuleNaming.moduleName(for: newManifest.displayName)
            newManifest.revision = ProjectRevision(0)
            newManifest.appliedChangeSets = []
            newManifest.modifiedAt = Date()
            var snapshots: [ProjectFileSnapshot] = []
            for record in manifest.files {
                guard let match = files.first(where: { $0.name == record.path }),
                      let contents = String(data: match.data, encoding: .utf8) else {
                    throw LibraryError.invalidImport("清单列出的文件缺失或非 UTF-8：\(record.path)")
                }
                snapshots.append(ProjectFileSnapshot(id: record.id, path: record.path, contents: contents))
            }
            newManifest.files = snapshots.map { ProjectManifest.FileRecord(id: $0.id, path: $0.path) }
            try ProjectStore.atomicWrite(packageURL: storeURL(for: newID), manifest: newManifest, files: snapshots)
            return newID
        }
        // 裸源码包：.swift 收进 Sources/，其余文本文件原样保留相对路径。
        var collected: [(path: String, contents: String)] = []
        for entry in files {
            guard let contents = String(data: entry.data, encoding: .utf8) else { continue }
            if entry.name.hasSuffix(".swift") {
                let base = (entry.name as NSString).lastPathComponent
                collected.append((path: "\(ProjectLayout.sources)/\(sanitizeFileName(base))", contents: contents))
            } else {
                collected.append((path: entry.name, contents: contents))
            }
        }
        guard collected.contains(where: { $0.path.hasSuffix(".swift") }) else {
            throw LibraryError.invalidImport("包内没有 .swift 文件")
        }
        let entry = collected.lazy.compactMap { firstRootView(in: $0.contents) }.first ?? "ContentView"
        return try writeNewProject(displayName: displayName ?? "导入的作品", entrySymbol: entry,
                                   templateID: nil, files: collected)
    }

    public func exportZIP(_ id: ProjectID) throws -> Data {
        let (manifest, files) = try readPackage(id)
        var entries = [ZipArchive.Entry(name: ProjectLayout.manifestFileName, data: try manifest.encoded())]
        for file in files {
            entries.append(ZipArchive.Entry(name: file.path, data: Data(file.contents.utf8)))
        }
        return ZipArchive.encode(entries)
    }

    // MARK: - 内部

    private func readPackage(_ id: ProjectID) throws -> (ProjectManifest, [ProjectFileSnapshot]) {
        let packageURL = storeURL(for: id)
        guard let data = try? Data(contentsOf: packageURL.appendingPathComponent(ProjectLayout.manifestFileName)),
              let manifest = try? ProjectManifest.decode(data) else {
            throw LibraryError.unreadableManifest(id.description)
        }
        var files: [ProjectFileSnapshot] = []
        for record in manifest.files {
            guard let contents = try? String(contentsOf: packageURL.appendingPathComponent(record.path), encoding: .utf8) else {
                throw LibraryError.unreadableManifest("文件缺失：\(record.path)")
            }
            files.append(ProjectFileSnapshot(id: record.id, path: record.path, contents: contents))
        }
        return (manifest, files)
    }

    private func writeNewProject(displayName: String, entrySymbol: String?, templateID: String?,
                                 files: [(path: String, contents: String)]) throws -> ProjectID {
        let fm = FileManager.default
        try fm.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        let id = ProjectID()
        var snapshots: [ProjectFileSnapshot] = []
        var total = 0
        for file in files {
            try ChangeSetPreview.validatePath(file.path)
            guard file.contents.utf8.count <= limits.maxFileBytes else {
                throw LibraryError.invalidImport("文件过大：\(file.path)")
            }
            total += file.contents.utf8.count
            snapshots.append(ProjectFileSnapshot(id: FileID(UUID().uuidString), path: file.path, contents: file.contents))
        }
        guard snapshots.count <= limits.maxSourceFiles else {
            throw LibraryError.invalidImport("文件数超过 \(limits.maxSourceFiles)")
        }
        guard total <= limits.maxTotalSourceBytes else {
            throw LibraryError.invalidImport("总量超过上限")
        }
        let manifest = ProjectManifest(projectID: id, displayName: displayName, runtimeVersion: currentRuntimeVersion,
                                       moduleName: ModuleNaming.moduleName(for: displayName),
                                       entrySymbol: entrySymbol, templateID: templateID,
                                       files: snapshots.map { ProjectManifest.FileRecord(id: $0.id, path: $0.path) })
        do {
            try ProjectStore.atomicWrite(packageURL: storeURL(for: id), manifest: manifest, files: snapshots)
        } catch {
            throw LibraryError.storage("\(error)")
        }
        return id
    }

    private func blankContent(name: String) -> String {
        "import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        VStack(spacing: 12) {\n            Text(\"\(name)\")\n                .font(.title)\n            Text(\"Hello, FairyStudio!\")\n        }\n        .padding()\n    }\n}\n"
    }

    private func sanitizeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return base.isEmpty ? "Imported.swift" : base
    }

    /// 首个 `struct X: View` 类型名（导入包的入口推断）。
    func firstRootView(in contents: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*View"#) else { return nil }
        let range = NSRange(contents.startIndex..., in: contents)
        guard let match = regex.firstMatch(in: contents, range: range),
              let nameRange = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[nameRange])
    }
}
