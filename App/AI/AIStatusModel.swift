import Foundation
import Observation
import FoundationAI

/// 「AI 状态」页的状态。所有可用性都来自 ModelBroker 的实时检测；不可用时不提供任何替代响应。
@MainActor
@Observable
final class AIStatusModel {
    /// 页面顶部三态。
    enum Headline: Equatable {
        case onDevice
        case cloud
        case unavailable

        var title: String {
            switch self {
            case .onDevice: "设备端"
            case .cloud: "Apple 云端"
            case .unavailable: "AI 当前不可用"
            }
        }
    }

    private(set) var onDevice: ModelAvailability?
    private(set) var cloud: ModelAvailability?
    private(set) var rawOnDevice = ""
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?
    private(set) var hasCloudConsent: Bool

    var selectedBackend: ModelBackend = ModelBroker.defaultBackend
    var prompt = ""
    private(set) var responseText = ""
    private(set) var responseBackend: ModelBackend?
    private(set) var lastFailure: ModelTaskFailure?
    private(set) var wasCancelled = false
    private(set) var isResponding = false

    @ObservationIgnored private let broker: ModelBroker
    @ObservationIgnored private let consent: CloudConsentStore
    @ObservationIgnored private var generation: Task<Void, Never>?

    init(broker: ModelBroker = .live(), consent: CloudConsentStore = .standard) {
        self.broker = broker
        self.consent = consent
        self.hasCloudConsent = consent.hasConsented
    }

    var headline: Headline {
        if onDevice == .available { return .onDevice }
        if cloud == .available && hasCloudConsent { return .cloud }
        return .unavailable
    }

    func availability(of backend: ModelBackend) -> ModelAvailability? {
        switch backend {
        case .onDevice: onDevice
        case .privateCloudCompute: cloud
        // 旧状态页不跟踪 OpenRouter（助手设置内单独显示）。
        case .openRouter: nil
        }
    }

    /// 发送按钮是否可用；不可用时由 `sendBlockReason` 给出原因。
    var canSend: Bool {
        sendBlockReason == nil
    }

    var sendBlockReason: String? {
        if isResponding { return "正在生成" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入内容" }
        guard let availability = availability(of: selectedBackend) else { return "尚未检测" }
        if !availability.isAvailable { return availability.reasonDescription }
        if selectedBackend == .privateCloudCompute && !hasCloudConsent { return "使用 Apple 云端前需要你的确认" }
        return nil
    }

    func refresh() async {
        isChecking = true
        onDevice = await broker.checkAvailability(backend: .onDevice)
        cloud = await broker.checkAvailability(backend: .privateCloudCompute)
        rawOnDevice = OnDeviceModelDriver().rawAvailabilityDescription()
        hasCloudConsent = consent.hasConsented
        lastCheckedAt = Date()
        isChecking = false
    }

    func grantCloudConsent() {
        consent.grantConsent()
        hasCloudConsent = true
    }

    func revokeCloudConsent() {
        consent.revokeConsent()
        hasCloudConsent = false
        if selectedBackend == .privateCloudCompute { selectedBackend = .onDevice }
    }

    func send() {
        guard canSend else { return }
        let request = ModelRequest(prompt: prompt, backend: selectedBackend)
        responseText = ""
        responseBackend = nil
        lastFailure = nil
        wasCancelled = false
        isResponding = true
        generation = Task { [broker] in
            let outcome = await broker.perform(request) { partial in
                await MainActor.run { [weak self] in self?.responseText = partial }
            }
            self.finish(outcome, backend: request.backend)
        }
    }

    func cancel() {
        Task { [broker] in await broker.cancelCurrentTask() }
        generation?.cancel()
    }

    private func finish(_ outcome: ModelTaskOutcome, backend: ModelBackend) {
        isResponding = false
        generation = nil
        switch outcome {
        case let .completed(response):
            responseText = response.text
            responseBackend = response.backend
        case let .failed(failure):
            lastFailure = failure
            // 任务失败反映到可用性（例如 assetsUnavailable → 模型未就绪）；单次拒绝不改变后端可用性。
            if let impact = failure.availabilityImpact, impact != .refused {
                switch backend {
                case .onDevice: onDevice = impact
                case .privateCloudCompute: cloud = impact
                case .openRouter: break
                }
            }
        case .cancelled:
            wasCancelled = true
        }
    }
}
