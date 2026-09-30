import Foundation

/// 模型后端：Apple 设备端 / Apple 云端（PCC）/ OpenRouter（用户自行配置的第三方云端）。
/// 后端之间绝不自动回退；第三方后端必须单独授权（见 OpenRouterConsentStore）。
public enum ModelBackend: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    case onDevice
    case privateCloudCompute
    case openRouter

    public var id: String { rawValue }

    /// 界面显示名（真实后端名，不做营销化包装）。
    public var displayName: String {
        switch self {
        case .onDevice: "设备端（Apple Foundation Models）"
        case .privateCloudCompute: "Apple 云端（Private Cloud Compute）"
        case .openRouter: "OpenRouter（用户自配云端）"
        }
    }

    public var shortName: String {
        switch self {
        case .onDevice: "设备端"
        case .privateCloudCompute: "Apple 云端"
        case .openRouter: "OpenRouter"
        }
    }
}

/// 后端可用性。无法判断原因时必须返回 `.unknown`，不得猜测。
public enum ModelAvailability: Sendable, Hashable, Codable {
    case available
    /// 设备不支持 Apple Intelligence（SystemLanguageModel.UnavailableReason.deviceNotEligible）。
    case deviceNotEligible
    /// 用户未开启 Apple Intelligence（.appleIntelligenceNotEnabled）。
    case appleIntelligenceNotEnabled
    /// 模型资源未就绪 / 下载中（.modelNotReady，或生成时 assetsUnavailable）。
    case modelNotReady
    /// 当前语言或地区设置不受模型支持（supportsLocale == false，或 unsupportedLanguageOrLocale）。
    case unsupportedLanguage
    /// 地区或账户限制（当前 SDK 无对应公开信号；保留给 PCC / 未来 SDK）。
    case regionOrAccountRestricted
    /// App 未获得 PCC 使用资格（entitlement 待官方文档核对）。
    case pccNotEntitled
    /// 当前 SDK 不含 PCC API（编译条件 FAIRY_PCC_SDK 未定义）。
    case pccSDKMissing
    /// 网络不可用（仅云端后端适用）。
    case noNetwork
    /// 配额耗尽或被限流（GenerationError.rateLimited）。
    case quotaExhausted
    /// 模型拒绝（refusal / guardrailViolation）。
    case refused
    /// 系统错误（附原始描述）。
    case systemError(String)
    /// 未配置第三方后端（OpenRouter）的 API Key。
    case missingAPIKey
    /// 第三方后端（OpenRouter）尚未获得用户授权。
    case thirdPartyNotAuthorized
    /// 无法判断原因。
    case unknown

    public var isAvailable: Bool { self == .available }

    /// 面向用户的具体原因说明。
    public var reasonDescription: String {
        switch self {
        case .available: "可用"
        case .deviceNotEligible: "此设备不支持 Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence 未开启（设置 → Apple Intelligence 与 Siri）"
        case .modelNotReady: "模型尚未就绪（可能正在下载），请稍后重新检测"
        case .unsupportedLanguage: "当前语言或地区不受模型支持"
        case .regionOrAccountRestricted: "当前地区或账户不支持此功能"
        case .pccNotEntitled: "App 尚未获得 Apple 云端（Private Cloud Compute）使用资格"
        case .pccSDKMissing: "当前 SDK 不含 Apple 云端（Private Cloud Compute）接口，需要 Xcode 27 / iOS 27 SDK"
        case .noNetwork: "网络不可用，Apple 云端无法访问"
        case .quotaExhausted: "请求过于频繁或配额已用尽，请稍后再试"
        case .refused: "模型拒绝了该请求"
        case let .systemError(detail): "系统错误：\(detail)"
        case .missingAPIKey: "未配置 OpenRouter API Key（助手设置 → OpenRouter）"
        case .thirdPartyNotAuthorized: "尚未授权将内容发送至 OpenRouter（助手设置 → OpenRouter）"
        case .unknown: "原因未知（系统未给出可识别的状态）"
        }
    }

    /// 稳定的机器可读标识（日志 / 测试 / 文档）。
    public var code: String {
        switch self {
        case .available: "available"
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .unsupportedLanguage: "unsupportedLanguage"
        case .regionOrAccountRestricted: "regionOrAccountRestricted"
        case .pccNotEntitled: "pccNotEntitled"
        case .pccSDKMissing: "pccSDKMissing"
        case .noNetwork: "noNetwork"
        case .quotaExhausted: "quotaExhausted"
        case .refused: "refused"
        case .systemError: "systemError"
        case .missingAPIKey: "missingAPIKey"
        case .thirdPartyNotAuthorized: "thirdPartyNotAuthorized"
        case .unknown: "unknown"
        }
    }
}

