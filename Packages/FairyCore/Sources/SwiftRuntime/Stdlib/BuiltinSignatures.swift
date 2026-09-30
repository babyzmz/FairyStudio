import RuntimeContracts

/// 编译期使用的内建名称与签名表。与 Stdlib / ViewBuiltins 的运行期实现、capability catalog 一一对应。

/// 受支持（至少部分）的内建类型名。
let builtinTypeNames: Set<String> = [
    "Int", "Double", "Bool", "String", "Array", "Dictionary", "Optional", "Character", "CGFloat", "Void", "Never",
    "Range", "ClosedRange", "Binding", "State",
    "View", "App", "Scene", "WindowGroup", "Color", "Font", "Text", "Button", "VStack", "HStack", "ZStack", "Spacer", "Divider",
    "TextField", "SecureField", "Toggle", "Slider", "Stepper", "Picker", "ForEach", "List", "NavigationStack", "NavigationView",
    "NavigationLink", "ScrollView", "Group",
    "Form", "Section", "Image", "ProgressView", "EmptyView",
]

/// 合法的 Swift / Foundation / SwiftUI 类型或视图，但运行时尚未支持（产生 unsupportedAPI 诊断而不是"找不到"）。
let knownUnsupportedTypes: Set<String> = [
    "Float", "Float32", "Float64", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Set", "UUID", "URL", "Data", "Timer", "DispatchQueue", "Task", "Substring", "AttributedString", "Calendar",
    "DateFormatter", "NumberFormatter", "Locale", "FileManager", "Bundle", "ProcessInfo", "Thread", "UserDefaults",
    "NotificationCenter", "JSONEncoder", "JSONDecoder", "ObservableObject", "AnyView", "Result", "Error",
    "DatePicker", "ColorPicker", "Label", "Link", "Menu", "TabView", "LazyVStack", "LazyHStack",
    "LazyVGrid", "LazyHGrid", "Grid", "GridRow", "GridItem", "GeometryReader", "Circle", "Rectangle", "RoundedRectangle", "Capsule",
    "Ellipse", "Path", "Canvas", "TimelineView", "AsyncImage", "TextEditor", "Gauge", "ShareLink",
    "NavigationSplitView", "Alert", "ActionSheet", "LinearGradient", "RadialGradient", "AngularGradient", "ToolbarItem",
    "EditButton", "ControlGroup", "DisclosureGroup", "OutlineGroup", "Table", "ContentUnavailableView", "ViewThatFits",
    "Settings", "DocumentGroup", "Animation", "Angle", "CGSize", "CGPoint", "CGRect", "UIColor", "NSColor",
]

let knownUnsupportedFunctions: Set<String> = [
    "withAnimation", "sequence", "type", "dump", "debugPrint", "swap", "readLine", "exit",
]

/// 受支持的自由函数（非视图）。
let builtinFunctionNames: Set<String> = [
    "print", "abs", "min", "max", "stride", "fatalError", "precondition", "assert",
    "sqrt", "floor", "ceil", "round", "sin", "cos", "exp", "log", "pow",
    "zip", "repeatElement",
]

/// 视图构造参数种类。
enum ViewParamKind {
    case string, number, bool, symbol, binding, keyPath, data
    case range         // 区间（Slider/Stepper 的 in:，Int 闭区间）
    case view        // 内联 @ViewBuilder 内容
    case action      // () -> Void 闭包
    case rowBuilder  // (Element) -> some View 闭包（@ViewBuilder）
    case any
    var isClosure: Bool {
        switch self {
        case .view, .action, .rowBuilder: return true
        default: return false
        }
    }
}

struct ViewParam {
    let label: String?
    let kind: ViewParamKind
    let optional: Bool
}

private func p(_ label: String?, _ kind: ViewParamKind, opt: Bool = false) -> ViewParam { ViewParam(label: label, kind: kind, optional: opt) }

