import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 设备端后端：Apple Foundation Models（SystemLanguageModel + LanguageModelSession）。
/// 签名已对照 iOS 26.2 SDK 的 FoundationModels.swiftinterface 核实（见 docs/APPLE_MODELS.md）。
public struct OnDeviceModelDriver: ModelBackendDriver {
    public let backend = ModelBackend.onDevice

    public init() {}

    public func checkAvailability() async -> ModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            let signal = FoundationModelsBridge.signal(from: model.availability)
            let localeSupported: Bool? = signal == .available ? model.supportsLocale(Locale.current) : nil
            return ModelStatusMapping.availability(from: signal, localeSupported: localeSupported)
        }
        return .systemError("系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用")
        #else
        return .systemError("当前 SDK 不含 FoundationModels 框架")
        #endif
    }

    public func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return FoundationModelsBridge.stream(prompt: request.prompt, instructions: request.instructions)
        }
        return Self.failedStream(.systemError("系统版本低于 iOS 26 / macOS 26，FoundationModels 不可用"))
        #else
        return Self.failedStream(.systemError("当前 SDK 不含 FoundationModels 框架"))
        #endif
    }

    /// 读取系统原始可用性值（未映射），用于在模拟器 / 实机记录真实返回值。
    public func rawAvailabilityDescription() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel.default
            return "availability=\(String(describing: model.availability)); supportsLocale(\(Locale.current.identifier))=\(model.supportsLocale(Locale.current))"
        }
        return "系统版本低于 26"
        #else
        return "SDK 不含 FoundationModels"
        #endif
    }
}

#if canImport(FoundationModels)
/// FoundationModels 类型 → 平台无关镜像的转换。只在这里接触 SDK 类型。
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum FoundationModelsBridge {
    public static func signal(from availability: SystemLanguageModel.Availability) -> OnDeviceAvailabilitySignal {
        switch availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unrecognized(String(describing: reason))
            }
        }
    }

    /// GenerationError → 镜像 case；SDK 新增 case 返回 nil。
    public static func kind(of error: LanguageModelSession.GenerationError) -> GenerationErrorKind? {
        switch error {
        case .exceededContextWindowSize: .exceededContextWindowSize
        case .assetsUnavailable: .assetsUnavailable
        case .guardrailViolation: .guardrailViolation
        case .unsupportedGuide: .unsupportedGuide
        case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale
        case .decodingFailure: .decodingFailure
        case .rateLimited: .rateLimited
        case .concurrentRequests: .concurrentRequests
        case .refusal: .refusal
        @unknown default: nil
        }
    }

    public static func failure(for error: LanguageModelSession.GenerationError) -> ModelTaskFailure {
        let detail = debugDetail(of: error)
        guard let kind = kind(of: error) else {
            return .unrecognizedGenerationError(detail)
        }
        return ModelStatusMapping.failure(for: kind, detail: detail)
    }

    private static func debugDetail(of error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case let .exceededContextWindowSize(context), let .assetsUnavailable(context), let .guardrailViolation(context),
             let .unsupportedGuide(context), let .unsupportedLanguageOrLocale(context), let .decodingFailure(context),
             let .rateLimited(context), let .concurrentRequests(context):
            return context.debugDescription
        case let .refusal(_, context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    /// 每次请求新建会话（M0 无多轮上下文）。消费方取消 → onTermination 取消内部任务 → 停止生成。
    static func stream(prompt: String, instructions: String?) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session: LanguageModelSession
                    if let instructions {
                        session = LanguageModelSession(instructions: instructions)
                    } else {
                        session = LanguageModelSession()
                    }
                    guard !session.isResponding else {
                        continuation.finish(throwing: ModelTaskFailure.concurrentRequests("会话已有在途请求"))
                        return
                    }
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: failure(for: error))
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ModelTaskFailure.systemError(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
