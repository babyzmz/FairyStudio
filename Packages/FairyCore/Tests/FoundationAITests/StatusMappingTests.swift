import Testing
@testable import FoundationAI

@Suite("可用性与错误映射")
struct StatusMappingTests {
    @Test("SystemLanguageModel 可用性每个原因都有明确映射；无法识别时为 unknown")
    func availabilityMapping() {
        #expect(ModelStatusMapping.availability(from: .available, localeSupported: true) == .available)
        #expect(ModelStatusMapping.availability(from: .available, localeSupported: nil) == .available)
        #expect(ModelStatusMapping.availability(from: .available, localeSupported: false) == .unsupportedLanguage)
        #expect(ModelStatusMapping.availability(from: .deviceNotEligible, localeSupported: nil) == .deviceNotEligible)
        #expect(ModelStatusMapping.availability(from: .appleIntelligenceNotEnabled, localeSupported: nil) == .appleIntelligenceNotEnabled)
        #expect(ModelStatusMapping.availability(from: .modelNotReady, localeSupported: nil) == .modelNotReady)
        #expect(ModelStatusMapping.availability(from: .unrecognized("future"), localeSupported: nil) == .unknown)
    }

    @Test("GenerationError 每个 case 映射到不同的明确状态", arguments: GenerationErrorKind.allCases)
    func generationErrorMapping(kind: GenerationErrorKind) {
        let failure = ModelStatusMapping.failure(for: kind, detail: "d")
        let expected: ModelTaskFailure = switch kind {
        case .exceededContextWindowSize: .exceededContextWindowSize("d")
        case .assetsUnavailable: .assetsUnavailable("d")
        case .guardrailViolation: .guardrailViolation("d")
        case .unsupportedGuide: .unsupportedGuide("d")
        case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale("d")
        case .decodingFailure: .decodingFailure("d")
        case .rateLimited: .rateLimited("d")
        case .concurrentRequests: .concurrentRequests("d")
        case .refusal: .refusal("d")
        }
        #expect(failure == expected)
        #expect(!failure.userMessage.isEmpty)
    }

    @Test("GenerationError 映射两两不同，覆盖 SDK 的 9 个 case")
    func generationErrorMappingIsInjective() {
        let failures = GenerationErrorKind.allCases.map { ModelStatusMapping.failure(for: $0, detail: "x") }
        #expect(Set(failures).count == GenerationErrorKind.allCases.count)
        #expect(GenerationErrorKind.allCases.count == 9)
    }

    @Test("失败对可用性的影响")
    func availabilityImpact() {
        #expect(ModelTaskFailure.assetsUnavailable("").availabilityImpact == .modelNotReady)
        #expect(ModelTaskFailure.rateLimited("").availabilityImpact == .quotaExhausted)
        #expect(ModelTaskFailure.unsupportedLanguageOrLocale("").availabilityImpact == .unsupportedLanguage)
        #expect(ModelTaskFailure.refusal("").availabilityImpact == .refused)
        #expect(ModelTaskFailure.guardrailViolation("").availabilityImpact == .refused)
        #expect(ModelTaskFailure.exceededContextWindowSize("").availabilityImpact == nil)
        #expect(ModelTaskFailure.unavailable(.pccSDKMissing).availabilityImpact == .pccSDKMissing)
    }

    @Test("可用性状态码唯一且说明非空")
    func availabilityCodesAreDistinct() {
        let all: [ModelAvailability] = [
            .available, .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedLanguage,
            .regionOrAccountRestricted, .pccNotEntitled, .pccSDKMissing, .noNetwork, .quotaExhausted, .refused,
            .systemError("x"), .unknown,
        ]
        #expect(Set(all.map(\.code)).count == all.count)
        #expect(all.allSatisfy { !$0.reasonDescription.isEmpty })
        #expect(all.filter(\.isAvailable) == [.available])
    }

    @Test("PCC 后端在当前 SDK 下固定报告 pccSDKMissing，且不产出内容")
    func pccIsMissing() async throws {
        let driver = PrivateCloudComputeDriver()
        #expect(await driver.checkAvailability() == .pccSDKMissing)
        var received: [String] = []
        do {
            for try await chunk in driver.streamResponse(to: ModelRequest(prompt: "hi", backend: .privateCloudCompute)) {
                received.append(chunk)
            }
            Issue.record("PCC 流不应成功结束")
        } catch let failure as ModelTaskFailure {
            #expect(failure == .unavailable(.pccSDKMissing))
        }
        #expect(received.isEmpty)
    }

    @Test("设备端后端在本宿主上的真实可用性（记录值，不假设可用）")
    func onDeviceRealAvailability() async {
        let driver = OnDeviceModelDriver()
        let availability = await driver.checkAvailability()
        print("[FoundationAITests] 宿主 OnDevice availability = \(availability.code) (\(availability.reasonDescription)); raw = \(driver.rawAvailabilityDescription())")
        #expect(!availability.code.isEmpty)
    }
}