/// 一次模型请求。后端必须显式指定：Broker 绝不在后端之间自动回退（本地模式绝不静默上传）。
public struct ModelRequest: Sendable, Hashable {
    public var prompt: String
    public var backend: ModelBackend
    public var instructions: String?

    public init(prompt: String, backend: ModelBackend = ModelBroker.defaultBackend, instructions: String? = nil) {
        self.prompt = prompt
        self.backend = backend
        self.instructions = instructions
    }
}

public struct ModelResponse: Sendable, Hashable {
    public var text: String
    /// 实际完成本次请求的后端。
    public var backend: ModelBackend

    public init(text: String, backend: ModelBackend) {
        self.text = text
        self.backend = backend
    }
}

/// 模型任务失败的明确状态。每个 GenerationError case 都有一一对应的状态。
public enum ModelTaskFailure: Error, Sendable, Hashable {
    /// 任务开始时的能力检测结果为不可用。
    case unavailable(ModelAvailability)
    /// 云端后端尚未获得用户确认。
    case cloudConsentRequired
    /// 已有任务在途（单在途）。
    case busy
    case exceededContextWindowSize(String)
    case assetsUnavailable(String)
    case guardrailViolation(String)
    case unsupportedGuide(String)
    case unsupportedLanguageOrLocale(String)
    case decodingFailure(String)
    case rateLimited(String)
    case concurrentRequests(String)
    case refusal(String)
    /// SDK 新增、本代码尚未识别的 GenerationError。
    case unrecognizedGenerationError(String)
    case systemError(String)
    /// 第三方后端认证失败（如 OpenRouter 401）。
    case authFailed(String)
    /// 第三方后端余额或额度不足（如 OpenRouter 402）。
    case insufficientCredits(String)
    /// 第三方流式输出被截断或以 length/error 结束：完整接收但不得自动提交。
    case truncatedOutput(String)
    /// 第三方端点返回不兼容的响应结构。
    case endpointIncompatible(String)

    /// 该失败对后端可用性的含义（用于刷新 AI 状态页）；nil 表示不改变可用性判断。
    public var availabilityImpact: ModelAvailability? {
        switch self {
        case let .unavailable(availability): availability
        case .assetsUnavailable: .modelNotReady
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .rateLimited: .quotaExhausted
        case .guardrailViolation, .refusal: .refused
        case .cloudConsentRequired, .busy, .exceededContextWindowSize, .unsupportedGuide, .decodingFailure,
             .concurrentRequests, .unrecognizedGenerationError, .systemError,
             .authFailed, .insufficientCredits, .truncatedOutput, .endpointIncompatible: nil
        }
    }

    public var userMessage: String {
        switch self {
        case let .unavailable(availability): "AI 不可用：\(availability.reasonDescription)"
        case .cloudConsentRequired: "使用云端后端前需要你的确认（助手设置）"
        case .busy: "已有一个请求正在进行，请等待完成或取消"
        case let .exceededContextWindowSize(detail): "内容超出模型上下文容量，请缩短输入（\(detail)）"
        case let .assetsUnavailable(detail): "模型资源不可用（\(detail)）"
        case let .guardrailViolation(detail): "请求触发了安全护栏（\(detail)）"
        case let .unsupportedGuide(detail): "不支持的生成约束（\(detail)）"
        case let .unsupportedLanguageOrLocale(detail): "不支持的语言或地区（\(detail)）"
        case let .decodingFailure(detail): "模型输出解码失败（\(detail)）"
        case let .rateLimited(detail): "请求被限流（\(detail)）"
        case let .concurrentRequests(detail): "同一会话存在并发请求（\(detail)）"
        case let .refusal(detail): "模型拒绝回答（\(detail)）"
        case let .unrecognizedGenerationError(detail): "未识别的生成错误（\(detail)）"
        case let .systemError(detail): "系统错误（\(detail)）"
        case let .authFailed(detail): "OpenRouter 认证失败：请检查 API Key（\(detail)）"
        case let .insufficientCredits(detail): "OpenRouter 余额或额度不足（\(detail)）"
        case let .truncatedOutput(detail): "模型输出被截断（\(detail)）；本轮不应用，请重试或换模型"
        case let .endpointIncompatible(detail): "OpenRouter 端点返回不兼容的响应（\(detail)）"
        }
    }
}

public enum ModelTaskOutcome: Sendable, Hashable {
    case completed(ModelResponse)
    case failed(ModelTaskFailure)
    case cancelled
}
