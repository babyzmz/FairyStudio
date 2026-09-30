import SwiftUI
import RuntimeContracts
import ProjectContracts
import ProjectCore

/// 文件树：文件 + 目录的新建 / 改名 / 删除、文件拖放到目录。所有操作经 FileChangeSet 提交。
struct FileTreeView: View {
    @Bindable var model: WorkspaceModel
    @State private var collapsed: Set<String> = []
    @State private var renamingFile: FileID?
    @State private var renamingText = ""
    @State private var renamingDir: String?
    @State private var renamingDirText = ""
    @State private var newFileDir: String?
    @State private var newFileText = ""
    @State private var newDirParent: String?
    @State private var newDirText = ""

    var body: some View {
        List {
            DirectoryRow(dir: "", model: model, collapsed: $collapsed,
                         renamingFile: $renamingFile, renamingText: $renamingText,
                         renamingDir: $renamingDir, renamingDirText: $renamingDirText,
                         newFileDir: $newFileDir, newFileText: $newFileText,
                         newDirParent: $newDirParent, newDirText: $newDirText,
                         isRoot: true)
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("workspace.fileTree")
    }
}

private struct DirectoryRow: View {
    let dir: String
    @Bindable var model: WorkspaceModel
    @Binding var collapsed: Set<String>
    @Binding var renamingFile: FileID?
    @Binding var renamingText: String
    @Binding var renamingDir: String?
    @Binding var renamingDirText: String
    @Binding var newFileDir: String?
    @Binding var newFileText: String
    @Binding var newDirParent: String?
    @Binding var newDirText: String
    var isRoot = false

    private var tree: WorkspaceModel.DirTree { model.tree }
    private var subdirs: [String] {
        tree.directories.filter { Self.parent(of: $0) == dir }
    }
    private var files: [ProjectFileSnapshot] { tree.filesByDir[dir] ?? [] }
    private var isExpanded: Bool { isRoot || !collapsed.contains(dir) }

    var body: some View {
        if !isRoot {
            dirHeader
        }
        if isExpanded {
            ForEach(subdirs, id: \.self) { sub in
                DirectoryRow(dir: sub, model: model, collapsed: $collapsed,
                             renamingFile: $renamingFile, renamingText: $renamingText,
                             renamingDir: $renamingDir, renamingDirText: $renamingDirText,
                             newFileDir: $newFileDir, newFileText: $newFileText,
                             newDirParent: $newDirParent, newDirText: $newDirText)
            }
            ForEach(files) { file in
                fileRow(file)
            }
            if newFileDir == dir {
                newFileField
            }
            if newDirParent == dir {
                newDirField
            }
        }
    }

    // MARK: - 目录头

    private var dirHeader: some View {
        Group {
            if renamingDir == dir {
                TextField("目录名", text: $renamingDirText)
                    .textInputAutocapitalization(.never)
                    .onSubmit { commitDirRename() }
            } else {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(dirName)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if collapsed.contains(dir) { collapsed.remove(dir) } else { collapsed.insert(dir) }
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first else { return false }
            let id = FileID(raw)
            Task { await model.moveFile(id, toDir: dir) }
            return true
        }
        .contextMenu {
            Button("新建文件") { newFileDir = dir; newFileText = "" }
            Button("新建子目录") { newDirParent = dir; newDirText = "" }
            Button("改名") { renamingDir = dir; renamingDirText = dirName }
            Button("删除", role: .destructive) {
                Task { await model.deleteDirectory(dir) }
            }
        }
        .accessibilityIdentifier("workspace.dir.\(dir)")
    }

    private var dirName: String { (dir as NSString).lastPathComponent }

    private func commitDirRename() {
        let parent = Self.parent(of: dir)
        let clean = renamingDirText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingDir = nil
        guard !clean.isEmpty, clean != dirName else { return }
        let target = parent.isEmpty ? clean : "\(parent)/\(clean)"
        Task { await model.renameDirectory(from: dir, to: target) }
    }

    // MARK: - 文件行

    private func fileRow(_ file: ProjectFileSnapshot) -> some View {
        Group {
            if renamingFile == file.id {
                TextField("文件名（含路径）", text: $renamingText)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("workspace.inlineRenameField")
                    .onSubmit {
                        let target = renamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                        renamingFile = nil
                        Task { await model.renameFile(file.id, to: target) }
                    }
            } else {
                Button {
                    model.open(file.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: file.path.hasSuffix(".swift") ? "swift" : "doc")
                            .foregroundStyle(.secondary)
                        Text((file.path as NSString).lastPathComponent)
                        if model.isDirty(file.id) {
                            Text("•").foregroundStyle(.orange).accessibilityLabel("未保存")
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.selectedTabID == file.id ? Color.accentColor.opacity(0.15) : Color.clear)
                .accessibilityIdentifier("workspace.openFile.\(file.path)")
            }
        }
        .draggable(file.id.rawValue)
        .contextMenu {
            Button("打开") { model.open(file.id) }
            Button("改名") { renamingFile = file.id; renamingText = file.path }
            Button("删除", role: .destructive) {
                Task { await model.deleteFile(file.id) }
            }
        }
    }

    // MARK: - 新建行

    private var newFileField: some View {
        TextField("文件名", text: $newFileText)
            .textInputAutocapitalization(.never)
            .onSubmit {
                let name = newFileText.trimmingCharacters(in: .whitespacesAndNewlines)
                newFileDir = nil
                Task { await model.createFile(in: dir, name: name.isEmpty ? nil : name) }
            }
            .accessibilityIdentifier("workspace.newFileField")
    }

    private var newDirField: some View {
        TextField("子目录名", text: $newDirText)
            .textInputAutocapitalization(.never)
            .onSubmit {
                let name = newDirText.trimmingCharacters(in: .whitespacesAndNewlines)
                newDirParent = nil
                guard !name.isEmpty else { return }
                model.createDirectory(dir.isEmpty ? name : "\(dir)/\(name)")
            }
    }

    static func parent(of dir: String) -> String {
        let parent = (dir as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}
