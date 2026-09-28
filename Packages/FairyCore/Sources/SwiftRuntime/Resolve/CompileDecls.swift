import RuntimeContracts
import SwiftSyntax

extension Compiler {
    func compileBodies() {
        // 1. 存储属性默认值与全局初始化器（它们可能补全未标注的类型）
        for t in types where t.defaultsFunction >= 0 { compileDefaults(t) }
        for g in globals where !g.isMainTopLevel { compileGlobalInit(g) }
        buildRuntimeTypes()
        // 2. 类型成员
        for t in types {
            for c in t.computed { compileComputed(c, in: t) }
            for f in t.fields where f.didSetBody != nil && f.didSetFunctionID >= 0 {
                compileDidSet(typeID: t.id, fieldType: f.type, oldParam: f.didSetParam, body: f.didSetBody!,
                              functionID: f.didSetFunctionID, file: f.fileIndex, name: f.name)
            }
            for m in t.methods { compileFunc(m, inType: t) }
            for i in t.inits { compileInit(i, in: t) }
        }
        for g in globals where g.didSetBody != nil && g.didSetFunctionID >= 0 {
            compileGlobalDidSet(oldParam: g.didSetParam, fieldType: g.type, body: g.didSetBody!,
                                functionID: g.didSetFunctionID, file: g.fileIndex, name: g.name)
        }
        // 3. 顶层函数（按名称排序，保证确定性）
        for key in funcs.keys.sorted() {
            for fn in funcs[key] ?? [] { compileFunc(fn, inType: nil) }
        }
        // 4. 入口
        compileScript()
        compileAppRoot()
        // 顶层 var 的类型可能在脚本编译中补全
        buildRuntimeTypes()
    }

    func selfVar(_ t: TypeDecl, mutable: Bool) -> LocalVar {
        declareLocal("self", isLet: !mutable, type: .named(t.id, t.name), byRef: mutable)
    }

    func coercion(for t: SType) -> ParamCoercion {
        (t == .double || t == .optional(.double)) ? .intToDouble : .none
    }

    func compileDefaults(_ t: TypeDecl) {
        withFunction(id: t.defaultsFunction, name: "\(t.name).init(默认值)", file: t.fileIndex, parent: nil) { b in
            b.staticTypeContext = t.id
            for f in t.fields {
                if let i = f.initializer {
                    let ty = compileFieldInitializer(i, field: f)
                    if !f.type.isKnown { f.type = ty }
                } else if f.type.isOptional && !f.isLet {
                    emit(.pushNil)
                } else {
                    emit(.pushVoid)
                }
            }
            emit(.makeRecord(type: t.id, count: t.fields.count))
            emit(.ret)
        }
    }

    func compileFieldInitializer(_ e: ExprSyntax, field: StoredFieldDecl) -> SType {
        let expected: SType? = field.type.isKnown ? field.type : nil
        let t = compileExpr(e, expected: expected)
        if let expected { checkAssignable(expected, t, e) }
        return t
    }

    func compileGlobalInit(_ g: GlobalDecl) {
        guard let fid = globalInitFunctions[g.globalID], let initExpr = g.initializer else { return }
        let owner = g.ownerType.map { types[$0].name + "." } ?? ""
        withFunction(id: fid, name: "\(owner)\(g.name) 初始化", file: g.fileIndex, parent: nil) { b in
            b.staticTypeContext = g.ownerType
            let expected: SType? = g.type.isKnown ? g.type : nil
            let t = compileExpr(initExpr, expected: expected)
            if let expected { checkAssignable(expected, t, initExpr) } else { g.type = t }
            emit(.ret)
        }
    }

    func compileComputed(_ c: ComputedDecl, in t: TypeDecl) {
        withFunction(id: c.functionID, name: "\(t.name).\(c.name)", file: c.fileIndex, parent: nil) { b in
            b.staticTypeContext = t.id
            if !c.isStatic {
                _ = selfVar(t, mutable: false)
                b.paramCount = 1
                b.paramCoercions = [.none]
            }
            b.returnType = c.type
            compileFunctionBody(c.body, returnType: c.type, builder: c.isViewBuilder)
        }
        if let setterBody = c.setterBody, c.setterFunctionID >= 0 {
            compileComputedSetter(c, setterBody: setterBody, in: t)
        }
    }

    /// 计算属性 setter：`(self, newValue) -> Self`，返回 mutation 后的 self（调用方同步 invoke 后写回）。
    func compileComputedSetter(_ c: ComputedDecl, setterBody: CodeBlockItemListSyntax, in t: TypeDecl) {
        withFunction(id: c.setterFunctionID, name: "\(t.name).\(c.name).set", file: c.fileIndex, parent: nil) { b in
            b.staticTypeContext = t.id
            _ = selfVar(t, mutable: true)
            _ = declareLocal(c.setterParam, isLet: true, type: c.type)
            b.paramCount = 2
            b.paramCoercions = [.none, coercion(for: c.type)]
            b.returnType = .named(t.id, t.name)
            b.isMutating = true
            compileStatements(setterBody)
            emit(.loadLocal(0))
            emit(.ret)
        }
    }

