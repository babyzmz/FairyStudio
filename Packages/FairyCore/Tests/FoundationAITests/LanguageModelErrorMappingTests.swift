import Foundation
import Testing
import FoundationModels
@testable import FoundationAI

// iOS 27 起 FoundationModels 把上下文超限等错误改从 LanguageModelError 抛出。
// 若不映射，`exceededContextWindowSize` 退避永不触发，实机会直接看到
// "系统错误（provided N token, maximum allowed is 4096）"。本套件锁定映射行为。

@Suite("iOS 27 LanguageModelError 映射")
struct LanguageModelErrorMappingTests {
    @Test("contextSizeExceeded → exceededContextWindowSize（退避可识别）")
    func contextSizeExceededMapsToBackoff() throws {
        guard #available(macOS 27.0, *) else {
            Issue.record("宿主需 macOS 27 才能构造 LanguageModelError")
            return
        }
        let context = LanguageModelError.ContextSizeExceeded(
            contextSize: 4096, tokenCount: 4107,
            debugDescription: "provided 4107 token, maximum allowed is 4096")
        let failure = FoundationModelsBridge.failure(for: .contextSizeExceeded(context))
        guard case let .exceededContextWindowSize(detail) = failure else {
            Issue.record("期望 exceededContextWindowSize，实际 \(failure)")
            return
        }
        #expect(detail.contains("4107"))
        #expect(detail.contains("4096"))
        #expect(failure.isContextOverflow)
    }
}
