import RuntimeContracts

/// 参数进入函数时的宽松转换（动态回退：类型未知的调用点传入整数字面量给 Double 形参）。
enum ParamCoercion: Sendable, Hashable { case none, intToDouble }

/// 一个已编译函数（顶层函数、方法、init、计算属性 getter、闭包、全局初始化器、脚本主体）。
final class IRFunction: Sendable {
    let id: Int
    let name: String
    /// 形参个数（方法/init 的 self 占槽位 0 并计入）。
    let paramCount: Int
    let localCount: Int
    let code: [Instr]
    /// 与 code 等长：每条指令对应的源范围索引（-1 表示无）。
    let locIndex: [Int32]
    let places: [PlaceDesc]
    let paramCoercions: [ParamCoercion]
    /// mutating 方法或 init：返回时需要把槽位 0（self）写回。
    let isMutating: Bool
    let isInit: Bool
    let fileIndex: Int

    init(id: Int, name: String, paramCount: Int, localCount: Int, code: [Instr], locIndex: [Int32], places: [PlaceDesc],
         paramCoercions: [ParamCoercion], isMutating: Bool, isInit: Bool, fileIndex: Int) {
        self.id = id; self.name = name; self.paramCount = paramCount; self.localCount = localCount; self.code = code
        self.locIndex = locIndex; self.places = places; self.paramCoercions = paramCoercions
        self.isMutating = isMutating; self.isInit = isInit; self.fileIndex = fileIndex
    }
}

enum PropertyWrapperKind: String, Sendable, Hashable { case none, state, binding }

enum RawValueConst: Sendable, Hashable {
    case int(Int), string(String), double(Double)
}

struct MethodInfo: Sendable, Hashable {
    var function: Int
    var isMutating: Bool
    var isStatic: Bool
    var paramLabels: [String?]
    var paramTypes: [SType]
    var returnType: SType
    var defaultArgCount: Int
}

/// 运行期类型元数据（由索引与编译阶段生成，只读）。
struct RuntimeTypeInfo: Sendable {
    enum Kind: String, Sendable { case structType, enumType }
    let id: Int
    let name: String
    let kind: Kind
    var fieldNames: [String] = []
    var fieldTypes: [SType] = []
    var fieldWrappers: [PropertyWrapperKind] = []
    var fieldIndex: [String: Int] = [:]
    /// 计算属性名 → getter 函数
    var computed: [String: Int] = [:]
    /// 方法全名（如 `add(_:to:)`）→ 方法信息
    var methods: [String: MethodInfo] = [:]
    var isView = false
    var isApp = false
    var bodyGetter: Int?
    /// 返回一个"所有带默认值的存储属性已初始化"的记录（无默认值的字段为 void）。
    var defaultsFunction: Int?
    /// 无参 init（rootView 入口构造用）
    var zeroArgInit: Int?
    var caseNames: [String] = []
    var rawValues: [RawValueConst]? = nil
    var conformances: Set<String> = []
}

struct GlobalInfo: Sendable {
    let name: String
    let isLet: Bool
    let type: SType
    /// 惰性初始化函数（非 main.swift 的全局变量、静态存储属性）；nil 表示由脚本顶层代码初始化。
    let initFunction: Int?
}

/// 编译产物：执行期只使用它，不再引用语法树。
final class IRProgram: Sendable {
    let moduleName: String
    let functions: [IRFunction]
    let types: [RuntimeTypeInfo]
    let globals: [GlobalInfo]
    let ranges: [SourceRange]
    let filePaths: [String]
    /// 入口函数：脚本主体（main.swift 顶层语句）
    let scriptFunction: Int?
    /// `.mainApp` 入口：返回根 View 值的合成函数
    let appRootFunction: Int?
    let typeByName: [String: Int]

    init(moduleName: String, functions: [IRFunction], types: [RuntimeTypeInfo], globals: [GlobalInfo], ranges: [SourceRange],
         filePaths: [String], scriptFunction: Int?, appRootFunction: Int?, typeByName: [String: Int]) {
        self.moduleName = moduleName; self.functions = functions; self.types = types; self.globals = globals
        self.ranges = ranges; self.filePaths = filePaths; self.scriptFunction = scriptFunction
        self.appRootFunction = appRootFunction; self.typeByName = typeByName
    }

    func range(function: IRFunction, pc: Int) -> SourceRange? {
        guard pc >= 0, pc < function.locIndex.count else { return nil }
        let idx = Int(function.locIndex[pc])
        return idx >= 0 && idx < ranges.count ? ranges[idx] : nil
    }
}