    /// 存储属性 didSet：`(self, oldValue) -> Self`，返回 mutation 后的 self（调用方同步 invoke 后写回）。
    func compileDidSet(typeID t: Int, fieldType: SType, oldParam: String?, body: CodeBlockItemListSyntax, functionID: Int,
                       file: Int, name: String) {
        withFunction(id: functionID, name: "\(types[t].name).\(name).didSet", file: file, parent: nil) { b in
            b.staticTypeContext = t
            _ = selfVar(types[t], mutable: true)
            _ = declareLocal(oldParam ?? "oldValue", isLet: true, type: fieldType)
            b.paramCount = 2
            b.paramCoercions = [.none, coercion(for: fieldType)]
            b.returnType = .named(t, types[t].name)
            b.isMutating = true
            compileStatements(body)
            emit(.loadLocal(0))
            emit(.ret)
        }
    }

    /// 全局变量 / static 存储属性 didSet：`(oldValue) -> Void`（全局读写直达存储，无 self 拷贝问题）。
    func compileGlobalDidSet(oldParam: String?, fieldType: SType, body: CodeBlockItemListSyntax, functionID: Int, file: Int,
                             name: String) {
        withFunction(id: functionID, name: "\(name).didSet", file: file, parent: nil) { b in
            _ = declareLocal(oldParam ?? "oldValue", isLet: true, type: fieldType)
            b.paramCount = 1
            b.paramCoercions = [coercion(for: fieldType)]
            b.returnType = .void
            compileStatements(body)
            emit(.pushVoid)
            emit(.ret)
        }
    }

    func compileFunc(_ fn: FuncDecl, inType t: TypeDecl?) {
        guard let body = fn.node.body else { return }
        let name = t.map { "\($0.name).\(fn.fullName)" } ?? fn.fullName
        withFunction(id: fn.functionID, name: name, file: fn.fileIndex, parent: nil) { b in
            b.staticTypeContext = t?.id
            var coercions: [ParamCoercion] = []
            if let t, !fn.isStatic {
                _ = selfVar(t, mutable: fn.isMutating)
                b.isMutating = fn.isMutating
                coercions.append(.none)
            }
            for p in fn.params {
                // inout 形参在函数体内可赋值（调用方装箱传入，写穿回原处）
                _ = declareLocal(p.name, isLet: !p.isInout, type: p.type)
                coercions.append(coercion(for: p.type))
            }
            b.paramCount = coercions.count
            b.paramCoercions = coercions
            b.returnType = fn.returnType
            compileFunctionBody(body.statements, returnType: fn.returnType, builder: fn.isViewBuilder)
        }
    }

    func compileInit(_ i: InitDecl, in t: TypeDecl) {
        guard let body = i.node.body else { return }
        withFunction(id: i.functionID, name: "\(t.name).\(fullName("init", i.labels))", file: i.fileIndex, parent: nil) { b in
            b.staticTypeContext = t.id
            b.isInit = true
            _ = selfVar(t, mutable: true)
            var coercions: [ParamCoercion] = [.none]
            for p in i.params {
                _ = declareLocal(p.name, isLet: !p.isInout, type: p.type)
                coercions.append(coercion(for: p.type))
            }
            b.paramCount = coercions.count
            b.paramCoercions = coercions
            b.returnType = .void
            compileStatements(body.statements)
            emit(.loadLocal(0))
            emit(.ret)
        }
    }

    /// 编译函数体：@ViewBuilder 体、单表达式隐式返回或普通语句序列。
    func compileFunctionBody(_ items: CodeBlockItemListSyntax, returnType: SType, builder: Bool) {
        if builder && (returnType == .view || !returnType.isKnown) {
            fb.isBuilder = true
            compileBuilderBlock(items)
            emit(.ret)
            return
        }
        if returnType != .void, items.count == 1, let first = items.first, case .expr(let e) = first.item, !isStatementLike(e) {
            withLoc(e) {
                let t = compileExpr(e, expected: returnType)
                checkAssignable(returnType, t, e)
                emit(.ret)
            }
            return
        }
        compileStatements(items)
        if returnType == .void || !returnType.isKnown {
            emit(.pushVoid)
            emit(.ret)
        } else {
            emit(.trap("函数执行到末尾但没有 return（Swift 要求非 Void 函数的每条路径都返回值）"))
        }
    }

    func isStatementLike(_ e: ExprSyntax) -> Bool {
        if e.is(IfExprSyntax.self) || e.is(SwitchExprSyntax.self) { return true }
        if let infix = e.as(InfixOperatorExprSyntax.self) {
            if infix.operator.is(AssignmentExprSyntax.self) { return true }
            if let op = infix.operator.as(BinaryOperatorExprSyntax.self), compoundOps[op.operator.text] != nil { return true }
        }
        return false
    }

