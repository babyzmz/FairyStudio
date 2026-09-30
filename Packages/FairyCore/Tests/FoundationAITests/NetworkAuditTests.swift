import Testing
import Foundation

/// 本项目自定义的源码审计（不是 Apple API）。
/// 网络策略（2026-09-28 调整）：OpenRouterProvider 是 FoundationAI 内唯一允许联网的文件，
/// 且只允许访问 openrouter.ai 域名；其余文件维持全禁（模型只经 Apple 系统框架访问）。
/// Key 只经 APIKeyStoring 进入 HTTP 头，不得出现在端点或提示词组装代码中。
@Suite("FoundationAI 网络审计")
struct NetworkAuditTests {
    static let forbiddenTokens = [
        "URLSession", "URLRequest", "NSURLConnection", "NSURLSession", "NWConnection", "CFStream",
        "WebSocket", "http://", "https://",
    ]

    static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FoundationAITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // FairyCore
            .appendingPathComponent("Sources/FoundationAI", isDirectory: true)
    }

    static func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    @Test("审计确实扫描到了 FoundationAI 源文件")
    func auditIsNotVacuous() throws {
        let names = try Self.swiftFiles().map(\.lastPathComponent)
        #expect(names.contains("ModelBroker.swift"))
        #expect(names.contains("OnDeviceModelDriver.swift"))
        #expect(names.contains("PrivateCloudComputeDriver.swift"))
        #expect(names.contains("OpenRouterProvider.swift"))
    }

    /// 唯一允许联网的文件与唯一允许的域名。
    static let networkAllowedFile = "OpenRouterProvider.swift"
    static let allowedEndpointPrefix = "https://openrouter.ai"

    @Test("FoundationAI 源码不含通用网络 API 或外部端点（OpenRouterProvider 除外）")
    func noNetworkAPIs() throws {
        var violations: [String] = []
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() {
                let isProviderFile = file.lastPathComponent == Self.networkAllowedFile
                for token in Self.forbiddenTokens where line.contains(token) {
                    if isProviderFile { continue }
                    violations.append("\(file.lastPathComponent):\(lineNumber + 1) 含 \(token)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test("OpenRouterProvider 只访问 openrouter.ai 域名")
    func openRouterEndpointsAreAllowListed() throws {
        guard let providerFile = try Self.swiftFiles().first(where: { $0.lastPathComponent == Self.networkAllowedFile }) else {
            Issue.record("缺少 OpenRouterProvider.swift")
            return
        }
        var violations: [String] = []
        let text = try String(contentsOf: providerFile, encoding: .utf8)
        for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.contains("https://"), !line.contains(Self.allowedEndpointPrefix) {
                violations.append("\(lineNumber + 1)：\(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, "端点必须限定在 \(Self.allowedEndpointPrefix)：\(violations.joined(separator: "\n"))")
    }

    @Test("API Key 不进入提示词组装代码")
    func apiKeyDoesNotReachPromptAssembly() throws {
        // Key 只允许出现在 OpenRouterProvider.swift（HTTP 头）；提示词/管线文件不得引用 keyStore。
        let promptFiles = ["AssistantPipeline.swift", "AssistantTools.swift", "AssistantProposal.swift"]
        var violations: [String] = []
        for file in try Self.swiftFiles() where promptFiles.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("APIKey") || text.contains("apiKey") || text.contains("sk-or-") {
                violations.append(file.lastPathComponent)
            }
        }
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test("FoundationAI 只导入允许的模块")
    func importsAreAllowListed() throws {
        let allowed: Set<String> = ["Foundation", "FoundationModels", "Synchronization", "RuntimeContracts", "ProjectContracts"]
        var unexpected: [String] = []
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count).split(separator: " ").first.map(String.init) ?? ""
                if !allowed.contains(module) { unexpected.append("\(file.lastPathComponent): \(trimmed)") }
            }
        }
        #expect(unexpected.isEmpty, "\(unexpected.joined(separator: "\n"))")
    }
}
