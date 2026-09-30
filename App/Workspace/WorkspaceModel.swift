import Foundation
import Observation
import SwiftUI
import UIKit
import RuntimeContracts
import ProjectContracts
import ProjectCore

/// 工作区状态（MainActor）：快照订阅、多标签草稿与光标、文件树操作、运行。
/// 所有写操作经 `FileChangeSet` 提交给 `ProjectStore`；读只消费快照。
@MainActor
@Observable
final class WorkspaceModel {
    let store: ProjectStore
    let library: ProjectLibrary
    let coordinator: RunCoordinator
    let initialPrompt: String

    var snapshot: ProjectSnapshot?
    var manifest: ProjectManifest?
    var loadError: String?
    var openedTabs: [FileID] = []
    var selectedTabID: FileID?
    /// 未保存草稿：tabID → 编辑内容（与快照不一致即脏）。
    var drafts: [FileID: String] = [:]
    private var draftBases: [FileID: ContentHash] = [:]
    private var editGenerations: [FileID: UInt64] = [:]
    /// 光标 offset：tabID → location（切换标签保留）。
    var cursors: [FileID: Int] = [:]
    /// 光标恢复令牌：切换标签时 +1，驱动 CodeTextView 恢复光标。
    var restoreTokens: [FileID: Int] = [:]
    /// UI 侧空目录（目录由文件路径隐含；新建空目录先记在这里，进文件即消失）。
    var knownEmptyDirs: Set<String> = []
    var errorMessage: String?
    /// 改名中的文件（alert 输入新路径）。
    var pendingRenameID: FileID?
    var renameText = ""
    /// iPhone 三段：作品 / 代码 / 助手。
    var compactPane: WorkspaceCompactPane = .artifact
    /// 主舞台分段：作品 / 代码（iPad 与宽窗口）。
    var mainView: WorkspaceMainView = .artifact
    var isFileDrawerPresented = false
    /// 左面板（会话历史 / 设置）可见性：iPad 双栏与 iPhone 以 sheet 呈现，iPad 三栏常驻。
    var isAssistantVisible = false
    /// 助手会话：左面板与中栏聊天共享同一实例。
    let assistant: AssistantSession

    private var subscribeTask: Task<Void, Never>?

    init(store: ProjectStore, library: ProjectLibrary, coordinator: RunCoordinator, initialPrompt: String = "") {
        self.store = store
        self.library = library
        self.coordinator = coordinator
        self.initialPrompt = initialPrompt
        self.assistant = AssistantSession(project: store, coordinator: coordinator, library: library,
                                          initialPrompt: initialPrompt,
                                          broker: .live(openRouterKeyStore: OpenRouterKeychain()),
                                          settings: .shared,
                                          agent: FoundationModelsAgentRunner())
    }

    /// 从诊断 / 变更卡定位到代码：打开文件并切到代码段。
    func locateInCode(fileID: FileID, line: Int) {
        open(fileID)
        mainView = .code
        compactPane = .code
    }

