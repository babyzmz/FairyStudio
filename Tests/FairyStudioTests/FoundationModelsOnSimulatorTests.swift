import Testing
import Foundation
import FoundationAI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 在 iOS 模拟器上（FoundationModels 框架存在）验证 SDK 类型 → 镜像的映射，并记录真实可用性。
@Suite("FoundationModels（iOS 运行时）")
struct FoundationModelsOnSimulatorTests {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func allGenerationErrors() -> [(LanguageModelSession.GenerationError, ModelTaskFailure)] {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "ctx")
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        return [
            (.exceededContextWindowSize(context), .exceededContextWindowSize("ctx")),
            (.assetsUnavailable(context), .assetsUnavailable("ctx")),
            (.guardrailViolation(context), .guardrailViolation("ctx")),
            (.unsupportedGuide(context), .unsupportedGuide("ctx")),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguageOrLocale("ctx")),
            (.decodingFailure(context), .decodingFailure("ctx")),
            (.rateLimited(context), .rateLimited("ctx")),
            (.concurrentRequests(context), .concurrentRequests("ctx")),
            (.refusal(refusal, context), .refusal("ctx")),
        ]
    }

    @Test("GenerationError 的 9 个 SDK case 逐一映射为明确状态")
    func generationErrorsMapFromSDK() throws {
        guard #available(iOS 26.0, *) else { return }
        let cases = Self.allGenerationErrors()
        #expect(cases.count == GenerationErrorKind.allCases.count)
        for (error, expected) in cases {
            #expect(FoundationModelsBridge.failure(for: error) == expected)
        }
    }

    @Test("UnavailableReason 的 3 个 SDK case 逐一映射")
    func availabilityMapsFromSDK() {
        guard #available(iOS 26.0, *) else { return }
        #expect(FoundationModelsBridge.signal(from: .available) == .available)
        #expect(FoundationModelsBridge.signal(from: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(FoundationModelsBridge.signal(from: .unavailable(.appleIntelligenceNotEnabled)) == .appleIntelligenceNotEnabled)
        #expect(FoundationModelsBridge.signal(from: .unavailable(.modelNotReady)) == .modelNotReady)
    }
    #endif

    @Test("记录本环境 SystemLanguageModel.default 的真实可用性")
    func recordRealAvailability() async {
        let driver = OnDeviceModelDriver()
        let mapped = await driver.checkAvailability()
        let raw = driver.rawAvailabilityDescription()
        let line = "[FAIRY-AVAILABILITY] mapped=\(mapped.code) reason=\(mapped.reasonDescription) raw=\(raw)"
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        #expect(!raw.isEmpty)
    }
}
