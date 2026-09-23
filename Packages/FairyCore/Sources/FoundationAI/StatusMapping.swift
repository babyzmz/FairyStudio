import Foundation

/// 设备端模型可用性信号：`SystemLanguageModel.Availability` 的平台无关镜像，
/// 让映射规则可以在不支持 FoundationModels 的宿主（macOS 15）上单测。
public enum OnDeviceAvailabilitySignal: Sendable, Hashable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// SDK 新增、本代码尚未识别的 UnavailableReason（附 String(describing:)）。
    case unrecognized(String)
}

/// `LanguageModelSession.GenerationError` 的 case 镜像；rawValue 与 SDK case 名一致。
public enum GenerationErrorKind: String, CaseIterable, Sendable, Hashable {
    case exceededContextWindowSize
    case assetsUnavailable
    case guardrailViolation
    case unsupportedGuide
    case unsupportedLanguageOrLocale
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case refusal
}

public enum ModelStatusMapping {
    /// 设备端可用性映射。`localeSupported == false` 时即使模型可用也报告 unsupportedLanguage；
    /// nil 表示未检测语言。无法识别的原因一律 unknown。
    public static func availability(from signal: OnDeviceAvailabilitySignal, localeSupported: Bool?) -> ModelAvailability {
        switch signal {
        case .available:
            return localeSupported == false ? .unsupportedLanguage : .available
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceNotEnabled
        case .modelNotReady:
            return .modelNotReady
        case .unrecognized:
            return .unknown
        }
    }

    /// GenerationError → 明确的任务失败状态。
    public static func failure(for kind: GenerationErrorKind, detail: String) -> ModelTaskFailure {
        switch kind {
        case .exceededContextWindowSize: .exceededContextWindowSize(detail)
        case .assetsUnavailable: .assetsUnavailable(detail)
        case .guardrailViolation: .guardrailViolation(detail)
        case .unsupportedGuide: .unsupportedGuide(detail)
        case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale(detail)
        case .decodingFailure: .decodingFailure(detail)
        case .rateLimited: .rateLimited(detail)
        case .concurrentRequests: .concurrentRequests(detail)
        case .refusal: .refusal(detail)
        }
    }
}
