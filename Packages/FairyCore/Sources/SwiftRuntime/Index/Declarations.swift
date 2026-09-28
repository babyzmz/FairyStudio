import RuntimeContracts
import SwiftSyntax

/// 访问级别。private 与 fileprivate 在本运行时中都按"仅本文件可见"处理（成员级别的细微差别见 SWIFT_SUPPORT.md）。
enum AccessLevel: Int, Comparable {
    case `private` = 0, `fileprivate`, `internal`, `public`
    static func < (a: AccessLevel, b: AccessLevel) -> Bool { a.rawValue < b.rawValue }
    var isFileScoped: Bool { self <= .fileprivate }
    var keyword: String {
        switch self {
        case .private: return "private"
        case .fileprivate: return "fileprivate"
        case .internal: return "internal"
        case .public: return "public"
        }
    }
}

/// 从修饰符读取访问级别与 setter 访问级别（`private(set)`）。
func readAccess(_ modifiers: DeclModifierListSyntax) -> (access: AccessLevel, setter: AccessLevel?) {
    var access = AccessLevel.internal
    var setter: AccessLevel?
    for m in modifiers {
        let level: AccessLevel?
        switch m.name.tokenKind {
        case .keyword(.private): level = .private
        case .keyword(.fileprivate): level = .fileprivate
        case .keyword(.internal): level = .internal
        case .keyword(.public), .keyword(.open): level = .public
        default: level = nil
        }
        guard let level else { continue }
        if let detail = m.detail, detail.detail.text == "set" { setter = level } else { access = level }
    }
    return (access, setter)
}

func hasModifier(_ modifiers: DeclModifierListSyntax, _ kw: Keyword) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(kw) }
}

/// 函数/方法的参数签名（编译期）。
struct ParamSig {
    var label: String?
    var name: String
    var typeSyntax: TypeSyntax?
    var type: SType = .unknown
    var defaultValue: ExprSyntax?
    var isInout: Bool
    var isVariadic: Bool
}

func fullName(_ base: String, _ labels: [String?]) -> String {
    base + "(" + labels.map { ($0 ?? "_") + ":" }.joined() + ")"
}

func readParams(_ clause: FunctionParameterClauseSyntax) -> [ParamSig] {
    clause.parameters.map { p in
        let first = p.firstName.text
        let label: String? = first == "_" ? nil : first
        let name = p.secondName?.text ?? first
        var isInout = false
        if let attributed = p.type.as(AttributedTypeSyntax.self) {
            isInout = attributed.specifiers.contains { $0.trimmedDescription == "inout" }
        }
        return ParamSig(label: label, name: name, typeSyntax: p.type, defaultValue: p.defaultValue?.value,
                        isInout: isInout, isVariadic: p.ellipsis != nil)
    }
}

final class StoredFieldDecl {
    let name: String
    let typeSyntax: TypeSyntax?
    let initializer: ExprSyntax?
    let isLet: Bool
    let wrapper: PropertyWrapperKind
    let access: AccessLevel
    let setterAccess: AccessLevel
    let fileIndex: Int
    let node: Syntax
    var type: SType = .unknown
    /// didSet 观察器（存储属性）：body + oldValue 参数名（nil 表示隐式 oldValue）+ 编译后函数 id。
    var didSetBody: CodeBlockItemListSyntax?
    var didSetParam: String?
    var didSetFunctionID = -1
    init(name: String, typeSyntax: TypeSyntax?, initializer: ExprSyntax?, isLet: Bool, wrapper: PropertyWrapperKind,
         access: AccessLevel, setterAccess: AccessLevel, fileIndex: Int, node: Syntax) {
        self.name = name; self.typeSyntax = typeSyntax; self.initializer = initializer; self.isLet = isLet
        self.wrapper = wrapper; self.access = access; self.setterAccess = setterAccess; self.fileIndex = fileIndex; self.node = node
    }
}

final class ComputedDecl {
    let name: String
    let typeSyntax: TypeSyntax?
    let body: CodeBlockItemListSyntax
    let isStatic: Bool
    let access: AccessLevel
    let fileIndex: Int
    let node: Syntax
    let isViewBuilder: Bool
    var type: SType = .unknown
    var functionID = -1
    /// setter（get/set 计算属性）：body + newValue 参数名 + 编译后函数 id（-1 表示只读）。
    var setterBody: CodeBlockItemListSyntax?
    var setterParam: String = "newValue"
    var setterFunctionID = -1
    init(name: String, typeSyntax: TypeSyntax?, body: CodeBlockItemListSyntax, isStatic: Bool, access: AccessLevel,
         fileIndex: Int, node: Syntax, isViewBuilder: Bool) {
        self.name = name; self.typeSyntax = typeSyntax; self.body = body; self.isStatic = isStatic; self.access = access
        self.fileIndex = fileIndex; self.node = node; self.isViewBuilder = isViewBuilder
    }
}

