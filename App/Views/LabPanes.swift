import SwiftUI
import RuntimeContracts
import NativeBridge

/// 源码编辑区（M0：TextEditor；M1 换 TextKit 2 原生编辑器）。
struct SourceEditorPane: View {
    @Bindable var studio: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("文件", selection: $studio.selectedFileID) {
                ForEach(studio.files) { file in
                    Text((file.path as NSString).lastPathComponent).tag(file.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("editor.filePicker")

            TextEditor(text: Binding(
                get: { studio.binding(for: studio.selectedFileID)?.contents ?? "" },
                set: { studio.updateContents(of: studio.selectedFileID, to: $0) }
            ))
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollDismissesKeyboard(.interactively)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("editor.text")
        }
    }
}

/// 渲染区：显示当前运行的 RenderTree；非运行态时禁用交互并说明原因。
struct PreviewPane: View {
    let coordinator: RunCoordinator

    var body: some View {
        Group {
            if let tree = coordinator.tree {
                RenderTreeView(tree: tree) { input in
                    coordinator.send(input)
                }
                .disabled(!coordinator.acceptsInput)
                .overlay(alignment: .topTrailing) {
                    if !coordinator.acceptsInput {
                        Text("未在运行：界面只读")
                            .font(.caption2)
                            .padding(6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(placeholderTitle, systemImage: "rectangle.dashed")
                } description: {
                    Text(placeholderMessage)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var placeholderTitle: String {
        switch coordinator.state {
        case .validating: "正在校验"
        case .preparing: "正在准备运行"
        case .failed: "运行失败"
        default: "尚未运行"
        }
    }

    private var placeholderMessage: String {
        switch coordinator.state {
        case .failed:
            coordinator.diagnostics.first { $0.severity == .error }?.message ?? "查看下方诊断"
        default:
            "点击「运行」或按 ⌘R"
        }
    }
}

/// 诊断/控制台抽屉：折叠时显示计数，展开后分为诊断与控制台两个列表。
struct ConsoleDrawer: View {
    let coordinator: RunCoordinator
    @Binding var isExpanded: Bool
    @State private var tab: DrawerTab = .diagnostics

    enum DrawerTab: String, CaseIterable, Identifiable {
        case diagnostics = "诊断"
        case console = "控制台"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    Text("诊断 \(coordinator.diagnostics.count) · 控制台 \(coordinator.console.count)")
                        .font(.footnote)
                    Spacer()
                    if let runID = coordinator.displayedRunID {
                        Text("Run \(runID.rawValue.uuidString.prefix(8))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("console.toggle")

            if isExpanded {
                Picker("类型", selection: $tab) {
                    ForEach(DrawerTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                List {
                    switch tab {
                    case .diagnostics:
                        if coordinator.diagnostics.isEmpty {
                            Text("没有诊断").foregroundStyle(.secondary)
                        }
                        ForEach(coordinator.diagnostics) { diagnostic in
                            DiagnosticRow(diagnostic: diagnostic)
                        }
                    case .console:
                        ForEach(coordinator.console) { entry in
                            Text(verbatim: entry.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.stream == .stderr ? Color.red : (entry.stream == .debug ? Color.secondary : Color.primary))
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 140, idealHeight: 220, maxHeight: 280)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: diagnostic.message)
                    .font(.callout)
                Text(verbatim: "\(diagnostic.kind.rawValue)\(diagnostic.capabilityID.map { " · \($0)" } ?? "")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let suggestion = diagnostic.suggestion {
                    Text(verbatim: suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle.fill"
        }
    }

    private var color: Color {
        switch diagnostic.severity {
        case .error: .red
        case .warning: .orange
        case .note: .blue
        }
    }
}