/// 内建视图构造签名（重载按顺序匹配）。
let viewSignatures: [String: [[ViewParam]]] = [
    "Text": [[p(nil, .string)], [p("verbatim", .string)]],
    "Button": [[p(nil, .string), p("role", .symbol, opt: true), p("action", .action)],
               [p("role", .symbol, opt: true), p("action", .action), p("label", .view)]],
    "VStack": [[p("alignment", .symbol, opt: true), p("spacing", .number, opt: true), p("content", .view)]],
    "HStack": [[p("alignment", .symbol, opt: true), p("spacing", .number, opt: true), p("content", .view)]],
    "ZStack": [[p("alignment", .symbol, opt: true), p("content", .view)]],
    "Spacer": [[p("minLength", .number, opt: true)]],
    "Divider": [[]],
    "EmptyView": [[]],
    "TextField": [[p(nil, .string), p("text", .binding)]],
    "SecureField": [[p(nil, .string), p("text", .binding)]],
    "Toggle": [[p(nil, .string), p("isOn", .binding)], [p("isOn", .binding), p("label", .view)]],
    "ForEach": [[p(nil, .data), p("id", .keyPath, opt: true), p("content", .rowBuilder)]],
    "List": [[p(nil, .data), p("id", .keyPath, opt: true), p("rowContent", .rowBuilder)], [p("content", .view)]],
    "NavigationStack": [[p("content", .view)], [p("path", .binding), p("content", .view)]],
    "NavigationView": [[p("content", .view)]],
    "NavigationLink": [[p(nil, .string), p("value", .any), p("label", .view, opt: true)],
                       [p("value", .any), p("label", .view)],
                       [p(nil, .string), p("destination", .view)],
                       [p("destination", .view), p("label", .view)]],
    "Slider": [[p("value", .binding), p("in", .range), p("step", .number, opt: true), p("label", .view, opt: true)]],
    "Stepper": [[p(nil, .string), p("value", .binding), p("in", .range, opt: true)],
                [p("value", .binding), p("in", .range, opt: true), p("label", .view)]],
    "Picker": [[p(nil, .string), p("selection", .binding), p("content", .view)],
               [p("selection", .binding), p("label", .view), p("content", .view)]],
    "ScrollView": [[p(nil, .symbol, opt: true), p("content", .view)]],
    "Group": [[p("content", .view)]],
    "Form": [[p("content", .view)]],
    "Section": [[p(nil, .string, opt: true), p("header", .string, opt: true), p("footer", .string, opt: true), p("content", .view)]],
    "Image": [[p("systemName", .string)], [p(nil, .string)]],
    "ProgressView": [[p(nil, .string, opt: true), p("value", .number, opt: true), p("total", .number, opt: true)]],
    "Color": [[p("red", .number), p("green", .number), p("blue", .number), p("opacity", .number, opt: true)]],
]

/// 视图名 → capability ID。
func viewCapability(_ name: String) -> String { "view.\(name == "NavigationView" ? "NavigationStack" : name)" }

/// 修饰符签名：允许的标签组合与参数期望类型。
struct ModifierSig {
    let labelSets: [[String?]]
    let argType: SType
}

let modifierSignatures: [String: ModifierSig] = [
    "padding": ModifierSig(labelSets: [[], [nil], [nil, nil]], argType: .unknown),
    "font": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "fontWeight": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "bold": ModifierSig(labelSets: [[]], argType: .unknown),
    "italic": ModifierSig(labelSets: [[]], argType: .unknown),
    "foregroundColor": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "foregroundStyle": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "tint": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "background": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "frame": ModifierSig(labelSets: [], argType: .double),   // 标签为 width/height/maxWidth/maxHeight/alignment 的有序子集
    "cornerRadius": ModifierSig(labelSets: [[nil]], argType: .double),
    "opacity": ModifierSig(labelSets: [[nil]], argType: .double),
    "disabled": ModifierSig(labelSets: [[nil]], argType: .bool),
    "hidden": ModifierSig(labelSets: [[]], argType: .unknown),
    "navigationTitle": ModifierSig(labelSets: [[nil]], argType: .string),
    "buttonStyle": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "textFieldStyle": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "listStyle": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "multilineTextAlignment": ModifierSig(labelSets: [[nil]], argType: .symbol),
    "lineLimit": ModifierSig(labelSets: [[nil]], argType: .int),
    "accessibilityLabel": ModifierSig(labelSets: [[nil]], argType: .string),
    "tag": ModifierSig(labelSets: [[nil]], argType: .unknown),
    "onAppear": ModifierSig(labelSets: [["perform"]], argType: .function([], .void)),
    "onDisappear": ModifierSig(labelSets: [["perform"]], argType: .function([], .void)),
    "task": ModifierSig(labelSets: [[nil]], argType: .function([], .void)),
    /// pickerStyle 样式透传（segmented/menu/automatic；视图本身不变，桥接按默认样式渲染）
    "pickerStyle": ModifierSig(labelSets: [[nil]], argType: .symbol),
]

let frameLabelOrder = ["width", "height", "maxWidth", "maxHeight", "alignment"]