final class FuncDecl {
    let node: FunctionDeclSyntax
    let fileIndex: Int
    let access: AccessLevel
    let baseName: String
    var params: [ParamSig]
    let isStatic: Bool
    let isMutating: Bool
    let isViewBuilder: Bool
    var returnType: SType = .void
    var functionID = -1
    var labels: [String?] { params.map(\.label) }
    var fullName: String { SwiftRuntime.fullName(baseName, labels) }
    /// 重载判重键：全名 + 形参类型写法（Swift 允许按类型重载）。
    var overloadKey: String { fullName + "|" + params.map { $0.typeSyntax?.trimmedDescription ?? "_" }.joined(separator: ",") }
    init(node: FunctionDeclSyntax, fileIndex: Int, access: AccessLevel, isStatic: Bool, isMutating: Bool, isViewBuilder: Bool) {
        self.node = node; self.fileIndex = fileIndex; self.access = access; self.baseName = node.name.text
        self.params = readParams(node.signature.parameterClause); self.isStatic = isStatic; self.isMutating = isMutating
        self.isViewBuilder = isViewBuilder
    }
}

final class InitDecl {
    let node: InitializerDeclSyntax
    let fileIndex: Int
    let access: AccessLevel
    var params: [ParamSig]
    var functionID = -1
    var labels: [String?] { params.map(\.label) }
    init(node: InitializerDeclSyntax, fileIndex: Int, access: AccessLevel) {
        self.node = node; self.fileIndex = fileIndex; self.access = access
        self.params = readParams(node.signature.parameterClause)
    }
}

final class GlobalDecl {
    let name: String
    let typeSyntax: TypeSyntax?
    let initializer: ExprSyntax?
    let isLet: Bool
    let fileIndex: Int
    let node: Syntax
    let access: AccessLevel
    /// main.swift 顶层变量：由脚本主体按顺序初始化。
    let isMainTopLevel: Bool
    /// 静态存储属性所属类型
    let ownerType: Int?
    var type: SType = .unknown
    var globalID = -1
    /// didSet 观察器（全局变量 / static 存储属性）：body + oldValue 参数名 + 编译后函数 id。
    var didSetBody: CodeBlockItemListSyntax?
    var didSetParam: String?
    var didSetFunctionID = -1
    init(name: String, typeSyntax: TypeSyntax?, initializer: ExprSyntax?, isLet: Bool, fileIndex: Int, node: Syntax,
         access: AccessLevel, isMainTopLevel: Bool, ownerType: Int?) {
        self.name = name; self.typeSyntax = typeSyntax; self.initializer = initializer; self.isLet = isLet
        self.fileIndex = fileIndex; self.node = node; self.access = access; self.isMainTopLevel = isMainTopLevel; self.ownerType = ownerType
    }
}

final class EnumCaseInfo {
    let name: String
    let rawValue: ExprSyntax?
    let node: Syntax
    /// 关联值形参（标签 + 类型写法）；空数组表示无关联值。
    var associated: [(label: String?, type: TypeSyntax?)] = []
    init(name: String, rawValue: ExprSyntax?, node: Syntax) { self.name = name; self.rawValue = rawValue; self.node = node }
}

final class TypeDecl {
    enum Kind { case structType, enumType }
    let id: Int
    let name: String
    let kind: Kind
    let fileIndex: Int
    let node: Syntax
    let access: AccessLevel
    var conformances: [String] = []
    var isMain = false
    var fields: [StoredFieldDecl] = []
    var computed: [ComputedDecl] = []
    var methods: [FuncDecl] = []
    var inits: [InitDecl] = []
    var statics: [GlobalDecl] = []
    var cases: [EnumCaseInfo] = []
    var rawType: SType?
    var hasInitInBody = false
    var defaultsFunction = -1
    /// App 类型的 `var body: some Scene` 语句
    var sceneBody: CodeBlockItemListSyntax?

    var isView: Bool { conformances.contains("View") }
    var isApp: Bool { conformances.contains("App") }
    init(id: Int, name: String, kind: Kind, fileIndex: Int, node: Syntax, access: AccessLevel) {
        self.id = id; self.name = name; self.kind = kind; self.fileIndex = fileIndex; self.node = node; self.access = access
    }

    func field(_ name: String) -> StoredFieldDecl? { fields.first { $0.name == name } }
    func computedProp(_ name: String) -> ComputedDecl? { computed.first { $0.name == name } }
    func methods(named base: String) -> [FuncDecl] { methods.filter { $0.baseName == base } }
    func staticField(_ name: String) -> GlobalDecl? { statics.first { $0.name == name } }
    func caseIndex(_ name: String) -> Int? { cases.firstIndex { $0.name == name } }
}
