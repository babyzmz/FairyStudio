import Foundation
import Security
import FoundationAI

/// OpenRouter API Key 的 Keychain 存储。
/// - Key 只存于本设备 Keychain（kSecAttrAccessibleAfterFirstUnlock）；
/// - 不进入源码、日志、提示词、导出包与解释器可访问范围（网络审计测试锁定此边界）；
/// - 界面只显示是否已配置与尾 4 位，不回显完整 Key。
final class OpenRouterKeychain: APIKeyStoring {
    static let service = "com.fairystudio.openrouter"
    static let account = "api-key"

    func apiKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setApiKey(_ key: String) -> String? {
        deleteApiKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            return "钥匙串写入失败（OSStatus \(status)）"
        }
        // 写后读校验：保存成功以读回为准。
        return apiKey() == nil ? "钥匙串写入后读回失败" : nil
    }

    @discardableResult
    func deleteApiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return "钥匙串删除失败（OSStatus \(status)）"
        }
        return nil
    }

    /// 状态摘要：不回显完整 Key。
    func statusDescription() -> String {
        guard let key = apiKey(), !key.isEmpty else { return "未配置" }
        let tail = key.suffix(4)
        return "已配置（…\(tail)）"
    }
}
