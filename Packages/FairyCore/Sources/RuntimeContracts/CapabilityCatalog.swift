import Foundation

public enum SupportLevel: String, Sendable, Codable { case supported, partial, unsupported }

public enum CapabilityCategory: String, Sendable, Codable {
    case syntax          // 语言语法：if/guard/switch/closure/struct/enum/extension…
    case stdlib          // 标准库函数签名：Array.map、String.count…
    case view            // SwiftUI 组件
    case modifier        // SwiftUI modifier
    case propertyWrapper // @State/@Binding…
    case hostCapability  // 宿主能力：文件、照片、音频、传感器…
}

/// machine-readable capability catalog 的条目。编辑器补全、AI 上下文、导入诊断和文档共用同一份目录。
public struct CapabilityEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String                 // 例：syntax.guard、stdlib.Array.map、view.Text、modifier.padding、host.photos.pick
    public var category: CapabilityCategory
    public var displayName: String
    public var signature: String?         // 承诺的精确签名（stdlib / modifier / host）
    public var level: SupportLevel
    public var minRuntimeVersion: RuntimeVersion
    public var requiredPermission: String?
    public var testIDs: [String]          // 对应测试用例 ID，必须真实存在
    public var notes: String?
    public init(id: String, category: CapabilityCategory, displayName: String, signature: String? = nil, level: SupportLevel,
                minRuntimeVersion: RuntimeVersion, requiredPermission: String? = nil, testIDs: [String] = [], notes: String? = nil) {
        self.id = id; self.category = category; self.displayName = displayName; self.signature = signature; self.level = level
        self.minRuntimeVersion = minRuntimeVersion; self.requiredPermission = requiredPermission; self.testIDs = testIDs; self.notes = notes
    }
}

public struct CapabilityCatalog: Sendable, Codable {
    public var runtimeVersion: RuntimeVersion
    public var entries: [CapabilityEntry]
    public init(runtimeVersion: RuntimeVersion, entries: [CapabilityEntry]) { self.runtimeVersion = runtimeVersion; self.entries = entries }
    public subscript(id: String) -> CapabilityEntry? { entries.first { $0.id == id } }
}
