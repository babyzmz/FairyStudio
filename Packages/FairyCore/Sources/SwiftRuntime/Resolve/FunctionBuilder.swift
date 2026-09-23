import RuntimeContracts

/// 局部变量（槽位化）。
struct LocalVar {
    let uid: Int
    let slot: Int
    let name: String
    let isLet: Bool
    var type: SType
    /// 被闭包捕获时是否按引用（var、嵌套函数、mutating 方法中的 self）。
    let captureByRef: Bool
}

enum VarLocation { case local(Int), capture(Int) }

struct ResolvedVar {
    let location: VarLocation
    let info: LocalVar
}

/// break / continue 目标。
struct Breakable {
    let isLoop: Bool
    var breakPatches: [Int] = []
    var continuePatches: [Int] = []
}

/// 单个函数（或闭包）的 IR 构建器。
final class FunctionBuilder {
    let id: Int
    let name: String
    let fileIndex: Int
    let parent: FunctionBuilder?
    var code: [Instr] = []
    var locs: [Int32] = []
    var places: [PlaceDesc] = []
    var localCount = 0
    var scopes: [[String: LocalVar]] = [[:]]
    var captures: [CaptureSource] = []
    var captureIndexByUID: [Int: Int] = [:]
    /// 静态方法 / 静态计算属性上下文所属类型
    var staticTypeContext: Int?
    var returnType: SType = .void
    var isInit = false
    var isMutating = false
    var breakables: [Breakable] = []
    var currentLoc: Int32 = -1
    var paramCoercions: [ParamCoercion] = []
    var paramCount = 0
    /// 可选链的"跳到链尾"补丁列表栈
    var optionalChainPatches: [[Int]] = []
    /// 视图构建模式（@ViewBuilder 闭包/body）
    var isBuilder = false

    init(id: Int, name: String, fileIndex: Int, parent: FunctionBuilder?) {
        self.id = id; self.name = name; self.fileIndex = fileIndex; self.parent = parent
    }

    func declare(_ v: LocalVar) { scopes[scopes.count - 1][v.name] = v }

    func pushScope() { scopes.append([:]) }
    func popScope() { scopes.removeLast() }

    /// 不产生捕获的只读查找（用于类型推断）。
    func peek(_ name: String) -> LocalVar? {
        for s in scopes.reversed() { if let v = s[name] { return v } }
        return parent?.peek(name)
    }

    /// 查找变量；若来自外层函数则登记为捕获。
    func lookup(_ name: String) -> ResolvedVar? {
        for s in scopes.reversed() { if let v = s[name] { return ResolvedVar(location: .local(v.slot), info: v) } }
        guard let parent, let pv = parent.lookup(name) else { return nil }
        if let idx = captureIndexByUID[pv.info.uid] { return ResolvedVar(location: .capture(idx), info: pv.info) }
        let src: CaptureSource
        switch pv.location {
        case .local(let s): src = .local(slot: s, byRef: pv.info.captureByRef)
        case .capture(let i): src = .capture(i)
        }
        captures.append(src)
        let idx = captures.count - 1
        captureIndexByUID[pv.info.uid] = idx
        return ResolvedVar(location: .capture(idx), info: pv.info)
    }

    /// 最近的静态类型上下文（沿闭包链向外）。
    var enclosingStaticType: Int? { staticTypeContext ?? parent?.enclosingStaticType }

    func finish(program ranges: Int) -> IRFunction {
        IRFunction(id: id, name: name, paramCount: paramCount, localCount: max(localCount, paramCount), code: code,
                   locIndex: locs, places: places, paramCoercions: paramCoercions, isMutating: isMutating || isInit,
                   isInit: isInit, fileIndex: fileIndex)
    }
}
