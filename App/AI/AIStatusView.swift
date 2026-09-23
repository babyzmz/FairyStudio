import SwiftUI
import FoundationAI

/// 「AI 状态」页：三态标题 + 具体原因 + 重新检测 + 最小 prompt 输入。
/// 不可用时发送按钮禁用并显示原因；不存在任何假响应路径。
struct AIStatusView: View {
    @Bindable var model: AIStatusModel
    @State private var showsCloudConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(model.headline.title, systemImage: headlineIcon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(headlineColor)
                            .accessibilityIdentifier("ai.headline")
                        if model.headline == .unavailable {
                            Text(unavailableSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("ai.headline.reason")
                        }
                    }
                    .padding(.vertical, 4)
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.isChecking {
                            ProgressView()
                        } else {
                            Label("重新检测", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isChecking)
                    .accessibilityIdentifier("ai.recheck")
                }

                Section("后端") {
                    BackendRow(backend: .onDevice, availability: model.onDevice)
                    BackendRow(backend: .privateCloudCompute, availability: model.cloud)
                    if !model.rawOnDevice.isEmpty {
                        LabeledContent("系统原始值") {
                            Text(verbatim: model.rawOnDevice)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                        .accessibilityIdentifier("ai.raw")
                    }
                    if let checkedAt = model.lastCheckedAt {
                        LabeledContent("检测时间", value: checkedAt.formatted(date: .omitted, time: .standard))
                    }
                }

                Section {
                    Picker("使用后端", selection: Binding(
                        get: { model.selectedBackend },
                        set: { backend in
                            if backend == .privateCloudCompute && !model.hasCloudConsent {
                                showsCloudConsent = true
                            } else {
                                model.selectedBackend = backend
                            }
                        }
                    )) {
                        ForEach(ModelBackend.allCases) { backend in
                            Text(backend.shortName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("输入一段提示", text: $model.prompt, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("ai.prompt")
                    HStack {
                        Button("发送") { model.send() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canSend)
                            .accessibilityIdentifier("ai.send")
                        if model.isResponding {
                            Button("取消", role: .cancel) { model.cancel() }
                                .buttonStyle(.bordered)
                        }
                    }
                    if let reason = model.sendBlockReason, !model.isResponding {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ai.send.reason")
                    }
                } header: {
                    Text("试用")
                } footer: {
                    Text("默认只使用设备端模型。Apple 云端需要你的明确确认，设备端不可用时不会自动改用云端。")
                }

                if model.isResponding || !model.responseText.isEmpty || model.lastFailure != nil || model.wasCancelled {
                    Section("结果") {
                        if let backend = model.responseBackend {
                            LabeledContent("实际后端", value: backend.displayName)
                        }
                        if !model.responseText.isEmpty {
                            Text(verbatim: model.responseText)
                                .textSelection(.enabled)
                        }
                        if let failure = model.lastFailure {
                            Label(failure.userMessage, systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                        if model.wasCancelled {
                            Label("已取消", systemImage: "stop.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.hasCloudConsent {
                    Section {
                        Button("撤销 Apple 云端授权", role: .destructive) { model.revokeCloudConsent() }
                    }
                }
            }
            .navigationTitle("AI 状态")
            .task { await model.refresh() }
            .confirmationDialog("使用 Apple 云端？", isPresented: $showsCloudConsent, titleVisibility: .visible) {
                Button("允许使用 Apple 云端") {
                    model.grantCloudConsent()
                    model.selectedBackend = .privateCloudCompute
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("你的提示将发送到 Apple Private Cloud Compute 处理。设备端模式下内容不会离开本机。")
            }
        }
    }

    private var headlineIcon: String {
        switch model.headline {
        case .onDevice: "iphone"
        case .cloud: "icloud"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var headlineColor: Color {
        model.headline == .unavailable ? .orange : .green
    }

    private var unavailableSummary: String {
        let local = model.onDevice.map { "设备端：\($0.reasonDescription)" } ?? "设备端：检测中"
        let cloud = model.cloud.map { "Apple 云端：\($0.reasonDescription)" } ?? "Apple 云端：检测中"
        return "\(local)\n\(cloud)"
    }
}

private struct BackendRow: View {
    let backend: ModelBackend
    let availability: ModelAvailability?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(backend.displayName)
                Spacer()
                Image(systemName: availability?.isAvailable == true ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(availability?.isAvailable == true ? .green : .secondary)
            }
            if let availability {
                Text(availability.reasonDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: availability.code)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("ai.code.\(backend.rawValue)")
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
    }
}
