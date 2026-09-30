import SwiftUI
import RuntimeContracts
import NativeBridge

/// 渲染区：显示当前运行的 RenderTree；非运行态时禁用交互并说明原因。
/// 诊断与控制台不在此显示（W1 起并入助手面板；数据仍由 RunCoordinator 保留给助手读）。
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
            coordinator.diagnostics.first { $0.severity == .error }?.message ?? "查看助手面板中的诊断"
        default:
            "点击「运行」或按 ⌘R"
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
