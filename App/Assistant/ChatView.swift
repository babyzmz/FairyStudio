import SwiftUI
import FoundationAI
import RuntimeContracts

// 助手对话流：气泡、流式文本、变更卡片、诊断卡片；输入框；诊断与控制台折叠区。
// 深浅色与 Dynamic Type：只用系统控件与 .font，不写死颜色与字号。
struct ChatView: View {
    @Bindable var session: AssistantSession
    var coordinator: RunCoordinator
    var onLocate: (FileID, Int) -> Void

    init(session: AssistantSession, onLocate: @escaping (FileID, Int) -> Void = { _, _ in }) {
        self.session = session
        self.coordinator = session.coordinatorForViews
        self.onLocate = onLocate
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            AssistantDiagnosticsSection(coordinator: coordinator, onLocate: onLocate)
                .padding(.horizontal, 8)
            if session.contextTrimmedNotice {
                Label("已裁剪上下文", systemImage: "scissors")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            inputBar
        }
        .confirmationDialog("使用 Apple 云端？", isPresented: $session.needsCloudConsent,
                            titleVisibility: .visible) {
            Button("允许使用 Apple 云端") {
                session.grantCloudConsent()
                session.backend = .privateCloudCompute
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你的提示与项目上下文将发送到 Apple Private Cloud Compute 处理。设备端模式下内容不会离开本机。")
        }
    }

    @ViewBuilder
    private func messageView(_ message: AssistantMessage) -> some View {
        switch message.kind {
        case let .user(text):
            HStack {
                Spacer()
                Text(verbatim: text)
                    .padding(8)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case let .assistant(text, streaming: streaming):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if text.isEmpty, streaming {
                        ProgressView()
                    } else {
                        Text(verbatim: text)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .background(.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
        case let .change(pending, status):
            ChangeCardView(pending: pending, status: status,
                           onApply: { session.applyCard(changeSetID: pending.changeSet.id) },
                           onDiscard: { session.discardCard(changeSetID: pending.changeSet.id) },
                           onLocate: onLocate)
        case let .diagnostics(diags, source):
            DiagnosticCardView(diagnostics: diags, source: source, onLocate: onLocate)
        case let .system(text):
            HStack {
                Spacer()
                Text(verbatim: text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextField("描述你想改变的地方…", text: $session.inputDraft, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("assistant.input")
            if session.isResponding {
                Button("取消", role: .cancel) { session.cancel() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("assistant.cancel")
                    .accessibilityLabel("停止生成")
            } else {
                Button("发送") { session.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("assistant.send")
            }
        }
        .padding(8)
    }
}

// ChatView 经 session 触达 coordinator（诊断/控制台只读），不另存引用。
extension AssistantSession {
    var coordinatorForViews: RunCoordinator { coordinator }
}
