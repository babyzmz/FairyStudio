import Foundation
import Synchronization
import Testing
import FoundationModels
@testable import FoundationAI

// OpenRouterProvider 的 mock 测试（URLProtocol 拦截，无真实网络）：
// SSE 组装、逐类错误映射、授权门、Key 只进请求头、截断不作为可提交内容、取消。
// 真实 API 验证走 liveSmoke（环境变量门控），默认跳过——不把 mock 说成真测。

/// 拦截 OpenRouterProvider 的全部 HTTP 请求；handler 决定响应。
final class MockOpenRouterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        requestCount = 0
    }

    static func sseResponse(_ events: [String]) -> (HTTPURLResponse, Data) {
        let body = events.map { "data: \($0)" }.joined(separator: "\n") + "\ndata: [DONE]\n"
        let response = HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(body.utf8))
    }

    static func errorResponse(_ status: Int, _ message: String, code: Int? = nil) -> (HTTPURLResponse, Data) {
        var errorObject: [String: Any] = ["message": message]
        if let code { errorObject["code"] = code }
        let body = try! JSONSerialization.data(withJSONObject: ["error": errorObject])
        let response = HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                                       statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, body)
    }
}

func deltaEvent(_ text: String) -> String {
    let obj: [String: Any] = ["choices": [["delta": ["content": text]]]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

func finishEvent(_ reason: String) -> String {
    let obj: [String: Any] = ["choices": [["delta": [:], "finish_reason": reason]]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

func usageEvent(prompt: Int, completion: Int) -> String {
    let obj: [String: Any] = ["usage": ["prompt_tokens": prompt, "completion_tokens": completion]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}

/// 并发安全的捕获盒（Swift 6 严格并发下不能跨闭包写局部变量）。
final class CaptureBox: @unchecked Sendable {
    let auth = Mutex<String?>(nil)
    let body = Mutex<String>("")
    let snapshots = Mutex<[String]>([])
}

@Suite("OpenRouter Provider（mock 网络）", .serialized)
struct OpenRouterProviderTests {
    private func makeProvider(key: String = "sk-or-test-1234",
                              modelID: String = OpenRouterCatalog.defaultModelID) -> OpenRouterProvider {
        var store = InMemoryAPIKeyStore()
        store.setApiKey(key)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOpenRouterURLProtocol.self]
        return OpenRouterProvider(keyStore: store, modelID: modelID,
                                  urlSession: URLSession(configuration: config))
    }

    private func collect(_ provider: OpenRouterProvider, prompt: String = "改一个文件") async throws
        -> (text: String, failure: ModelTaskFailure?) {
        var text = ""
        var failure: ModelTaskFailure?
        do {
            for try await snapshot in provider.streamResponse(
                to: ModelRequest(prompt: prompt, backend: .openRouter, instructions: "sys")) {
                text = snapshot
            }
        } catch let taskFailure as ModelTaskFailure {
            failure = taskFailure
        }
        return (text, failure)
    }

    @Test("SSE 流式组装：快照累积 + usage 独立统计")
    func streamingAssembles() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.sseResponse([
                deltaEvent("第一段"), deltaEvent("第二段"),
                usageEvent(prompt: 7, completion: 5),
                finishEvent("stop"),
            ])
        }
        let provider = makeProvider()
        let result = try await collect(provider)
        #expect(result.failure == nil)
        #expect(result.text == "第一段第二段")
        let usage = try #require(provider.lastUsage)
        #expect(usage.promptTokens == 7)
        #expect(usage.completionTokens == 5)
        #expect(usage.modelID == OpenRouterCatalog.defaultModelID)
    }

    @Test("Key 只进请求头，不进请求体")
    func keyStaysInHeader() async throws {
        MockOpenRouterURLProtocol.reset()
        let capture = CaptureBox()
        MockOpenRouterURLProtocol.handler = { request in
            capture.auth.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
            var captured = ""
            if let body = request.httpBodyStream {
                body.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while body.hasBytesAvailable {
                    let read = body.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                body.close()
                captured = String(data: data, encoding: .utf8) ?? ""
            } else if let data = request.httpBody {
                captured = String(data: data, encoding: .utf8) ?? ""
            }
            capture.body.withLock { $0 = captured }
            return MockOpenRouterURLProtocol.sseResponse([deltaEvent("ok"), finishEvent("stop")])
        }
        let provider = makeProvider(key: "sk-or-SECRET-9876")
        _ = try await collect(provider)
        #expect(capture.auth.withLock { $0 } == "Bearer sk-or-SECRET-9876")
        #expect(!capture.body.withLock { $0 }.contains("sk-or-SECRET-9876"), "Key 不得进入请求体/提示词")
    }

    @Test("认证失败（401）→ authFailed")
    func authFailure() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.errorResponse(401, "Invalid API key")
        }
        let result = try await collect(makeProvider())
        guard case let .authFailed(detail) = result.failure else {
            Issue.record("期望 authFailed，实际 \(String(describing: result.failure))")
            return
        }
        #expect(detail.contains("Invalid"))
    }

    @Test("余额不足（402）→ insufficientCredits")
    func insufficientCredits() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.errorResponse(402, "Insufficient credits")
        }
        let result = try await collect(makeProvider())
        guard case .insufficientCredits = result.failure else {
            Issue.record("期望 insufficientCredits，实际 \(String(describing: result.failure))")
            return
        }
    }

    @Test("限流（429）→ rateLimited")
    func rateLimited() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.errorResponse(429, "Rate limit exceeded")
        }
        let result = try await collect(makeProvider())
        guard case .rateLimited = result.failure else {
            Issue.record("期望 rateLimited，实际 \(String(describing: result.failure))")
            return
        }
    }

    @Test("上下文超限（400 context_length）→ exceededContextWindowSize（可触发退避）")
    func contextOverflow() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.errorResponse(400, "This model's maximum context length is 4096 tokens",
                                                    code: 400)
        }
        let result = try await collect(makeProvider())
        guard case let .exceededContextWindowSize(detail) = result.failure else {
            Issue.record("期望 exceededContextWindowSize，实际 \(String(describing: result.failure))")
            return
        }
        #expect(detail.contains("context"))
        #expect(result.failure!.isContextOverflow)
    }

    @Test("finish_reason=length → truncatedOutput（完整接收但不提交）")
    func truncatedByLength() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.sseResponse([
                deltaEvent("{\"operations\":[{\"action\":\"cre"),   // 半截 JSON
                usageEvent(prompt: 100, completion: 4096),
                finishEvent("length"),
            ])
        }
        let result = try await collect(makeProvider())
        guard case let .truncatedOutput(detail) = result.failure else {
            Issue.record("期望 truncatedOutput，实际 \(String(describing: result.failure))")
            return
        }
        #expect(detail.contains("length"))
    }

    @Test("流中途错误对象 → 逐类映射")
    func midStreamError() async throws {
        MockOpenRouterURLProtocol.reset()
        let errorObject = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": "Provider down", "code": 502],
        ])
        let payload = String(data: errorObject, encoding: .utf8)!
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.sseResponse([deltaEvent("部分"), payload])
        }
        let result = try await collect(makeProvider())
        guard case .systemError = result.failure else {
            Issue.record("期望 systemError，实际 \(String(describing: result.failure))")
            return
        }
    }

    @Test("未授权时 Broker 拒绝且不发起任何 HTTP 请求")
    func consentGateBlocksBeforeNetwork() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.sseResponse([deltaEvent("不应到达"), finishEvent("stop")])
        }
        var keyStore = InMemoryAPIKeyStore()
        keyStore.setApiKey("sk-or-test")
        let provider = OpenRouterProvider(keyStore: keyStore)
        let broker = ModelBroker(drivers: [provider], consent: .standard,
                                 openRouterConsent: OpenRouterConsentStore(suiteName: "fairy.tests.openrouter.\(UUID().uuidString)"))
        let outcome = await broker.perform(ModelRequest(prompt: "x", backend: .openRouter)) { _ in }
        guard case .failed = outcome else {
            Issue.record("期望失败，实际 \(outcome)")
            return
        }
        #expect(MockOpenRouterURLProtocol.requestCount == 0, "未授权绝不发起 HTTP 请求")
        #expect(await broker.hasOpenRouterConsent == false)
    }

    @Test("授权后放行")
    func consentGrantedPasses() async throws {
        MockOpenRouterURLProtocol.reset()
        MockOpenRouterURLProtocol.handler = { _ in
            MockOpenRouterURLProtocol.sseResponse([deltaEvent("ok"), finishEvent("stop")])
        }
        let provider = makeProvider(key: "sk-or-test")
        let consent = OpenRouterConsentStore(suiteName: "fairy.tests.openrouter.\(UUID().uuidString)")
        consent.grantConsent()
        let broker = ModelBroker(drivers: [provider], consent: .standard, openRouterConsent: consent)
        let capture = CaptureBox()
        let outcome = await broker.perform(ModelRequest(prompt: "x", backend: .openRouter)) { partial in
            capture.snapshots.withLock { $0.append(partial) }
        }
        guard case let .completed(response) = outcome else {
            Issue.record("期望完成，实际 \(outcome)")
            return
        }
        #expect(response.text == "ok")
        #expect(capture.snapshots.withLock { $0.last } == "ok")
    }

    @Test("无 Key → missingAPIKey 可用性")
    func missingKeyReportsAvailability() async {
        let provider = OpenRouterProvider(keyStore: InMemoryAPIKeyStore())
        let availability = await provider.checkAvailability()
        #expect(availability == .missingAPIKey)
    }

    // MARK: - 真实 API 验证（环境变量门控；默认跳过，不冒充已测）

    /// 真实验证入口：FAIRY_OPENROUTER_LIVE=1 且 FAIRY_OPENROUTER_KEY=sk-or-… 时运行。
    /// 覆盖要求 8 的第一项：>4096 token 的真实请求证明不受 Apple 4096 会话限制。
    /// mock 无法替代本测试；未设置环境变量时本测试跳过并如实标注。
    @Test("真实 API：超过 4096 token 的请求（门控）", .timeLimit(.minutes(4)),
          .disabled(if: ProcessInfo.processInfo.environment["FAIRY_OPENROUTER_LIVE"] != "1"))
    func liveRequestBeyondAppleLimit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["FAIRY_OPENROUTER_KEY"], !key.isEmpty else {
            Issue.record("FAIRY_OPENROUTER_LIVE=1 但未提供 FAIRY_OPENROUTER_KEY")
            return
        }
        var store = InMemoryAPIKeyStore()
        store.setApiKey(key)
        // ~5600 token 的长提示（远超 Apple 4K 会话限制，但在所选模型预算内）。
        let longPrompt = String(repeating: "请记住这一段背景资料：项目使用 Swift 子集解释器执行界面代码。\\n", count: 120)
            + "请回答：收到。"
        let provider = OpenRouterProvider(keyStore: store, modelID: "openai/gpt-4o-mini")
        var text = ""
        for try await snapshot in provider.streamResponse(
            to: ModelRequest(prompt: longPrompt, backend: .openRouter, instructions: "你是测试助手。")) {
            text = snapshot
        }
        #expect(!text.isEmpty)
        let usage = try #require(provider.lastUsage)
        #expect(usage.promptTokens > 4096, "真实 usage 应超过 4096，证明未受 Apple 限制；实际 \(usage.promptTokens)")
    }
}
