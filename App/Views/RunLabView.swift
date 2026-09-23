import SwiftUI
import RuntimeContracts

/// 「运行实验」页：源码编辑区、运行/停止（始终在顶部可达）、渲染区、诊断/控制台抽屉。
/// iPad（regular 宽度）左右分栏；iPhone（compact）在代码与预览之间切换，运行后自动切到预览。
struct RunLabView: View {
    @Bindable var studio: StudioModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPane: CompactPane = .code
    @State private var isConsoleExpanded = false

    enum CompactPane: String, CaseIterable, Identifiable {
        case code = "代码"
        case preview = "预览"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            RunToolbar(studio: studio) {
                // 运行时收起键盘：让出预览区与诊断抽屉（iPad 上编辑区与预览并排，键盘会遮住抽屉）。
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                studio.run()
                compactPane = .preview
            }
            Divider()
            if horizontalSizeClass == .regular {
                HStack(spacing: 0) {
                    SourceEditorPane(studio: studio)
                        .frame(maxWidth: .infinity)
                    Divider()
                    PreviewPane(coordinator: studio.coordinator)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Picker("面板", selection: $compactPane) {
                    ForEach(CompactPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("lab.panePicker")
                switch compactPane {
                case .code: SourceEditorPane(studio: studio)
                case .preview: PreviewPane(coordinator: studio.coordinator)
                }
            }
            Divider()
            ConsoleDrawer(coordinator: studio.coordinator, budgetDescription: studio.budgetDescription, isExpanded: $isConsoleExpanded)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// 顶部工具条：状态、引擎、运行（⌘R）、停止（⌘.）。放在顶部，键盘弹出时不会被遮挡。
struct RunToolbar: View {
    let studio: StudioModel
    let onRun: () -> Void

    var body: some View {
        let coordinator = studio.coordinator
        HStack(spacing: 8) {
            RunStateBadge(state: coordinator.state)
            EngineLabel(studio: studio)
            Spacer(minLength: 4)
            Button(action: onRun) {
                Label(coordinator.isActive ? "重新运行" : "运行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("run.button")
            Button {
                studio.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!coordinator.isActive)
            .accessibilityIdentifier("stop.button")
        }
        .labelStyle(AdaptiveLabelStyle())
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// 大字号时只显示图标，避免工具条溢出。
struct AdaptiveLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

struct RunStateBadge: View {
    let state: RunState

    var body: some View {
        Text(state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(Text("运行状态：\(state.displayName)"))
            .accessibilityIdentifier("run.state")
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .validating, .preparing, .stopping: .orange
        case .failed, .interrupted: .red
        case .idle, .stopped: .secondary
        }
    }
}

/// 当前引擎（M0-C 起只有 SwiftRuntime 解释器，不再提供夹具引擎选择）。
struct EngineLabel: View {
    let studio: StudioModel

    var body: some View {
        Label(studio.engineChoice.displayName, systemImage: "cpu")
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("引擎：\(studio.engineChoice.displayName)"))
            .accessibilityIdentifier("engine.label")
    }
}