    // MARK: - 脚本入口

    func compileScript() {
        let items = topLevelItems.filter { isScriptFile($0.file) }
        let hasStatements = items.contains { if case .decl = $0.item.item { return false }; return true }
        guard hasStatements, let file = items.first?.file else { return }
        use("syntax.topLevelCode")
        let id = allocFunction()
        scriptFunction = id
        scriptFileIndex = file
        withFunction(id: id, name: "main.swift 顶层代码", file: file, parent: nil) { b in
            compilingScriptTopLevel = true
            for (_, item) in items { compileItem(item) }
            compilingScriptTopLevel = false
            emit(.pushVoid)
            emit(.ret)
        }
    }

    func compileTopLevelVar(_ v: VariableDeclSyntax) {
        for binding in v.bindings {
            if let tp = binding.pattern.as(TuplePatternSyntax.self) {
                compileTopLevelTuple(tp, binding: binding)
                continue
            }
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                  let gid = globalByName[ident.identifier.text] else { continue }
            let g = globals[gid]
            if let initExpr = binding.initializer?.value {
                let expected: SType? = g.type.isKnown ? g.type : nil
                let t = compileExpr(initExpr, expected: expected)
                if let expected { checkAssignable(expected, t, initExpr) } else { g.type = t }
                emit(.storeGlobal(gid))
            } else if g.type.isOptional {
                emit(.pushNil)
                emit(.storeGlobal(gid))
            }
        }
    }

    /// 顶层 `let (a, b) = …`：求值一次，按顺序存入各元素全局变量（索引期已登记）。
    func compileTopLevelTuple(_ tp: TuplePatternSyntax, binding: PatternBindingSyntax) {
        use("syntax.tuplePattern")
        let elems = Array(tp.elements)
        guard let initExpr = binding.initializer?.value else { return }
        let annotated: SType? = binding.typeAnnotation.map { resolveType($0.type, file: fb.fileIndex, selfType: currentSelfTypeID) }
        let t = compileExpr(initExpr, expected: annotated)
        if t.isKnown, !( { if case .tuple(let ts, _) = t { return ts.count == elems.count }; return false }() ) {
            error(.typeCheck, "解构声明的初始值应为 \(elems.count) 元组，得到 '\(t)'。", initExpr)
        }
        emit(.destructure(elems.count))
        var gids: [Int?] = []
        for el in elems {
            if let id = el.pattern.as(IdentifierPatternSyntax.self), let gid = globalByName[id.identifier.text] {
                gids.append(gid)
            } else {
                gids.append(nil)
            }
        }
        for gid in gids.reversed() {
            if let gid { emit(.storeGlobal(gid)) } else { emit(.pop) }
        }
    }

    // MARK: - @main App

    func compileAppRoot() {
        guard let app = types.first(where: \.isMain) else { return }
        guard app.isApp else {
            unsupported("非 App 的 @main 类型（static func main 入口）", app.node, "syntax.mainApp", file: app.fileIndex)
            return
        }
        guard let body = app.sceneBody else {
            error(.typeCheck, "@main App '\(app.name)' 缺少 `var body: some Scene`。", app.node, file: app.fileIndex, capability: "syntax.mainApp")
            return
        }
        if !app.fields.isEmpty {
            unsupported("App 类型中的存储属性", app.fields[0].node, "syntax.mainApp", file: app.fileIndex)
        }
        let stmts = Array(body)
        guard stmts.count == 1, case .expr(let e) = stmts[0].item, let call = e.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self), callee.baseName.text == "WindowGroup",
              let content = call.trailingClosure, call.additionalTrailingClosures.isEmpty,
              call.arguments.count <= 1 else {
            unsupported("此种 Scene 结构（当前只支持单个 WindowGroup { 根视图 }）", body, "syntax.mainApp", file: app.fileIndex)
            return
        }
        use("syntax.mainApp")
        let id = allocFunction()
        appRootFunction = id
        withFunction(id: id, name: "\(app.name).body.WindowGroup", file: app.fileIndex, parent: nil) { b in
            b.isBuilder = true
            b.staticTypeContext = app.id
            compileBuilderBlock(content.statements)
            emit(.ret)
        }
    }

    // MARK: - 入口点

    func computeEntryPoints() {
        if scriptFunction != nil, let f = scriptFileIndex { entryPoints.append(.script(files[f].source.id)) }
        if appRootFunction != nil { entryPoints.append(.mainApp) }
        for t in types where t.isView && isDefaultConstructible(t) {
            entryPoints.append(.rootView(symbol: t.name))
        }
    }

    func isDefaultConstructible(_ t: TypeDecl) -> Bool {
        if t.inits.contains(where: { $0.params.allSatisfy { $0.defaultValue != nil } }) { return true }
        if t.hasInitInBody { return false }
        return t.fields.allSatisfy { $0.initializer != nil || $0.type.isOptional && !$0.isLet }
    }
}
