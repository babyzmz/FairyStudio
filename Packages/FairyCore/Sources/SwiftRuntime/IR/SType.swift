import RuntimeContracts

/// 编译期静态类型（尽力推断）。
///
/// 解释器本身是动态类型的；静态类型只用于：字面量定型（Int/Double 区分）、隐式成员（`.up`）解析、
/// 重载与方法分派的静态绑定、私有成员访问检查、print/插值时 Optional 的格式化。
/// `unknown` 表示编译期无法确定，VM 走动态分派（见 docs/RUNTIME_DESIGN.md "动态回退"）。
indirect enum SType: Hashable, Sendable, CustomStringConvertible {
    case unknown
    case void
    case int
    case double
    case bool
    case string
    case array(SType)
    case dict(SType, SType)
    case optional(SType)
    case range(closed: Bool)
    case tuple([SType], [String?])
    /// 用户定义的 struct / enum：类型索引 + 名称（名称仅用于消息）。
    case named(Int, String)
    case function([SType], SType)
    /// `some View`、内建视图值或自定义 View。
    case view
    case binding(SType)
    /// 未决隐式成员（`.red`、`.title`、`.center` 等 SwiftUI 常量）。
    case symbol
    case keyPath
    /// 用户类型作为表达式出现（`Counter.make()`、`Direction.allCases`）。
    case metatype(Int, String)
    /// 内建类型名作为表达式出现（`Int.max`、`Double.pi`、`Color.red`）。
    case builtinType(String)

    var description: String {
        switch self {
        case .unknown: return "_"
        case .void: return "Void"
        case .int: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        case .string: return "String"
        case .array(let e): return "[\(e)]"
        case .dict(let k, let v): return "[\(k): \(v)]"
        case .optional(let w): return "\(w)?"
        case .range(let closed): return closed ? "ClosedRange<Int>" : "Range<Int>"
        case .tuple(let ts, let ls):
            return "(" + zip(ts, ls).map { t, l in l.map { "\($0): \(t)" } ?? "\(t)" }.joined(separator: ", ") + ")"
        case .named(_, let n): return n
        case .function(let ps, let r): return "(" + ps.map(\.description).joined(separator: ", ") + ") -> \(r)"
        case .view: return "some View"
        case .binding(let t): return "Binding<\(t)>"
        case .symbol: return "(隐式成员)"
        case .keyPath: return "KeyPath"
        case .metatype(_, let n): return "\(n).Type"
        case .builtinType(let n): return "\(n).Type"
        }
    }

    var isKnown: Bool { if case .unknown = self { return false }; return true }
    var isNumeric: Bool { self == .int || self == .double }

    /// 去掉一层 Optional。
    var unwrapped: SType { if case .optional(let w) = self { return w }; return self }
    var isOptional: Bool { if case .optional = self { return true }; return false }

    var elementType: SType {
        switch self {
        case .array(let e): return e
        case .range: return .int
        case .string: return .string
        case .dict(let k, let v): return .tuple([k, v], ["key", "value"])
        default: return .unknown
        }
    }

    /// 是否确定为某个具体值类型（可以用于 Int/Double 不匹配诊断）。
    var isConcreteScalar: Bool {
        switch self {
        case .int, .double, .bool, .string: return true
        default: return false
        }
    }
}
