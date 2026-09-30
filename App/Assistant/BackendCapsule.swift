import SwiftUI
import FoundationAI
import RuntimeContracts

// 顶部后端与状态胶囊：设备端 / Apple 云端 / 不可用 + 原因。
// 云端首次使用由 session.needsCloudConsent 触发确认框；PCC SDK 缺失时禁用并显示原因。
struct BackendCapsule: View {
    @Bindable var session: AssistantSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                backendButton(.onDevice, availability: session.onDeviceAvailability, disabledReason: nil)
                backendButton(.privateCloudCompute, availability: session.cloudAvailability,
                              disabledReason: session.cloudDisabledReason)
                Spacer()
                Button {
                    Task { await session.refreshAvailability() }
                } label: {
                    Label("检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("assistant.recheck")
            }
            if let reason = session.cloudDisabledReason {
                Text(verbatim: "Apple 云端不可用：\(reason)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if session.autoRunOnValidated {
                Text("模型修改校验通过后直接应用并运行")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("模型修改后直接运行", isOn: $session.autoRunOnValidated)
                .font(.footnote)
                .toggleStyle(.switch)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task { await session.refreshAvailability() }
    }

    private func backendButton(_ backend: ModelBackend, availability: ModelAvailability?,
                               disabledReason: String?) -> some View {
        let selected = session.backend == backend
        return Button {
            if backend == .privateCloudCompute, !session.hasCloudConsent {
                session.needsCloudConsent = true
            } else if disabledReason == nil {
                session.backend = backend
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: dot(for: availability))
                Text(backend.shortName)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? .blue.opacity(0.2) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .accessibilityIdentifier("assistant.backend.\(backend.rawValue)")
    }

    private func dot(for availability: ModelAvailability?) -> String {
        guard let availability else { return "questionmark.circle" }
        return availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
}

// "诊断与控制台"折叠区（从运行页迁入）：只读 coordinator.diagnostics / console。
// 控制台上限 2000 行复用 coordinator 截断，这里只取尾部显示。
struct AssistantDiagnosticsSection: View {
    var coordinator: RunCoordinator
    var onLocate: (FileID, Int) -> Void

    var body: some View {
        DisclosureGroup("诊断与控制台") {
            VStack(alignment: .leading, spacing: 8) {
                if coordinator.diagnostics.isEmpty {
                    Text("暂无诊断")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    DiagnosticCardView(diagnostics: coordinator.diagnostics,
                                       source: "上次运行", onLocate: onLocate)
                }
                Text("控制台（尾部 \(tail.count) 行，共上限 \(RunCoordinator.consoleLimit) 行）")
                    .font(.footnote).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tail, id: \.id) { entry in
                            Text(verbatim: "[\(entry.stream)] \(entry.text)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .font(.headline)
        .accessibilityIdentifier("assistant.diagnostics")
    }

    private var tail: [ConsoleEntry] { Array(coordinator.console.suffix(100)) }
}
