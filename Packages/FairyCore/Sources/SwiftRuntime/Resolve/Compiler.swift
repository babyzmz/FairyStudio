import RuntimeContracts
import SwiftSyntax

/// 编译产物（validate 与 run 共用）。
struct CompileOutput: Sendable {
    var program: IRProgram?
    var diagnostics: [RuntimeContracts.Diagnostic]
    var entryPoints: [EntryPoint]
    var capabilities: [String]
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// 编译器：解析 → 模块声明索引 → 名称解析与语义检查 → 槽位化 IR。
///
/// 所有阶段先处理完全部文件的顶层声明再解析引用，文件顺序不影响结果（文件已按路径排序）。
final class Compiler {
    let source: ProgramSource
    var files: [ParsedFile] = []
    var diagnostics: [RuntimeContracts.Diagnostic] = []
    var capabilities: Set<String> = []

    // 索引
    var types: [TypeDecl] = []
    var typeByName: [String: Int] = [:]
    var funcs: [String: [FuncDecl]] = [:]
    var globals: [GlobalDecl] = []
    var globalByName: [String: Int] = [:]
    var topLevelItems: [(file: Int, item: CodeBlockItemSyntax)] = []
    var extensions: [(file: Int, node: ExtensionDeclSyntax)] = []

    // 输出
    var functions: [IRFunction?] = []
    var ranges: [RuntimeContracts.SourceRange] = []
    var runtimeTypes: [RuntimeTypeInfo] = []
    var scriptFunction: Int?
    var appRootFunction: Int?
    var entryPoints: [EntryPoint] = []

    var _rawValues: [Int: [RawValueConst]] = [:]
    var scriptFileIndex: Int?
    var compilingScriptTopLevel = false
    /// 多语句闭包从 return 语句推断出的返回类型
    var inferredClosureReturn: [Int: SType] = [:]

    // 当前状态
    var fb: FunctionBuilder!
    var nextUID = 0
    var exprDepth = 0
    /// `.task` 同步子集：闭包体内的 `await` 按同步直接执行（声明侧不支持 async，故 await 只会出现在同步调用上）。
    var taskSyncDepth = 0

    init(source: ProgramSource) { self.source = source }

    // MARK: - 驱动

    func compile() -> CompileOutput {
        let parsed = ProgramParser.parse(source)
        files = parsed.files
        diagnostics = parsed.diagnostics
        if files.isEmpty {
            diagnostics.append(RuntimeContracts.Diagnostic(kind: .typeCheck, message: "项目中没有 Swift 源文件。"))
        }
        if files.contains(where: \.hasParseErrors) {
            return CompileOutput(program: nil, diagnostics: diagnostics, entryPoints: [], capabilities: [])
        }
        buildIndex()
        resolveSignatures()
        buildRuntimeTypes()
        compileBodies()
        computeEntryPoints()
        let program = IRProgram(
            moduleName: source.moduleName,
            functions: functions.enumerated().map { i, f in
                f ?? IRFunction(id: i, name: "<missing>", paramCount: 0, localCount: 0, code: [.trap("内部错误：函数未编译"), .ret],
                                locIndex: [-1, -1], places: [], paramCoercions: [], isMutating: false, isInit: false, fileIndex: 0)
            },
            types: runtimeTypes,
            globals: globals.map { GlobalInfo(name: $0.name, isLet: $0.isLet, type: $0.type, initFunction: globalInitFunctions[$0.globalID],
                                                     didSetFunction: $0.didSetFunctionID >= 0 ? $0.didSetFunctionID : nil) },
            ranges: ranges,
            filePaths: files.map(\.source.path),
            scriptFunction: scriptFunction,
            appRootFunction: appRootFunction,
            typeByName: typeByName)
        return CompileOutput(program: program, diagnostics: diagnostics, entryPoints: entryPoints,
                             capabilities: capabilities.sorted())
    }

    var globalInitFunctions: [Int: Int] = [:]

    // MARK: - 诊断

    func range(_ node: some SyntaxProtocol, file: Int? = nil) -> RuntimeContracts.SourceRange? {
        let f = file ?? fb?.fileIndex ?? 0
        guard f < files.count else { return nil }
        return files[f].range(of: node)
    }

