import SwiftUI
import UniformTypeIdentifiers
import RuntimeContracts
import ProjectContracts
import ProjectCore
import SwiftRuntime

/// 打开中的作品（导航用）。
struct OpenedProject: Hashable {
    var id: ProjectID
    var initialPrompt: String
}

/// 首页「我的作品」：最近项目（modifiedAt 倒序）、模板入口、新建（描述需求 / 空白 / 导入）。
struct LibraryView: View {
    let library: ProjectLibrary
    @State private var path: [OpenedProject] = []
    @State private var summaries: [ProjectLibrary.Summary] = []
    @State private var templates: [ProjectTemplate] = []
    @State private var errorMessage: String?
    @State private var isNewSheetPresented = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var newTemplateID = "blank"
    @State private var isSwiftImporterPresented = false
    @State private var isZipImporterPresented = false
    @State private var renaming: ProjectLibrary.Summary?
    @State private var renamingText = ""
    @State private var deleting: ProjectLibrary.Summary?
    @State private var shareURL: ShareableURL?
    @Environment(\.colorScheme) private var colorScheme


    // MARK: - 首页分区（拆分计算属性以控制类型推断复杂度）

    private var newSection: some View {
        Section {
            Button {
                newName = ""; newDescription = ""; newTemplateID = "blank"
                isNewSheetPresented = true
            } label: {
                Label("新作品", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("library.new")
            Menu {
                Button {
                    isSwiftImporterPresented = true
                } label: {
                    Label("Swift 文件", systemImage: "square.and.arrow.down")
                }
                Button {
                    isZipImporterPresented = true
                } label: {
                    Label("项目包 / ZIP", systemImage: "archivebox")
                }
            } label: {
                Label("导入", systemImage: "tray.and.arrow.down")
            }
            .accessibilityIdentifier("library.importMenu")
        }
    }

    private var creativeSection: some View {
        Section("开始创作") {
            TextField("今天想做个什么？", text: $newDescription, axis: .vertical)
                .accessibilityIdentifier("library.creativePrompt")
            Button {
                newName = ""
                newTemplateID = "blank"
                isNewSheetPresented = true
            } label: {
                Label("开始创建", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(newDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("library.creativeStart")
        }
    }

    /// 首屏快速开始：基础模板 + 少量新模板（计划 §3.3：完整库进模板库页）。
    private var quickTemplates: [ProjectTemplate] {
        let priority = ["counter", "calc", "todo"]
        let base = priority.compactMap { id in templates.first { $0.id == id } }
        let rest = templates.filter { !priority.contains($0.id) }.prefix(2)
        return base + rest
    }

    private var quickTemplateSection: some View {
        Section("从模板开始") {
            ForEach(quickTemplates, id: \.id) { template in
                Button {
                    createFromTemplate(template)
                } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.displayName).font(.headline)
                            if let description = template.description {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("library.template.\(template.id)")
            }
        }
    }

    private var recentSection: some View {
        Section("最近作品") {
            if summaries.isEmpty {
                Text("还没有作品。可以从模板开始，或用上面的入口描述需求。")
                    .foregroundStyle(.secondary)
            }
            let columns = [GridItem(.adaptive(minimum: DS.Layout.libraryCardMinWidth), spacing: DS.Space.m)]
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(summaries, id: \.projectID) { summary in
                    LibraryCard(
                        summary: summary, current: SwiftRuntimeEngine.version,
                        surface: DS.Surface.secondary(colorScheme),
                        onOpen: { path.append(OpenedProject(id: summary.projectID, initialPrompt: "")) },
                        onRename: { renaming = summary; renamingText = summary.displayName },
                        onDuplicate: { duplicate(summary) },
                        onExport: { export(summary) },
                        onDelete: { deleting = summary })
                }
            }
        }
    }

    private var gallerySection: some View {
        Section {
            NavigationLink {
                TemplateGalleryView(templates: templates,
                                    onCreate: { createFromTemplate($0) })
            } label: {
                Label("模板库（\(templates.count)）", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("library.templateGallery")
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                newSection
                if summaries.isEmpty {
                    creativeSection
                }
                quickTemplateSection
                recentSection
                gallerySection
            }
            .navigationTitle("我的作品")
            .accessibilityIdentifier("library.list")
            .sheet(isPresented: $isNewSheetPresented) { newSheet }
            .fileImporter(isPresented: $isSwiftImporterPresented, allowedContentTypes: [.swiftSource]) {
                importSwift($0)
            }
            .fileImporter(isPresented: $isZipImporterPresented, allowedContentTypes: [.zip]) {
                importZip($0)
            }
            .alert("重命名", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            )) {
                TextField("名称", text: $renamingText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("确定") { commitRename() }
            }
            .alert("删除作品？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            )) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除（含快照与数据）", role: .destructive) { commitDelete() }
            } message: {
                Text("作品包、回滚快照与数据目录将一起移除，不可撤销。")
            }
            .alert("失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $shareURL) { item in
                ShareSheet(url: item.url)
            }
            .navigationDestination(for: OpenedProject.self) { opened in
                WorkspaceDestination(library: library, opened: opened)
            }
            .task { refresh() }
        }
    }

    // MARK: - 新建表

    private var newSheet: some View {
        NavigationStack {
            Form {
                TextField("作品名称", text: $newName)
                    .accessibilityIdentifier("library.newName")
                TextField("需求描述（交给助手，可选）", text: $newDescription, axis: .vertical)
                    .accessibilityIdentifier("library.newDescription")
                Picker("起始", selection: $newTemplateID) {
                    Text("空白 Swift 项目").tag("blank")
                    ForEach(templates, id: \.id) { template in
                        Text(template.displayName).tag(template.id)
                    }
                }
                .accessibilityIdentifier("library.newTemplate")
            }
            .navigationTitle("新建作品")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isNewSheetPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { createNew() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("library.create")
                }
            }
        }
    }

    // MARK: - 操作

    /// 模板动态发现：包内 Templates/ 下每个子目录一个模板（缺失时退回基础三个）。
    private static func templateIDs() -> [String] {
        guard let base = Bundle.main.url(forResource: "Templates", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return ["calc", "counter", "todo"]
        }
        let ids = names.filter { !$0.hasPrefix(".") }.sorted()
        return ids.isEmpty ? ["calc", "counter", "todo"] : ids
    }

    /// 按类别分组（保持首次出现顺序）。
    private var templateCategories: [(String, [ProjectTemplate])] {
        var order: [String] = []
        var map: [String: [ProjectTemplate]] = [:]
        for t in templates {
            let c = t.category ?? "其他"
            if map[c] == nil { order.append(c) }
            map[c, default: []].append(t)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func refresh() {
        summaries = library.list()
        templates = Self.templateIDs().compactMap { try? ProjectTemplate.load(named: $0) }
    }

    private func createNew() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id: ProjectID
            if newTemplateID == "blank" {
                id = try library.createBlank(displayName: name)
            } else if let template = templates.first(where: { $0.id == newTemplateID }) {
                id = try library.createFromTemplate(
                    ProjectLibrary.TemplateFiles(templateID: template.id,
                                                 entrySymbol: template.entrySymbolName,
                                                 files: template.files.map { (path: $0.path, contents: $0.contents) }),
                    displayName: name)
            } else {
                return
            }
            isNewSheetPresented = false
            refresh()
            // 描述需求创建：打开工作区并把描述经 initialPrompt 交给助手槽位。
            path.append(OpenedProject(id: id, initialPrompt: prompt))
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func createFromTemplate(_ template: ProjectTemplate) {
        do {
            let id = try library.createFromTemplate(
                ProjectLibrary.TemplateFiles(templateID: template.id,
                                             entrySymbol: template.entrySymbolName,
                                             files: template.files.map { (path: $0.path, contents: $0.contents) }))
            refresh()
            path.append(OpenedProject(id: id, initialPrompt: ""))
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func duplicate(_ summary: ProjectLibrary.Summary) {
        do {
            let id = try library.duplicate(summary.projectID)
            refresh()
            path.append(OpenedProject(id: id, initialPrompt: ""))
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func commitRename() {
        guard let target = renaming else { return }
        renaming = nil
        do {
            try library.rename(target.projectID, displayName: renamingText)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func commitDelete() {
        guard let target = deleting else { return }
        deleting = nil
        do {
            try library.delete(target.projectID)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func importSwift(_ result: Result<URL, any Error>) {
        guard case let .success(url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let id = try library.importSwiftFile(displayName: url.deletingPathExtension().lastPathComponent, sourceURL: url)
            refresh()
            path.append(OpenedProject(id: id, initialPrompt: ""))
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func importZip(_ result: Result<URL, any Error>) {
        guard case let .success(url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let id = try library.importZIP(data)
            refresh()
            path.append(OpenedProject(id: id, initialPrompt: ""))
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func export(_ summary: ProjectLibrary.Summary) {
        do {
            let data = try library.exportZIP(summary.projectID)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(summary.displayName).mojoproject.zip")
            try data.write(to: url, options: .atomic)
            shareURL = ShareableURL(url: url)
        } catch {
            errorMessage = "\(error)"
        }
    }
}

/// 作品卡：名称、运行类型、最后修改时间、兼容性状态。
struct ProjectCard: View {
    let summary: ProjectLibrary.Summary
    let current: RuntimeVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.displayName).font(.headline)
                Spacer()
                compatibilityBadge
            }
            Text(summary.entryDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.relative(summary.modifiedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var compatibilityBadge: some View {
        let status = compatibilityStatus(manifest: summary.runtimeVersion, current: current)
        return Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
            .accessibilityIdentifier("library.compatibility")
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 兼容性：manifest runtimeVersion vs 当前引擎 runtimeVersion。
enum CompatibilityStatus: String {
    case compatible = "一致"
    case upgradeable = "可升级"
    case incompatible = "不兼容"

    var color: Color {
        switch self {
        case .compatible: .green
        case .upgradeable: .orange
        case .incompatible: .red
        }
    }
}

func compatibilityStatus(manifest: String, current: RuntimeVersion) -> CompatibilityStatus {
    guard let version = RuntimeVersion(parsing: manifest) else { return .incompatible }
    if version == current { return .compatible }
    if version.major == current.major, version < current { return .upgradeable }
    return .incompatible
}

/// 打开作品：异步打开 ProjectStore 后进工作区（每作品一个 RunCoordinator）。
struct WorkspaceDestination: View {
    let library: ProjectLibrary
    let opened: OpenedProject
    @State private var store: ProjectStore?
    @State private var coordinator: RunCoordinator?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let store, let coordinator {
                WorkspaceView(project: store, library: library, coordinator: coordinator,
                              initialPrompt: opened.initialPrompt)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("打不开作品", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView("正在打开…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: opened.id) {
            do {
                let openedStore = try await library.openStore(opened.id)
                await MainActor.run {
                    self.store = openedStore
                    self.coordinator = RunCoordinator(engine: SwiftRuntimeEngine())
                }
            } catch {
                await MainActor.run { self.errorMessage = WorkspaceModel.describe(error) }
            }
        }
    }
}

extension ProjectTemplate {
    /// 根视图入口符号名（模板均为 rootView 入口）。
    var entrySymbolName: String? {
        if case let .rootView(symbol) = entry { return symbol }
        return nil
    }
}

/// `sheet(item:)` 需要 Identifiable；不对 Foundation 的 URL 做追溯扩展（跨模块一致性告警）。
private struct ShareableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系统分享（导出 ZIP 用）。
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

private extension UTType {
    static var swiftSource: UTType {
        UTType(filenameExtension: "swift") ?? .plainText
    }
}


/// 作品卡（网格单元）：样式收敛在此，回调由宿主提供。
private struct LibraryCard: View {
    let summary: ProjectLibrary.Summary
    let current: RuntimeVersion
    let surface: Color
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            ProjectCard(summary: summary, current: current)
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.project.\(summary.projectID.description)")
        .contextMenu {
            Button("重命名") { onRename() }
            Button("复制") { onDuplicate() }
            Button("导出 ZIP") { onExport() }
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}
