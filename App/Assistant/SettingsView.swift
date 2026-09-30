import SwiftUI
import FoundationAI
import ProjectContracts

/// 设置页（计划 §5.3 / 用户 2026-09-30 调整：设置从首页进入，分类管理；
/// 聊天区不再承载设置入口）。分区：模型后端 / OpenRouter / 更新策略 / 关于。
struct SettingsView: View {
    @Bindable var settings: AssistantSettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var onDeviceAvailability: ModelAvailability?
    @State private var keyStatus = "未配置"
    @State private var draftKey = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isUpdatingCatalog = false
    @State private var catalogNotice = ""
    @State private var keyRevision = 0
    @State private var catalogRevision = 0
    private let keychain = OpenRouterKeychain()

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                if settings.backend == .openRouter || settings.isOpenRouterEnabled {
                    openRouterSection
                }
                updateStrategySection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await refreshAvailability()
                keyStatus = keychain.statusDescription()
            }
        }
    }

    // MARK: - 模型后端

    private var backendSection: some View {
        Section {
            Picker("默认后端", selection: $settings.backend) {
                Text("设备端").tag(ModelBackend.onDevice)
                Text("Apple 云端").tag(ModelBackend.privateCloudCompute)
                Text("OpenRouter").tag(ModelBackend.openRouter)
            }
            if let availability = onDeviceAvailability {
                LabeledContent("设备端模型", value: availability.isAvailable ? "可用" : availability.reasonDescription)
            }
            LabeledContent("设备端上下文", value: "约 4K tokens（输入与输出共享）")
        } header: {
            Text("模型后端")
        } footer: {
            Text("默认设备端：内容不离开本机。切换到云端后端前需在对应分区完成配置与授权。")
        }
    }

    // MARK: - OpenRouter（用户自配云端）

    private var openRouterSection: some View {
        Section {
            Toggle("启用 OpenRouter", isOn: openRouterEnabledBinding)
            if settings.isOpenRouterEnabled {
                LabeledContent("API Key", value: keyStatus)
                SecureField("sk-or-…", text: $draftKey)
                HStack {
                    Button("保存 Key") {
                        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = keychain.setApiKey(trimmed) {
                            keyStatus = "保存失败：\(error)"
                        } else {
                            keyStatus = keychain.statusDescription()
                            draftKey = ""
                        }
                    }
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("删除 Key", role: .destructive) {
                        if let error = keychain.deleteApiKey() {
                            keyStatus = "删除失败：\(error)"
                        } else {
                            keyStatus = keychain.statusDescription()
                        }
                    }
                }
                Picker("模型", selection: openRouterModelBinding) {
                    ForEach(OpenRouterCatalog.verified) { info in
                        Text(info.displayName).tag(info.id)
                    }
                }
                HStack {
                    Button("连接测试（发送一条最小请求）") {
                        isTesting = true
                        testResult = nil
                        let provider = OpenRouterProvider(keyStore: keychain, modelID: settings.openRouterModelID)
                        Task {
                            let availability = await provider.testConnection()
                            testResult = availability.isAvailable ? "连接成功，Key 有效。" : availability.reasonDescription
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                }
                if let testResult {
                    Text(testResult).font(.caption)
                }
                HStack {
                    Button("更新模型目录（核对上下文与输出上限）") {
                        isUpdatingCatalog = true
                        catalogNotice = ""
                        let provider = OpenRouterProvider(keyStore: keychain, modelID: settings.openRouterModelID)
                        Task {
                            do {
                                let live = try await provider.fetchLiveModels()
                                let known = live.filter { info in
                                    OpenRouterCatalog.verified.contains { $0.id == info.id }
                                }
                                catalogRevision += 1
                                catalogNotice = "已核对 \(known.count)/\(OpenRouterCatalog.verified.count) 个模型（目录共 \(live.count) 个可用）"
                            } catch let failure as ModelTaskFailure {
                                catalogNotice = failure.userMessage
                            } catch {
                                catalogNotice = "目录获取失败：\(error)"
                            }
                            isUpdatingCatalog = false
                        }
                    }
                    .disabled(isUpdatingCatalog)
                }
                if isUpdatingCatalog {
                    Text("正在核对实时目录…").font(.caption)
                }
                if catalogNotice != "" {
                    Text(catalogNotice).font(.caption)
                }
                LabeledContent("上下文", value: contextDescription())
                Text("启用后，对话、诊断与项目 Swift 源码将发送至 OpenRouter 及其上游模型供应商；关闭后拒绝新请求；已发送内容无法撤回。Key 仅存于本机钥匙串，不进入源码、日志与导出内容。各模型的 token 预算独立管理，不受设备端 4K 上下文限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("OpenRouter（用户自配云端）")
        } footer: {
            Text("未授权时不会发起任何请求。")
        }
    }

    // MARK: - 更新策略

    private var updateStrategySection: some View {
        Section {
            Picker("更新策略", selection: $settings.updateStrategy) {
                ForEach(UpdateStrategy.allCases) { strategy in
                    Text(strategy.rawValue).tag(strategy)
                }
            }
            switch settings.updateStrategy {
            case .manual:
                Text("每个候选先看改动再应用。").font(.caption).foregroundStyle(.secondary)
            case .autoCompatible:
                Text("候选启动检查通过后提交并重新运行；临时界面状态会重置。保状态热更新尚未启用。").font(.caption).foregroundStyle(.secondary)
            case .paused:
                Text("继续生成候选，但保留当前运行版本，不自动应用。").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("更新策略")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: AssistantSidebarView.appVersion)
            LabeledContent("运行环境", value: "SwiftRuntime · SwiftUI 子集")
            LabeledContent("设备与构建信息", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        }
    }

    // MARK: - 绑定与辅助

    private var openRouterEnabledBinding: Binding<Bool> {
        Binding(get: { settings.isOpenRouterEnabled }, set: { settings.setOpenRouterEnabled($0) })
    }

    private var openRouterModelBinding: Binding<String> {
        Binding(get: { settings.openRouterModelID }, set: { settings.openRouterModelID = $0 })
    }

    private func contextDescription() -> String {
        _ = catalogRevision
        let provider = OpenRouterProvider(keyStore: keychain, modelID: settings.openRouterModelID)
        guard let info = provider.modelInfo(for: settings.openRouterModelID) else { return "待核对（更新模型目录）" }
        var parts: [String] = []
        if let context = info.contextLength { parts.append("上下文 \(context / 1000)k") }
        if let maxOutput = info.maxOutput { parts.append("输出上限 \(maxOutput)") }
        return parts.isEmpty ? "待核对（更新模型目录）" : parts.joined(separator: " / ")
    }

    private func refreshAvailability() async {
        onDeviceAvailability = await OnDeviceModelDriver().checkAvailability()
    }
}