/// 内建值类型的属性类型（编译期推断）。nil 表示不支持。
func builtinMemberType(_ recv: SType, _ name: String, program types: [TypeDecl]) -> SType? {
    switch recv {
    case .array(let e):
        switch name {
        case "count", "startIndex", "endIndex": return .int
        case "isEmpty": return .bool
        case "first", "last": return .optional(e)
        case "indices": return .range(closed: false)
        default: return nil
        }
    case .string:
        switch name {
        case "count": return .int
        case "isEmpty": return .bool
        case "first", "last": return .optional(.string)
        case "description": return .string
        default: return nil
        }
    case .dict(let k, let v):
        switch name {
        case "count": return .int
        case "isEmpty": return .bool
        case "keys": return .array(k)
        case "values": return .array(v)
        default: return nil
        }
    case .range:
        switch name {
        case "count", "lowerBound", "upperBound": return .int
        case "isEmpty": return .bool
        case "first", "last": return .optional(.int)
        default: return nil
        }
    case .int:
        switch name {
        case "description": return .string
        case "magnitude": return .int
        default: return nil
        }
    case .double:
        switch name {
        case "description": return .string
        case "isNaN", "isInfinite", "isFinite": return .bool
        default: return nil
        }
    case .date:
        return name == "description" ? .string : nil
    case .bool:
        return name == "description" ? .string : nil
    case .tuple(let ts, let ls):
        if let i = ls.firstIndex(of: name) { return ts[i] }
        if let i = Int(name), i < ts.count { return ts[i] }
        return nil
    case .named(let t, _):
        if name == "rawValue", t < types.count, let raw = types[t].rawType { return raw }
        return nil
    default:
        return nil
    }
}

/// 内建方法签名：闭包参数类型与结果类型。
struct MethodSig {
    /// 各参数的期望类型（闭包参数为函数类型）
    var params: [SType]
    /// 结果类型；closureResult 用于 map 等
    var result: (_ closureResult: SType, _ argTypes: [SType]) -> SType
    var mutating: Bool
    var capability: String
}

