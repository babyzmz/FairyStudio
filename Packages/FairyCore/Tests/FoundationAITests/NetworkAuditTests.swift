import Testing
import Foundation

/// 本项目自定义的源码审计（不是 Apple API）：FoundationAI 目标内不得出现通用网络 API 或第三方端点。
/// 模型只能经由 Apple 系统框架（FoundationModels / 未来的 PCC API）访问。
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
    }

    @Test("FoundationAI 源码不含通用网络 API 或外部端点")
    func noNetworkAPIs() throws {
        var violations: [String] = []
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() {
                for token in Self.forbiddenTokens where line.contains(token) {
                    violations.append("\(file.lastPathComponent):\(lineNumber + 1) 含 \(token)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test("FoundationAI 只导入允许的模块")
    func importsAreAllowListed() throws {
        let allowed: Set<String> = ["Foundation", "FoundationModels", "Synchronization", "RuntimeContracts"]
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
