import Foundation

/// 一次运行实例的身份。旧实例的回调不得影响新实例：所有事件都带 RunID。
public struct RunID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// 项目内文件的稳定身份；文件改名不改变 FileID。
public struct FileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// RenderTree 节点身份：由视图结构路径 + 显式 id（ForEach/List 行）组成，跨渲染稳定。
public struct NodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// 宿主触发运行时动作（Button.action 等）的句柄；只在其所属 RunID 内有效。
/// 对宿主而言 NodeID / ActionID / BindingID 都是不透明字符串，同一 RunID 内跨渲染稳定；宿主不得解析其内部格式。
public struct ActionID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// 双向绑定句柄（TextField / Toggle / Slider 等），宿主通过它反向写入运行时状态。
public struct BindingID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// 运行时语义版本；manifest.runtimeVersion 与 capability catalog 都引用它。
public struct RuntimeVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    public static func < (a: RuntimeVersion, b: RuntimeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
}
