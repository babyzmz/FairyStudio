import SwiftUI
import RuntimeContracts
import ProjectContracts
import ProjectCore

/// 工作区（作品为中心，计划 §4）：
/// - 主舞台：运行中的作品（作品视图）或编辑器（代码视图），运行控制在舞台侧；
/// - 助手：右侧栏（iPad）/独立分段（iPhone），以任务与改动卡为中心；
/// - 顶栏：返回、作品名与保存状态、作品/代码切换、历史、更多。
/// 生成/运行/更新三状态轴来自 StateContract（AssistantSession + RunCoordinator）。
struct WorkspaceView: View {
    @State private var model: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var showHistory = false

    init(project: ProjectStore, library: ProjectLibrary, coordinator: RunCoordinator, initialPrompt: String = "") {
        _model = State(initialValue: WorkspaceModel(store: project, library: library,
                                                    coordinator: coordinator, initialPrompt: initialPrompt))
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkspaceLayout.mode(horizontalSizeClass: sizeClass, width: proxy.size.width)
            VStack(spacing: 0) {
                headerBar
                Divider()
                if let hint = model.entryFileHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .accessibilityIdentifier("workspace.entryHint")
                }
                switch layout {
                case .triple:
                    let widths = WorkspaceWidths.split(available: proxy.size.width)
                    HStack(spacing: 0) {
                        mainStage.frame(width: widths.stage)
                        Divider()
                        assistantColumn
                            .frame(width: widths.assistant)
                            .accessibilityIdentifier("assistant.sidebar")
                    }
                case .double:
                    HStack(spacing: 0) {
                        mainStage.frame(maxWidth: .infinity)
                        if model.isAssistantVisible {
                            Divider()
                            assistantColumn
                                .frame(width: min(380, proxy.size.width * 0.4))
                                .accessibilityIdentifier("assistant.sidebar")
                        }
                    }
                case .single:
                    compactBody
                }
            }
            .background(DS.Surface.workbench(colorScheme))
        }
        .navigationTitle(model.snapshot?.displayName ?? "工作区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .sheet(isPresented: singleSidebarBinding) {
            NavigationStack { AssistantSidebarView(session: model.assistant) }
        }
        .sheet(isPresented: $model.isFileDrawerPresented) {
            fileDrawer
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(session: model.assistant,
                         onRestore: { recordID in model.assistant.restorePreviousVersion(recordID: recordID) })
        }
        .alert("改名", isPresented: Binding(
            get: { model.pendingRenameID != nil },
            set: { if !$0 { model.pendingRenameID = nil } }
        )) {
            TextField("新路径（如 Sources/New.swift）", text: $model.renameText)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("workspace.renameField")
            Button("取消", role: .cancel) { model.pendingRenameID = nil }
            Button("确定") { Task { await model.commitPendingRename() } }
        }
        .alert("提交失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.start() }
        .onDisappear { model.detach() }
    }

    /// iPhone：侧栏（会话历史/设置）经工具条按钮打开。
    private var singleSidebarBinding: Binding<Bool> {
        Binding(
            get: { model.isAssistantVisible && sizeClass == .compact },
            set: { model.isAssistantVisible = $0 }
        )
    }

    // MARK: - 顶栏（返回/标题+状态 | 作品·代码 | 历史·助手）

    private var headerBar: some View {
        HStack(spacing: DS.Space.s) {
            RunStateBadge(state: model.coordinator.state)
            statusSummary
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            Picker("视图", selection: $model.mainView) {
                ForEach(WorkspaceMainView.allCases) { view in
                    Text(view.rawValue).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
            .accessibilityIdentifier("workspace.viewPicker")
        }
        .padding(.horizontal)
        .padding(.vertical, DS.Space.s)
    }

    /// 状态摘要（计划 §8.1："文件已保存 rN · 正在运行 rM · 有待应用修改"）。
    private var statusSummary: some View {
        let relationship = WorkspaceVersionRelationship(
            saved: model.snapshot?.revision,
            running: model.assistant.runningVersion,
            candidateBase: nil)
        return Text(relationship.summary)
    }

    private var toolbarItems: ToolbarItemGroup<some View> {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("新建文件") {
                    Task { await model.createFile(in: ProjectLayout.sources) }
                }
                Button("新建目录") {
                    model.createDirectory("\(ProjectLayout.sources)/NewFolder")
                }
                Button("文件树…") { model.isFileDrawerPresented = true }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("workspace.newFile")
            Button {
                showHistory = true
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("workspace.historyButton")
            Button {
                model.isAssistantVisible.toggle()
            } label: {
                Label("助手", systemImage: "bubble.left.and.text.bubble.right")
            }
            .accessibilityIdentifier("workspace.assistantButton")
        }
    }

    // MARK: - 主舞台（作品 / 代码；运行控制属于舞台）

    private var mainStage: some View {
        VStack(spacing: 0) {
            runToolbar
            Divider()
            switch model.mainView {
            case .artifact:
                PreviewPane(coordinator: model.coordinator)
            case .code:
                editorPane
            }
        }
        .background(DS.Surface.content(colorScheme))
        .accessibilityIdentifier("workspace.mainStage")
    }

    private var runToolbar: some View {
        let coordinator = model.coordinator
        return HStack(spacing: DS.Space.s) {
            Button {
                model.run()
            } label: {
                Label(coordinator.isActive ? "重新运行" : "运行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("run.button")
            .frame(minHeight: 44)
            Button {
                model.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!coordinator.isActive)
            .accessibilityIdentifier("stop.button")
            .accessibilityLabel("停止作品运行")
            .frame(minHeight: 44)
            Spacer(minLength: 0)
            Button {
                model.isAssistantVisible.toggle()
            } label: {
                Label(model.isAssistantVisible ? "收起助手" : "助手", systemImage: "sidebar.trailing")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("workspace.assistantButton")
        }
        .labelStyle(AdaptiveLabelStyle())
        .padding(.horizontal)
        .padding(.vertical, DS.Space.s)
    }

    // MARK: - 助手栏（会话切换 + 聊天）

    private var assistantColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("创作助手").font(.headline)
                Spacer()
                Button {
                    model.assistant.newConversation()
                } label: {
                    Label("新任务", systemImage: "plus.bubble")
                }
                .font(.callout)
                .accessibilityIdentifier("assistant.newChat")
                Menu {
                    Button("会话历史…") { model.isAssistantVisible = true }
                    Button("设置…") { model.isAssistantVisible = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("workspace.assistantMenu")
            }
            .padding(.horizontal)
            .padding(.vertical, DS.Space.s)
            Divider()
            chatPane
        }
        .background(DS.Surface.content(colorScheme))
    }

    // MARK: - iPhone 单栏（作品 / 代码 / 助手）

    private var compactBody: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $model.compactPane) {
                ForEach(WorkspaceCompactPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, DS.Space.s)
            .accessibilityIdentifier("workspace.panePicker")
            switch model.compactPane {
            case .artifact:
                runToolbar
                Divider()
                PreviewPane(coordinator: model.coordinator)
            case .code:
                runToolbar
                Divider()
                editorPane
            case .assistant:
                assistantPaneBody
            }
        }
    }

    /// iPhone 助手段：会话切换行 + 聊天。
    private var assistantPaneBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button("新任务") { model.assistant.newConversation() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("assistant.newChat")
                Spacer()
                Button("会话与设置") { model.isAssistantVisible = true }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, DS.Space.xs)
            chatPane
        }
    }

    // MARK: - 聊天（中栏 / 助手段共用）

    private var chatPane: some View {
        ChatView(session: model.assistant, onLocate: { fileID, _ in
            model.locateInCode(fileID: fileID, line: 0)
        })
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 文件抽屉（所有布局共用）

    private var fileDrawer: some View {
        NavigationStack {
            FileTreeView(model: model)
                .navigationTitle("文件")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.isFileDrawerPresented = false }
                    }
                }
        }
    }

    // MARK: - 编辑器（多标签，未保存 •，⌘S 保存，切换保留光标）

    private var editorPane: some View {
        VStack(spacing: 0) {
            tabBar
            editorContent
        }
    }

    private var editorContent: some View {
        Group {
            if let id = model.selectedTabID {
                CodeTextView(
                    text: Binding(
                        get: { model.text(of: id) },
                        set: { model.setText($0, for: id) }
                    ),
                    cursor: Binding(
                        get: { model.cursors[id, default: 0] },
                        set: { model.cursors[id] = $0 }
                    ),
                    restore: model.restoreTokens[id, default: 0]
                )
                .scrollDismissesKeyboard(.interactively)
            } else {
                ContentUnavailableView {
                    Label("未打开文件", systemImage: "doc")
                } description: {
                    Text("从文件树选择文件，或新建一个文件")
                }
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.openedTabs, id: \.self) { id in
                    HStack(spacing: 2) {
                        Button {
                            model.open(id)
                        } label: {
                            Text("\(model.displayName(of: id))\(model.isDirty(id) ? " •" : "")")
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(model.selectedTabID == id ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.tab.\(id.rawValue)")
                        .contextMenu {
                            Button("保存") { Task { await model.save(id) } }
                            Button("关闭") { model.close(id) }
                            Button("改名…") { model.isFileDrawerPresented = true }
                            Button("删除", role: .destructive) {
                                Task { await model.deleteFile(id) }
                            }
                        }
                        Button {
                            model.close(id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.tabClose.\(id.rawValue)")
                    }
                }
                Button {
                    Task {
                        if let selected = model.selectedTabID {
                            await model.save(selected)
                        }
                    }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.hasDirtyTabs)
                .accessibilityIdentifier("workspace.save")
                if let selected = model.selectedTabID {
                    Menu {
                        Button("改名…") {
                            model.pendingRenameID = selected
                            model.renameText = model.snapshot?.file(id: selected)?.path ?? ""
                        }
                        Button("删除", role: .destructive) {
                            Task { await model.deleteFile(selected) }
                        }
                    } label: {
                        Label("本文件", systemImage: "doc")
                    }
                    .accessibilityIdentifier("workspace.fileMenu")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