    func error(_ kind: DiagnosticKind, _ message: String, _ node: some SyntaxProtocol, file: Int? = nil,
               capability: String? = nil, suggestion: String? = nil) {
        if let capability { capabilities.insert(capability) }
        let d = RuntimeContracts.Diagnostic(kind: kind, severity: .error, message: message, range: range(node, file: file),
                           suggestion: suggestion, capabilityID: capability)
        // 同一位置同一消息只报一次
        if !diagnostics.contains(where: { $0.message == d.message && $0.range == d.range }) { diagnostics.append(d) }
    }

    func warning(_ message: String, _ node: some SyntaxProtocol, file: Int? = nil) {
        diagnostics.append(RuntimeContracts.Diagnostic(kind: .typeCheck, severity: .warning, message: message, range: range(node, file: file)))
    }

    /// 合法 Swift 但运行时尚不支持的语法。
    func unsupported(_ what: String, _ node: some SyntaxProtocol, _ capability: String, file: Int? = nil) {
        error(.unsupportedSyntax, "运行时尚不支持：\(what)。这是合法的 Swift，但 Fairy Studio 当前版本的解释器还不能执行它。",
              node, file: file, capability: capability)
    }

    /// 合法调用但 API 未实现。
    func unsupportedAPI(_ what: String, _ node: some SyntaxProtocol, _ capability: String) {
        error(.unsupportedAPI, "运行时尚不支持 API：\(what)。这是合法的 Swift/SwiftUI 调用，但当前运行时还没有实现它。",
              node, capability: capability)
    }

    func use(_ capability: String) { capabilities.insert(capability) }

    // MARK: - 发射

    func emit(_ i: Instr) {
        fb.code.append(i)
        fb.locs.append(fb.currentLoc)
    }

    var here: Int { fb.code.count }

    /// 发射一条待回填目标的跳转，返回其位置。
    func emitJump(_ make: (Int) -> Instr) -> Int {
        emit(make(-1))
        return fb.code.count - 1
    }

    func patch(_ at: Int, to target: Int) {
        switch fb.code[at] {
        case .jump: fb.code[at] = .jump(target)
        case .jumpIfFalse: fb.code[at] = .jumpIfFalse(target)
        case .jumpIfTrue: fb.code[at] = .jumpIfTrue(target)
        case .jumpIfNil: fb.code[at] = .jumpIfNil(target)
        case .jumpIfNotNil: fb.code[at] = .jumpIfNotNil(target)
        case .loop: fb.code[at] = .loop(target)
        case .iterNext(let slot, _): fb.code[at] = .iterNext(slot: slot, exit: target)
        default: break
        }
    }

    func addPlace(_ p: PlaceDesc) -> Int {
        if let i = fb.places.firstIndex(of: p) { return i }
        fb.places.append(p)
        return fb.places.count - 1
    }

    /// 在编译某个节点期间把它的源范围关联到发射的指令。
    func withLoc<R>(_ node: some SyntaxProtocol, _ body: () -> R) -> R {
        let saved = fb.currentLoc
        if let r = range(node) {
            ranges.append(r)
            fb.currentLoc = Int32(ranges.count - 1)
        }
        defer { fb.currentLoc = saved }
        return body()
    }

    func allocFunction() -> Int {
        functions.append(nil)
        return functions.count - 1
    }

    func declareLocal(_ name: String, isLet: Bool, type: SType, byRef: Bool? = nil) -> LocalVar {
        nextUID += 1
        let v = LocalVar(uid: nextUID, slot: fb.localCount, name: name, isLet: isLet, type: type, captureByRef: byRef ?? !isLet)
        fb.localCount += 1
        fb.declare(v)
        return v
    }

    func hiddenLocal() -> Int {
        fb.localCount += 1
        return fb.localCount - 1
    }

    /// 以新的函数构建器编译 body，结束后登记为 IRFunction。
    func withFunction(id: Int, name: String, file: Int, parent: FunctionBuilder?, _ body: (FunctionBuilder) -> Void) {
        let saved = fb
        let b = FunctionBuilder(id: id, name: name, fileIndex: file, parent: parent)
        fb = b
        body(b)
        functions[id] = b.finish(program: ranges.count)
        fb = saved
    }
}