    func start() {
        subscribeTask?.cancel()
        subscribeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.store.snapshots()
            for await next in stream {
                self.applySnapshot(next)
                if Task.isCancelled { break }
            }
        }
        Task { await reload() }
    }

    func detach() { subscribeTask?.cancel(); subscribeTask = nil }

    /// 快照订阅之外的手动刷新（打开完成后 / 出错重试）。store 已打开，读不抛错。
    func reload() async {
        let next = await store.snapshot()
        manifest = await store.manifestSnapshot()
        applySnapshot(next)
    }

    private func applySnapshot(_ next: ProjectSnapshot) {
        snapshot = next
        // 消失的文件：清掉标签与草稿。
        let ids = Set(next.files.map(\.id))
        openedTabs.removeAll { !ids.contains($0) && drafts[$0] == nil }
        if drafts.keys.contains(where: { !ids.contains($0) }) {
            errorMessage = "有正在编辑的文件被删除；草稿已保留，请复制到新文件后保存。"
        }
        if let selected = selectedTabID, !ids.contains(selected), drafts[selected] == nil {
            selectedTabID = openedTabs.first
        }
        // 外部提交后：草稿基于旧哈希保存会失败；脏 tab 保留（用户显式保存时若哈希过期再提示）。
        knownEmptyDirs = knownEmptyDirs.filter { dir in
            !next.files.contains { $0.path == dir || $0.path.hasPrefix(dir + "/") }
        }
    }

    // MARK: - 标签与草稿

    func open(_ id: FileID) {
        assistant.selectedPath = snapshot?.file(id: id)?.path
        if !openedTabs.contains(id) { openedTabs.append(id) }
        if selectedTabID != id {
            selectedTabID = id
            restoreTokens[id, default: 0] += 1
        }
    }

    func close(_ id: FileID) {
        guard drafts[id] == nil else {
            errorMessage = "该文件有未保存修改，请保存后再关闭。"
            return
        }
        draftBases[id] = nil; editGenerations[id] = nil
        openedTabs.removeAll { $0 == id }
        drafts.removeValue(forKey: id)
        if selectedTabID == id { selectedTabID = openedTabs.last }
        assistant.selectedPath = selectedTabID.flatMap { snapshot?.file(id: $0)?.path }
    }

    func text(of id: FileID) -> String {
        if let draft = drafts[id] { return draft }
        return snapshot?.file(id: id)?.contents ?? ""
    }

    func setText(_ text: String, for id: FileID) {
        let base = snapshot?.file(id: id)?.contents ?? ""
        editGenerations[id, default: 0] += 1
        if text == base {
            drafts.removeValue(forKey: id); draftBases[id] = nil
        } else {
            if draftBases[id] == nil { draftBases[id] = snapshot?.file(id: id)?.hash }
            drafts[id] = text
        }
    }

    func isDirty(_ id: FileID) -> Bool { drafts[id] != nil }
    var hasDirtyTabs: Bool { !drafts.isEmpty }

    // MARK: - 提交

    @discardableResult
    func submit(_ operations: [FileOperation], summary: String) async -> Bool {
        guard let base = snapshot else { return false }
        let changeSet = FileChangeSet(baseRevision: base.revision, operations: operations,
                                      summary: summary, origin: .user)
        do {
            let result = try await store.apply(changeSet)
            await reload()
            // 新建文件直接打开。
            for id in result.createdFileIDs { open(id) }
            return true
        } catch {
            errorMessage = Self.describe(error)
            await reload()
            return false
        }
    }

    @discardableResult
    func save(_ id: FileID) async -> Bool {
        guard let draft = drafts[id], let file = snapshot?.file(id: id) else { return false }
        guard let baseHash = draftBases[id], baseHash == file.hash else {
            errorMessage = "文件已被助手或其他窗口修改。草稿已保留，请对照最新版本合并，不能直接覆盖。"
            return false
        }
        let generation = editGenerations[id]
        let ok = await submit([.replace(fileID: id, expectedBaseHash: baseHash, contents: draft)], summary: "保存 \(file.path)")
        if ok {
            if editGenerations[id] == generation { drafts[id] = nil; draftBases[id] = nil }
            else { draftBases[id] = ContentHash(of: draft) }
        }
        return ok
    }

    func saveAll() async {
        guard let snap = snapshot else { return }
        let submittedDrafts = drafts, submittedGenerations = editGenerations
        var ops: [FileOperation] = []
        for (id, draft) in submittedDrafts {
            guard let file = snap.file(id: id) else {
                errorMessage = "草稿对应的文件已被删除。请先另存恢复，保存全部不会丢弃草稿。"
                return
            }
            guard let hash = draftBases[id], hash == file.hash else {
                errorMessage = "存在版本冲突，草稿已保留，请先合并。"
                return
            }
            ops.append(.replace(fileID: id, expectedBaseHash: hash, contents: draft))
        }
        guard !ops.isEmpty else { return }
        if await submit(ops, summary: "保存全部（\(ops.count) 个文件）") {
            for (id, text) in submittedDrafts {
                if editGenerations[id] == submittedGenerations[id] { drafts[id] = nil; draftBases[id] = nil }
                else { draftBases[id] = ContentHash(of: text) }
            }
        }
    }

    // MARK: - 文件树操作

    func createFile(in dir: String, name: String? = nil) async {
        let cleanDir = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileName = name ?? Self.uniqueName(in: cleanDir, snapshot: snapshot)
        let path = cleanDir.isEmpty ? fileName : "\(cleanDir)/\(fileName)"
        let stub = fileName.hasSuffix(".swift") ? "// \(fileName)\n" : ""
        knownEmptyDirs.remove(cleanDir)
        await submit([.create(path: path, contents: stub)], summary: "新建 \(path)")
    }

    func createDirectory(_ dir: String) {
        let clean = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return }
        knownEmptyDirs.insert(clean)
    }

    func renameFile(_ id: FileID, to newPath: String) async {
        guard let file = snapshot?.file(id: id) else { return }
        let clean = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != file.path else { return }
        await submit([.rename(fileID: id, expectedBaseHash: file.hash, newPath: clean)], summary: "改名 \(file.path) → \(clean)")
    }

    func renameDirectory(from oldPrefix: String, to newPrefix: String) async {
        guard let snap = snapshot else { return }
        let olds = oldPrefix.hasSuffix("/") ? String(oldPrefix.dropLast()) : oldPrefix
        let news = newPrefix.hasSuffix("/") ? String(newPrefix.dropLast()) : newPrefix
        let ops: [FileOperation] = snap.files
            .filter { $0.path == olds || $0.path.hasPrefix(olds + "/") }
            .map { file in
                let suffix = String(file.path.dropFirst(olds.count))
                return FileOperation.rename(fileID: file.id, expectedBaseHash: file.hash, newPath: news + suffix)
            }
        guard !ops.isEmpty else { return }
        knownEmptyDirs.remove(olds)
        await submit(ops, summary: "目录改名 \(olds) → \(news)")
    }

    func deleteFile(_ id: FileID) async {
        guard let file = snapshot?.file(id: id) else { return }
        await submit([.delete(fileID: id, expectedBaseHash: file.hash)], summary: "删除 \(file.path)")
    }

    /// alert 确认后的改名提交。
    func commitPendingRename() async {
        guard let id = pendingRenameID else { return }
        pendingRenameID = nil
        await renameFile(id, to: renameText)
    }

    func deleteDirectory(_ prefix: String) async {
        guard let snap = snapshot else { return }
        let ops: [FileOperation] = snap.files
            .filter { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
            .map { .delete(fileID: $0.id, expectedBaseHash: $0.hash) }
        guard !ops.isEmpty else { knownEmptyDirs.remove(prefix); return }
        knownEmptyDirs.remove(prefix)
        await submit(ops, summary: "删除目录 \(prefix)")
    }

    func moveFile(_ id: FileID, toDir dir: String) async {
        guard let file = snapshot?.file(id: id) else { return }
        let clean = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = (file.path as NSString).lastPathComponent
        let newPath = clean.isEmpty ? base : "\(clean)/\(base)"
        await renameFile(id, to: newPath)
    }

    // MARK: - 运行

    func run() {
        guard !hasDirtyTabs else {
            errorMessage = "请先保存修改再运行；不会悄悄运行旧代码。"
            return
        }
        guard let snap = snapshot else { return }
        UIApplication.dismissKeyboard()
        coordinator.run(snap.program, entry: snap.entry, sourceRevision: snap.revision)
    }

    func stop() { coordinator.stop() }

    // MARK: - 诊断提示

    /// entryFile 被删：工作区内联提示（详细诊断在助手面板）。
    var entryFileHint: String? {
        guard let manifest, let entryFile = manifest.entryFile else { return nil }
        guard let snap = snapshot, snap.file(path: entryFile) == nil else { return nil }
        return "入口文件 \(entryFile) 已删除：恢复该文件或将其他文件改名为入口路径后才能运行脚本入口。"
    }

    // MARK: - 文件树

    struct DirTree: Sendable {
        var directories: [String] // 相对路径，排序
        var filesByDir: [String: [ProjectFileSnapshot]] // dir → 直属文件
    }

    var tree: DirTree {
        var dirs = Set(knownEmptyDirs)
        var filesByDir: [String: [ProjectFileSnapshot]] = [:]
        for file in snapshot?.files ?? [] {
            let dir = (file.path as NSString).deletingLastPathComponent
            filesByDir[dir, default: []].append(file)
            // 逐级补父目录。
            var parts = dir.split(separator: "/").map(String.init)
            while !parts.isEmpty {
                dirs.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        for dir in filesByDir.keys { dirs.insert(dir) }
        for (dir, files) in filesByDir {
            filesByDir[dir] = files.sorted { $0.path < $1.path }
        }
        return DirTree(directories: dirs.sorted(), filesByDir: filesByDir)
    }

    func displayName(of id: FileID) -> String {
        (snapshot?.file(id: id)?.path as NSString?)?.lastPathComponent ?? "未知文件"
    }

    // MARK: - 辅助

    static func uniqueName(in dir: String, snapshot: ProjectSnapshot?) -> String {
        var index = 0
        while true {
            index += 1
            let name = index == 1 ? "Untitled.swift" : "Untitled\(index).swift"
            let path = dir.isEmpty ? name : "\(dir)/\(name)"
            if snapshot?.file(path: path) == nil { return name }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? ChangeSetError {
            switch e {
            case let .revisionMismatch(expected, actual):
                return "版本冲突：基于 r\(expected.rawValue)，当前 r\(actual.rawValue)，已刷新到最新。"
            case .hashMismatch:
                return "文件已被其他窗口或助手修改：已刷新，请确认内容后重试。"
            case .fileNotFound:
                return "文件不存在：已刷新。"
            case let .pathConflict(path):
                return "路径冲突：\(path) 已存在。"
            case let .invalidPath(path):
                return "非法路径：\(path)。"
            case let .limitExceeded(detail):
                return "超过上限：\(detail)。"
            case .alreadyApplied:
                return "该提交已应用（幂等）。"
            case let .storage(detail):
                return "存储失败：\(detail)。"
            }
        } else if let e = error as? ProjectStore.OpenError {
            switch e {
            case .missingManifest:
                return "找不到 project.json。"
            case let .unreadableManifest(inner):
                return "清单损坏：\(inner)。"
            case let .unsupportedSchemaVersion(v):
                return "清单版本过高（schema \(v)），当前引擎无法打开。"
            case let .missingFile(path):
                return "文件缺失：\(path)。"
            }
        }
        return "\(error)"
    }
}

/// iPhone 分段切换：作品 / 代码 / 助手。
enum WorkspaceCompactPane: String, CaseIterable, Identifiable {
    case artifact = "作品"
    case code = "代码"
    case assistant = "助手"
    var id: String { rawValue }
}

/// 主舞台分段：作品 / 代码。
enum WorkspaceMainView: String, CaseIterable, Identifiable {
    case artifact = "作品"
    case code = "代码"
    var id: String { rawValue }
}

/// iPad 布局断点（纯函数，可测）：宽 regular + 足够宽度走三栏，否则双栏；compact 走单栏三段。
enum WorkspaceLayout {
    case triple
    case double
    case single

    static func mode(horizontalSizeClass: UserInterfaceSizeClass?, width: CGFloat) -> WorkspaceLayout {
        if horizontalSizeClass == .regular {
            return width >= 1024 ? .triple : .double
        }
        return .single
    }
}

private extension UIApplication {
    /// 运行时收起键盘：让出预览区（iPad 上编辑区与预览并排，键盘会遮住预览）。
    static func dismissKeyboard() {
        shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
