import Foundation
import Synchronization

// OpenRouter 云端后端（用户自行配置 Key 的可选云端，Apple PCC 尚未获批期间的替代路径）。
// 策略（2026-09-28 产品调整）：
// - 独立 HTTP 通道（/api/v1/chat/completions，SSE 流式），绝不经过 Apple 本地模型或其
//   LanguageModelSession，因此不继承 Apple 的 4096 上下文限制；token 预算按所选模型独立管理，
//   统计量来自响应中的真实 usage 字段（请求 usage.include），不用 Apple tokenizer。
// - 授权门：未经 OpenRouterConsentStore 授权（ModelBroker 检查）绝不发起请求。
// - Key 只经 APIKeyStoring（App 侧实现为 Keychain）进 HTTP 头；不进源码、日志、提示词或解释器。
// - 错误逐类解析（认证/余额/限流/上下文超限/端点不兼容/流中断），绝不无条件重试。
// - finish_reason 为 length / error 或流中断：完整接收后抛 truncatedOutput，管线不得自动提交。

/// OpenRouter API Key 存储抽象。生产实现为 Keychain（App 侧）；测试用内存实现。
public protocol APIKeyStoring: Sendable {
    func apiKey() -> String?
    /// 保存 Key；返回 nil = 成功，非 nil = 面向用户的错误描述（如 Keychain 写入失败）。
    @discardableResult
    mutating func setApiKey(_ key: String) -> String?
    /// 删除 Key；返回 nil = 成功，非 nil = 错误描述。
    @discardableResult
    mutating func deleteApiKey() -> String?
}

/// 测试与无 Key 环境的内存实现（App 生产用 Keychain 实现）。
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let key = Mutex<String?>(nil)
    public init() {}
    public func apiKey() -> String? { key.withLock { $0 } }
    public func setApiKey(_ key: String) -> String? { self.key.withLock { $0 = key; return nil } }
    public func deleteApiKey() -> String? { self.key.withLock { $0 = nil; return nil } }
}

/// OpenRouter 使用授权：独立于 Apple 云端确认，默认拒绝。
public struct OpenRouterConsentStore: Sendable {
    static let consentKey = "fairy.ai.openRouter.consent.v1"
    static let consentDateKey = "fairy.ai.openRouter.consentDate.v1"

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public static let standard = OpenRouterConsentStore()

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    public var hasConsented: Bool {
        defaults.bool(forKey: Self.consentKey)
    }

    public var consentDate: Date? {
        defaults.object(forKey: Self.consentDateKey) as? Date
    }

    public func grantConsent(at date: Date = Date()) {
        defaults.set(true, forKey: Self.consentKey)
        defaults.set(date, forKey: Self.consentDateKey)
    }

    public func revokeConsent() {
        defaults.removeObject(forKey: Self.consentKey)
        defaults.removeObject(forKey: Self.consentDateKey)
    }
}

/// 模型条目。上下文/输出上限由实时目录（/api/v1/models）核对后填充——不在代码里编造数字。
public struct OpenRouterModelInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public var contextLength: Int?
    public var maxOutput: Int?

    public init(id: String, displayName: String, contextLength: Int? = nil, maxOutput: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.contextLength = contextLength
        self.maxOutput = maxOutput
    }
}

public enum OpenRouterCatalog {
    /// 用户指定的模型清单（2026-09-30）。维度数字一律以实时目录核对为准。
    public static let verified: [OpenRouterModelInfo] = [
        OpenRouterModelInfo(id: "z-ai/glm-5.3-flash", displayName: "GLM-5.3 Flash"),
        OpenRouterModelInfo(id: "deepseek/deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash"),
        OpenRouterModelInfo(id: "openai/gpt-6-luna-pro", displayName: "GPT-6 Luna Pro"),
        OpenRouterModelInfo(id: "openai/gpt-6-luna", displayName: "GPT-6 Luna"),
        OpenRouterModelInfo(id: "xiaomi/mimo-v2.6-flash", displayName: "MiMo V2.6 Flash"),
        OpenRouterModelInfo(id: "xiaomi/mimo-v2.6-pro", displayName: "MiMo V2.6 Pro"),
        OpenRouterModelInfo(id: "nvidia/nemotron-3-ultra-550b-a55b:free", displayName: "Nemotron 3 Ultra 550B（免费）"),
    ]

