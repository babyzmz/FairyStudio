import Foundation
import FoundationAI
import Observation

/// 应用级助手设置（计划 §5.3 / §8.3）：后端、更新策略、OpenRouter 配置。
/// 首页设置入口与各工作区会话共享同一实例；写操作持久化到 UserDefaults。
@MainActor
@Observable
final class AssistantSettingsModel {
    static let shared = AssistantSettingsModel()

    private let defaults: UserDefaults
    let openRouterConsent: OpenRouterConsentStore
    let openRouterKeyStore: any APIKeyStoring

    init(defaults: UserDefaults = .standard,
         openRouterConsent: OpenRouterConsentStore = .standard,
         openRouterKeyStore: any APIKeyStoring = InMemoryAPIKeyStore()) {
        self.defaults = defaults
        self.openRouterConsent = openRouterConsent
        self.openRouterKeyStore = openRouterKeyStore
        backend = ModelBackend(rawValue: defaults.string(forKey: "fairy.ai.backend") ?? "") ?? .onDevice
        updateStrategy = UpdateStrategy(rawValue: defaults.string(forKey: "fairy.ai.updateStrategy") ?? "")
            ?? .autoCompatible
        openRouterModelID = defaults.string(forKey: "fairy.ai.openRouter.model") ?? OpenRouterCatalog.defaultModelID
    }

    var backend: ModelBackend {
        didSet { defaults.set(backend.rawValue, forKey: "fairy.ai.backend") }
    }

    var updateStrategy: UpdateStrategy {
        didSet { defaults.set(updateStrategy.rawValue, forKey: "fairy.ai.updateStrategy") }
    }

    var openRouterModelID: String {
        didSet { defaults.set(openRouterModelID, forKey: "fairy.ai.openRouter.model") }
    }

    var isOpenRouterEnabled: Bool { openRouterConsent.hasConsented }

    func setOpenRouterEnabled(_ on: Bool) {
        if on {
            openRouterConsent.grantConsent()
        } else {
            openRouterConsent.revokeConsent()
            if backend == .openRouter { backend = .onDevice }
        }
    }
}
