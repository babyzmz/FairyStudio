import SwiftUI
import RuntimeContracts
import NativeBridge

/// 源码编辑区（M0：CodeTextView；M1 换 TextKit 2 原生编辑器）。
struct SourceEditorPane: View {
    @Bindable var studio: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("文件", selection: $studio.selectedFileID) {
                    ForEach(studio.files) { file in
                        Text(file.fileName).tag(file.id)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("editor.filePicker")
                Button {
                    studio.reverseFileOrder()
                } label: {
                    Label("交换文件顺序", systemImage: "arrow.left.arrow.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("editor.swapOrder")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Text(verbatim: "传给运行时的文件顺序：\(studio.fileOrderDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .accessibilityIdentifier("editor.order")

            CodeTextView(text: Binding(
                get: { studio.contents(of: studio.selectedFileID) },
                set: { studio.updateContents(of: studio.selectedFileID, to: $0) }
            ))
            .padding(.horizontal, 4)
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
    var budgetDescription: String = ""
    @Binding var isExpanded: Bool
    @State private var tab: DrawerTab = .diagnostics

    enum DrawerTab: String, CaseIterable, Identifiable {
        case diagnostics = "诊断"
        case console = "控制台"
        #if DEBUG
        case metrics = "指标"
        #endif
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
                .accessibilityIdentifier("console.tabs")
                #if DEBUG
                if tab == .metrics {
                    // 非惰性：所有指标行都在无障碍树中（UI 测试读取），不依赖滚动位置。
                    ScrollView {
                        MetricsRows(coordinator: coordinator, budgetDescription: budgetDescription)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    }
                    .frame(minHeight: 140, idealHeight: 220, maxHeight: 280)
                } else {
                    entriesList
                }
                #else
                entriesList
                #endif
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var entriesList: some View {
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
            #if DEBUG
            case .metrics:
                EmptyView()
            #endif
            }
        }
        .listStyle(.plain)
        .frame(minHeight: 140, idealHeight: 220, maxHeight: 280)
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

#if DEBUG
/// DEBUG 诊断指标：实例计数、引擎存活资源、进程内存、进入运行 / 停止耗时。全部来自真实测量，只读。
struct MetricsRows: View {
    let coordinator: RunCoordinator
    let budgetDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("刷新指标") { coordinator.refreshMetrics() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("metrics.refresh")
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        metric("状态序列", coordinator.stateHistory.map(\.rawValue).joined(separator: "→"), id: "metrics.stateHistory")
        metric("预算", budgetDescription, id: "metrics.budget")
        metric("协调器持有实例", "\(coordinator.activeInstanceCount)", id: "metrics.activeInstances")
        metric("引擎存活（实例/线程/任务）", coordinator.engineLiveCounts.map { "\($0.instances)/\($0.threads)/\($0.tasks)" } ?? "未读取",
               id: "metrics.engineLive")
        metric("已启动 / 已释放实例", "\(coordinator.startedRunCount)/\(coordinator.releasedInstanceCount)", id: "metrics.runCounts")
        metric("常驻内存 MB", coordinator.memory.map { String(format: "%.1f", $0.residentMB) } ?? "未读取", id: "metrics.residentMB")
        metric("内存占用 phys_footprint MB", coordinator.memory.map { String(format: "%.1f", $0.footprintMB) } ?? "未读取",
               id: "metrics.footprintMB")
        metric("进入运行耗时 ms", Self.ms(coordinator.lastStartLatency), id: "metrics.startLatency")
        metric("校验耗时 ms", Self.ms(coordinator.lastValidationDuration), id: "metrics.validation")
        metric("停止→终态 ms", Self.ms(coordinator.lastStopLatency), id: "metrics.stopLatency")
        metric("停止→实例释放 ms", Self.ms(coordinator.lastStopCompletionLatency), id: "metrics.stopCompletion")
    }

    private func metric(_ title: String, _ value: String, id: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .font(.caption.monospaced())
                .accessibilityIdentifier(id)
        } label: {
            Text(title).font(.caption)
        }
    }

    static func ms(_ duration: Duration?) -> String {
        guard let duration else { return "—" }
        let (seconds, attoseconds) = duration.components
        return String(format: "%.1f", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
#endif