    public static func info(for id: String) -> OpenRouterModelInfo? {
        verified.first { $0.id == id }
    }

    public static let defaultModelID = "z-ai/glm-5.3-flash"
}

/// OpenRouter 流式生成驱动。无状态除所选模型外；模型切换经 `selectModel`（Mutex 保护）。
public final class OpenRouterProvider: ModelBackendDriver, @unchecked Sendable {
    public let backend = ModelBackend.openRouter

    static let endpoint = "https://openrouter.ai/api/v1/chat/completions"
    static let modelsEndpoint = "https://openrouter.ai/api/v1/models"

    private let keyStore: any APIKeyStoring
    private let modelID: Mutex<String>
    private let urlSession: URLSession
    /// 最近一次请求的真实 token 统计（来自响应 usage.include），按所选模型独立口径。
    public private(set) var lastUsage: OpenRouterUsage?

    public init(keyStore: any APIKeyStoring, modelID: String = OpenRouterCatalog.defaultModelID,
                urlSession: URLSession = .shared) {
        self.keyStore = keyStore
        self.modelID = Mutex(modelID)
        self.urlSession = urlSession
    }

    public func selectModel(_ id: String) {
        modelID.withLock { $0 = id }
    }

    public var selectedModelID: String {
        modelID.withLock { $0 }
    }

    public func checkAvailability() async -> ModelAvailability {
        guard keyStore.apiKey()?.isEmpty == false else { return .missingAPIKey }
        return .available
    }