func builtinMethodSig(_ recv: SType, _ fullName: String) -> MethodSig? {
    func sig(_ params: [SType], mutating: Bool = false, _ cap: String, _ result: @escaping (SType, [SType]) -> SType) -> MethodSig {
        MethodSig(params: params, result: result, mutating: mutating, capability: cap)
    }
    let typeName: String
    var elem: SType = .unknown
    switch recv {
    case .array(let e): typeName = "Array"; elem = e
    case .range: typeName = "Range"; elem = .int
    case .string: typeName = "String"; elem = .string
    case .dict(let k, let v): typeName = "Dictionary"; elem = .tuple([k, v], ["key", "value"])
    case .int: typeName = "Int"
    case .double: typeName = "Double"
    case .bool: typeName = "Bool"
    default: return nil
    }
    let base = fullName.split(separator: "(").first.map(String.init) ?? fullName
    let cap = "stdlib.\(typeName).\(base)"
    switch (typeName, fullName) {
    case ("Int", "isMultiple(of:)"): return sig([.int], cap) { _, _ in .bool }
    case ("Int", "signum()"): return sig([], cap) { _, _ in .int }
    case ("Double", "rounded()"), ("Double", "squareRoot()"): return sig([], cap) { _, _ in .double }
    case ("Double", "rounded(_:)"): return sig([.symbol], cap) { _, _ in .double }
    case ("Double", "truncatingRemainder(dividingBy:)"): return sig([.double], cap) { _, _ in .double }
    case ("Bool", "toggle()"): return sig([], mutating: true, cap) { _, _ in .void }
    case ("Int", _), ("Double", _), ("Bool", _): return nil
    default: break
    }
    if typeName == "String" {
        switch fullName {
        case "uppercased()", "lowercased()", "dropFirst()", "dropLast()": return sig([], cap) { _, _ in .string }
        case "contains(_:)", "hasPrefix(_:)", "hasSuffix(_:)": return sig([.string], cap) { _, _ in .bool }
        case "split(separator:)", "components(separatedBy:)": return sig([.string], cap) { _, _ in .array(.string) }
        case "replacingOccurrences(of:with:)": return sig([.string, .string], cap) { _, _ in .string }
        case "trimmingCharacters(in:)": return sig([.symbol], cap) { _, _ in .string }
        case "prefix(_:)", "suffix(_:)", "dropFirst(_:)", "dropLast(_:)": return sig([.int], cap) { _, _ in .string }
        case "append(_:)", "append(contentsOf:)": return sig([.string], mutating: true, cap) { _, _ in .void }
        case "removeAll()": return sig([], mutating: true, cap) { _, _ in .void }
        case "removeLast()", "removeFirst()": return sig([], mutating: true, cap) { _, _ in .string }
        case "filter(_:)": return sig([.function([.string], .bool)], cap) { _, _ in .string }
        case "reversed()": return sig([], cap) { _, _ in .array(.string) }
        default: break
        }
    }
    if case .dict(let k, let v) = recv {
        switch fullName {
        case "removeValue(forKey:)": return sig([k], mutating: true, cap) { _, _ in .optional(v) }
        case "updateValue(_:forKey:)": return sig([v, k], mutating: true, cap) { _, _ in .optional(v) }
        case "removeAll()": return sig([], mutating: true, cap) { _, _ in .void }
        case "mapValues(_:)": return sig([.function([v], .unknown)], cap) { r, _ in .dict(k, r) }
        case "filter(_:)": return sig([.function([elem], .bool)], cap) { _, _ in .dict(k, v) }
        default: break
        }
    }
    if typeName == "Array" {
        switch fullName {
        case "append(_:)": return sig([elem], mutating: true, cap) { _, _ in .void }
        case "append(contentsOf:)": return sig([.array(elem)], mutating: true, cap) { _, _ in .void }
        case "insert(_:at:)": return sig([elem, .int], mutating: true, cap) { _, _ in .void }
        case "remove(at:)": return sig([.int], mutating: true, cap) { _, _ in elem }
        case "removeLast()", "removeFirst()": return sig([], mutating: true, cap) { _, _ in elem }
        case "popLast()": return sig([], mutating: true, cap) { _, _ in .optional(elem) }
        case "removeAll()", "sort()", "reverse()": return sig([], mutating: true, cap) { _, _ in .void }
        case "removeAll(where:)": return sig([.function([elem], .bool)], mutating: true, cap) { _, _ in .void }
        case "sort(by:)": return sig([.function([elem, elem], .bool)], mutating: true, cap) { _, _ in .void }
        case "swapAt(_:_:)": return sig([.int, .int], mutating: true, cap) { _, _ in .void }
        default: break
        }
    }
    // 序列通用（Array / Range / String / Dictionary）
    switch fullName {
    case "contains(_:)": return sig([elem], cap) { _, _ in .bool }
    case "contains(where:)", "allSatisfy(_:)": return sig([.function([elem], .bool)], cap) { _, _ in .bool }
    case "map(_:)": return sig([.function([elem], .unknown)], cap) { r, _ in .array(r) }
    case "compactMap(_:)": return sig([.function([elem], .unknown)], cap) { r, _ in .array(r.unwrapped) }
    case "filter(_:)": return sig([.function([elem], .bool)], cap) { _, _ in .array(elem) }
    case "forEach(_:)": return sig([.function([elem], .void)], cap) { _, _ in .void }
    case "reduce(_:_:)": return sig([.unknown, .function([.unknown, elem], .unknown)], cap) { _, a in a.first ?? .unknown }
    case "sorted()", "reversed()", "dropFirst()", "dropLast()": return sig([], cap) { _, _ in .array(elem) }
    case "sorted(by:)": return sig([.function([elem, elem], .bool)], cap) { _, _ in .array(elem) }
    case "enumerated()": return sig([], cap) { _, _ in .array(.tuple([.int, elem], ["offset", "element"])) }
    case "first(where:)": return sig([.function([elem], .bool)], cap) { _, _ in .optional(elem) }
    case "firstIndex(of:)", "lastIndex(of:)": return sig([elem], cap) { _, _ in .optional(.int) }
    case "firstIndex(where:)": return sig([.function([elem], .bool)], cap) { _, _ in .optional(.int) }
    case "min()", "max()": return sig([], cap) { _, _ in .optional(elem) }
    case "min(by:)", "max(by:)": return sig([.function([elem, elem], .bool)], cap) { _, _ in .optional(elem) }
    case "count(where:)": return sig([.function([elem], .bool)], cap) { _, _ in .int }
    case "joined(separator:)": return sig([.string], cap) { _, _ in .string }
    case "joined()": return sig([], cap) { _, _ in .string }
    case "prefix(_:)", "suffix(_:)", "dropFirst(_:)", "dropLast(_:)": return sig([.int], cap) { _, _ in .array(elem) }
    default: return nil
    }
}

/// 可能是 mutating 的方法名（接收者类型未知时用于决定是否按左值编译）。
let possiblyMutatingBuiltinNames: Set<String> = Stdlib.allMutatingNames