    /// 最近一次请求的实际 token 统计。
    public struct OpenRouterUsage: Sendable, Hashable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var modelID: String
    }

    public func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(request: request) { snapshot in
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch let failure as ModelTaskFailure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let urlError as URLError where urlError.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ModelTaskFailure.systemError(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 连接测试：最小完成请求（真实调用，验证 Key 与端点）。
    public func testConnection() async -> ModelAvailability {
        do {
            var sawContent = false
            let request = ModelRequest(prompt: "ping", backend: .openRouter, instructions: nil)
            try await self.stream(request: request) { snapshot in
                if !snapshot.isEmpty { sawContent = true }
            }
            return sawContent ? .available : .systemError("端点返回空内容")
        } catch let failure as ModelTaskFailure {
            if case let .unavailable(availability) = failure { return availability }
            return .systemError(failure.userMessage)
        } catch is CancellationError {
            return .systemError("连接测试被取消")
        } catch {
            return .systemError(String(describing: error))
        }
    }

    private let liveCatalog = Mutex<[OpenRouterModelInfo]>([])

    /// 实时模型目录（公开端点）：核对上下文长度与输出上限并缓存；设置页据此显示真实数字。
    public func fetchLiveModels() async throws -> [OpenRouterModelInfo] {
        var request = URLRequest(url: URL(string: Self.modelsEndpoint)!)
        request.httpMethod = "GET"
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelTaskFailure.endpointIncompatible("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw Self.mapHTTPError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw ModelTaskFailure.endpointIncompatible("模型目录结构无法解析")
        }
        var out: [OpenRouterModelInfo] = []
        for item in list {
            guard let id = item["id"] as? String else { continue }
            let context = (item["context_length"] as? Int)
                ?? ((item["top_provider"] as? [String: Any])?["context_length"] as? Int)
            let maxOutput = (item["max_completion_tokens"] as? Int)
                ?? ((item["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int)
            out.append(OpenRouterModelInfo(id: id, displayName: id, contextLength: context, maxOutput: maxOutput))
        }
        liveCatalog.withLock { $0 = out }
        return out
    }

    /// 模型维度：实时目录优先，回退静态清单（可能为 nil = 尚未核对）。
    public func modelInfo(for id: String) -> OpenRouterModelInfo? {
        if let live = liveCatalog.withLock({ $0 }).first(where: { $0.id == id }) {
            return live
        }
        return OpenRouterCatalog.info(for: id)
    }

    // MARK: - 内部

    private func stream(request: ModelRequest, onSnapshot: @escaping (String) -> Void) async throws {
        guard let key = keyStore.apiKey(), !key.isEmpty else {
            throw ModelTaskFailure.unavailable(.missingAPIKey)
        }
        let model = modelID.withLock { $0 }
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            // 独立 token 口径：真实 usage 由响应返回，不用 Apple tokenizer。
            "usage": ["include": true],
            "messages": [
                ["role": "system", "content": request.instructions ?? ""],
                ["role": "user", "content": request.prompt],
            ],
        ]
        if let info = modelInfo(for: model), let maxOutput = info.maxOutput {
            payload["max_tokens"] = maxOutput
        }
        var urlRequest = URLRequest(url: URL(string: Self.endpoint)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("FairyStudio", forHTTPHeaderField: "X-Title")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ModelTaskFailure.endpointIncompatible("非 HTTP 响应")
        }
        if http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Self.mapHTTPError(status: http.statusCode, body: body)
        }

        var accumulated = ""
        var finishReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]" else { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 流中途错误：如实解析并终止（不得当作完成内容）。
            if let errorObject = obj["error"] {
                throw Self.mapOpenRouterError(status: http.statusCode, errorObject: errorObject)
            }
            if let usage = obj["usage"] as? [String: Any] {
                let promptTokens = usage["prompt_tokens"] as? Int ?? 0
                let completionTokens = usage["completion_tokens"] as? Int ?? 0
                lastUsage = OpenRouterUsage(promptTokens: promptTokens, completionTokens: completionTokens, modelID: model)
            }
            if let choices = obj["choices"] as? [[String: Any]], let choice = choices.first {
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String, !content.isEmpty {
                    accumulated += content
                    onSnapshot(accumulated)
                }
                if let reason = choice["finish_reason"] as? String {
                    finishReason = reason
                }
            }
        }
        // 截断：完整接收但不当作可提交内容（管线不会收到成功结果）。
        if finishReason == "length" {
            throw ModelTaskFailure.truncatedOutput("finish_reason=length（达到模型输出上限）")
        }
        if finishReason == "error" {
            throw ModelTaskFailure.truncatedOutput("finish_reason=error")
        }
        if finishReason == nil && accumulated.isEmpty {
            throw ModelTaskFailure.endpointIncompatible("流式响应未包含任何内容")
        }
    }

    // MARK: - 错误解析（逐类，绝不无条件重试）

    static func mapHTTPError(status: Int, body: String) -> ModelTaskFailure {
        let detail = Self.errorDetail(status: status, body: body)
        switch status {
        case 401, 403: return .authFailed(detail)
        case 402: return .insufficientCredits(detail)
        case 429: return .rateLimited(detail)
        case 400 where isContextError(detail): return .exceededContextWindowSize(detail)
        case 404: return .endpointIncompatible(detail)
        default:
            if isContextError(detail) { return .exceededContextWindowSize(detail) }
            return .systemError("HTTP \\(status)（\\(detail)）")
        }
    }

    static func mapOpenRouterError(status: Int, errorObject: Any) -> ModelTaskFailure {
        var message = ""
        var code = status
        if let e = errorObject as? [String: Any] {
            message = (e["message"] as? String) ?? String(describing: e)
            if let n = e["code"] as? Int { code = n }
            if let s = e["code"] as? String, let n = Int(s) { code = n }
        } else {
            message = String(describing: errorObject)
        }
        switch code {
        case 401, 403: return .authFailed(message)
        case 402: return .insufficientCredits(message)
        case 429: return .rateLimited(message)
        case 404: return .endpointIncompatible(message)
        default:
            if isContextError(message) { return .exceededContextWindowSize(message) }
            return .systemError("HTTP \\(code)（\\(message)）")
        }
    }

    static func isContextError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("context_length") || lowered.contains("context length")
            || lowered.contains("context window") || lowered.contains("maximum context")
            || lowered.contains("maximum allowed") || lowered.contains("too many tokens")
            || lowered.contains("context size")
    }

    static func errorDetail(status: Int, body: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let e = obj["error"] as? [String: Any],
           let message = e["message"] as? String {
            return message
        }
        return body.isEmpty ? "HTTP \\(status)" : String(body.prefix(300))
    }
}
