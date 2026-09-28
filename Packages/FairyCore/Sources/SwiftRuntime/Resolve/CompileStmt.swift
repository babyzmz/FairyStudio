import RuntimeContracts
import SwiftSyntax

let compoundOps: [String: BinOp] = [
    "+=": .add, "-=": .sub, "*=": .mul, "/=": .div, "%=": .rem,
    "&=": .bitAnd, "|=": .bitOr, "^=": .bitXor, "<<=": .shl, ">>=": .shr,
    "&+=": .wrapAdd, "&-=": .wrapSub, "&*=": .wrapMul,
]

extension Compiler {
    func compileStatements(_ items: CodeBlockItemListSyntax) {
        for item in items { compileItem(item) }
    }

    func compileItem(_ item: CodeBlockItemSyntax) {
        withLoc(item) {
            switch item.item {
            case .decl(let d): compileLocalDecl(d)
            case .stmt(let s): compileStmt(s)
            case .expr(let e): compileExprStatement(e)
            }
        }
    }

    func compileBlock(_ block: CodeBlockSyntax) {
        fb.pushScope()
        compileStatements(block.statements)
        fb.popScope()
    }

    // MARK: - 声明

    func compileLocalDecl(_ d: DeclSyntax) {
        if let v = d.as(VariableDeclSyntax.self) {
            if compilingScriptTopLevel && fb.scopes.count == 1 && fb.parent == nil {
                compileTopLevelVar(v)
            } else {
                compileLocalVar(v)
            }
        } else if let fn = d.as(FunctionDeclSyntax.self) {
            if compilingScriptTopLevel && fb.scopes.count == 1 && fb.parent == nil { return }  // main.swift 顶层函数已作为全局函数编译
            compileNestedFunc(fn)
        } else if d.is(StructDeclSyntax.self) || d.is(EnumDeclSyntax.self) || d.is(ClassDeclSyntax.self) {
            if compilingScriptTopLevel && fb.scopes.count == 1 && fb.parent == nil { return }
            unsupported("局部类型声明", d, "syntax.nestedType")
        } else if d.is(ImportDeclSyntax.self) || d.is(ExtensionDeclSyntax.self) || d.is(ProtocolDeclSyntax.self)
                    || d.is(TypeAliasDeclSyntax.self) || d.is(ActorDeclSyntax.self) {
            if compilingScriptTopLevel && fb.scopes.count == 1 && fb.parent == nil { return }
            unsupported("局部声明", d, "syntax.declaration")
        } else {
            unsupported("此类局部声明", d, "syntax.declaration")
        }
    }

    func compileLocalVar(_ v: VariableDeclSyntax) {
        for attr in v.attributes {
            if let a = attr.as(AttributeSyntax.self) {
                unsupported("局部变量上的属性 @\(a.attributeName.trimmedDescription)", a, "syntax.attribute")
            }
        }
        let isLet = v.bindingSpecifier.tokenKind == .keyword(.let)
        use(isLet ? "syntax.let" : "syntax.var")
        for binding in v.bindings {
            if binding.accessorBlock != nil {
                unsupported("局部计算变量", binding, "syntax.globalComputed")
                continue
            }
            let annotated: SType? = binding.typeAnnotation.map { resolveType($0.type, file: fb.fileIndex, selfType: currentSelfTypeID) }
            if annotated != nil { use("syntax.typeAnnotation") }
            if binding.pattern.is(WildcardPatternSyntax.self) {
                if let e = binding.initializer?.value {
                    _ = compileExpr(e, expected: annotated)
                    emit(.pop)
                }
                continue
            }
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                if let tp = binding.pattern.as(TuplePatternSyntax.self) {
                    compileTupleDestructure(tp, binding: binding, isLet: isLet, annotated: annotated)
                    continue
                }
                unsupported("元组模式 / 解构声明", binding.pattern, "syntax.tuplePattern")
                for n in patternNames(binding.pattern) { _ = declareLocal(n, isLet: isLet, type: .unknown) }
                continue
            }
            let name = ident.identifier.text
            if let e = binding.initializer?.value {
                let t = compileExpr(e, expected: annotated)
                if let annotated { checkAssignable(annotated, t, e) }
                if t == .void && annotated == nil { warning("常量 '\(name)' 被推断为 Void 类型。", ident) }
                let local = declareLocal(name, isLet: isLet, type: annotated ?? t)
                emit(.initLocal(local.slot))
            } else {
                guard let annotated else {
                    error(.typeCheck, "变量 '\(name)' 需要类型标注或初始值。", ident)
                    continue
                }
                let local = declareLocal(name, isLet: isLet, type: annotated)
                if annotated.isOptional && !isLet {
                    emit(.pushNil)
                    emit(.initLocal(local.slot))
                }
            }
        }
    }

    /// `let (a, b) = 元组` / `var (a, _, c): (Int, Double, String) = …`（扁平一层）。
    func compileTupleDestructure(_ tp: TuplePatternSyntax, binding: PatternBindingSyntax, isLet: Bool, annotated: SType?) {
        use("syntax.tuplePattern")
        let elems = Array(tp.elements)
        var names: [String?] = []
        var flat = true
        for el in elems {
            if let id = el.pattern.as(IdentifierPatternSyntax.self) { names.append(id.identifier.text) }
            else if el.pattern.is(WildcardPatternSyntax.self) { names.append(nil) }
            else { flat = false; break }
        }
        var annoElems: [SType]?
        if let annotated {
            if case .tuple(let ts, _) = annotated, ts.count == elems.count { annoElems = ts }
            else if let ta = binding.typeAnnotation {
                error(.typeCheck, "解构声明的类型标注应为 \(elems.count) 元组，得到 '\(annotated)'。", ta)
            }
        }
        guard flat, let initExpr = binding.initializer?.value else {
            if flat {
                error(.typeCheck, "解构声明 '\(binding.pattern.trimmedDescription)' 需要初始值。", binding.pattern)
            } else {
                unsupported("嵌套元组模式", binding.pattern, "syntax.tuplePattern")
            }
            for n in patternNames(binding.pattern) { _ = declareLocal(n, isLet: isLet, type: .unknown) }
            return
        }
        let rhsT = compileExpr(initExpr, expected: annotated)
        var rhsElems: [SType]?
        if case .tuple(let ts, _) = rhsT, ts.count == elems.count { rhsElems = ts }
        if rhsT.isKnown && rhsElems == nil {
            error(.typeCheck, "解构声明的初始值应为 \(elems.count) 元组，得到 '\(rhsT)'。", initExpr)
        }
        if let annotated { checkAssignable(annotated, rhsT, initExpr) }
        emit(.destructure(elems.count))
        var slots: [Int?] = []
        for (i, n) in names.enumerated() {
            let t = annoElems?[i] ?? rhsElems?[i] ?? .unknown
            if let n { slots.append(declareLocal(n, isLet: isLet, type: t).slot) } else { slots.append(nil) }
        }
        for s in slots.reversed() {
            if let s { emit(.initLocal(s)) } else { emit(.pop) }
        }
    }

    func compileNestedFunc(_ fn: FunctionDeclSyntax) {        use("syntax.function.nested")
        guard let decl = makeFuncDecl(fn, file: fb.fileIndex, inType: nil), let body = fn.body else { return }
        for p in decl.params where p.defaultValue != nil {
            unsupported("嵌套函数的默认参数", p.defaultValue!, "syntax.function.defaultArguments")
        }
        let ps = decl.params.map { p in p.typeSyntax.map { resolveType($0, file: fb.fileIndex, selfType: currentSelfTypeID) } ?? .unknown }
        let ret = fn.signature.returnClause.map { resolveType($0.type, file: fb.fileIndex, selfType: currentSelfTypeID) } ?? .void
        let local = declareLocal(decl.baseName, isLet: true, type: .function(ps, ret), byRef: true)
        let id = allocFunction()
        var caps: [CaptureSource] = []
        let parent = fb
        withFunction(id: id, name: decl.fullName, file: fb.fileIndex, parent: parent) { b in
            for (i, p) in decl.params.enumerated() { _ = declareLocal(p.name, isLet: !p.isInout, type: ps[i]) }
            b.paramCount = decl.params.count
            b.paramCoercions = ps.map { coercion(for: $0) }
            b.returnType = ret
            compileFunctionBody(body.statements, returnType: ret, builder: decl.isViewBuilder)
            caps = b.captures
        }
        emit(.makeClosure(function: id, captures: caps))
        emit(.storeLocal(local.slot))
    }

    /// 当前 self 的类型 id（实例方法 / 闭包内）或静态上下文类型。
    var currentSelfTypeID: Int? {
        if case .named(let t, _)? = fb.peek("self")?.type { return t }
        return fb.enclosingStaticType
    }

    // MARK: - 语句

    func compileStmt(_ s: StmtSyntax) {
        if let es = s.as(ExpressionStmtSyntax.self) {
            compileExprStatement(es.expression)
        } else if let r = s.as(ReturnStmtSyntax.self) {
            compileReturn(r)
        } else if let g = s.as(GuardStmtSyntax.self) {
            compileGuard(g)
        } else if let f = s.as(ForStmtSyntax.self) {
            compileFor(f)
        } else if let w = s.as(WhileStmtSyntax.self) {
            compileWhile(w)
        } else if let r = s.as(RepeatStmtSyntax.self) {
            compileRepeat(r)
        } else if let b = s.as(BreakStmtSyntax.self) {
            if let label = b.label {
                unsupported("带标签的 break", label, "syntax.labeledStatement")
                return
            }
            use("syntax.break")
            guard !fb.breakables.isEmpty else {
                error(.typeCheck, "break 只能出现在循环或 switch 中。", b)
                return
            }
            let p = emitJump { .jump($0) }
            fb.breakables[fb.breakables.count - 1].breakPatches.append(p)
        } else if let c = s.as(ContinueStmtSyntax.self) {
            if let label = c.label {
                unsupported("带标签的 continue", label, "syntax.labeledStatement")
                return
            }
            use("syntax.continue")
            guard let idx = fb.breakables.lastIndex(where: \.isLoop) else {
                error(.typeCheck, "continue 只能出现在循环中。", c)
                return
            }
            let p = emitJump { .jump($0) }
            fb.breakables[idx].continuePatches.append(p)
        } else if let d = s.as(DoStmtSyntax.self) {
            if !d.catchClauses.isEmpty || d.throwsClause != nil {
                unsupported("do-catch 错误处理", d, "syntax.errorHandling")
                return
            }
            compileBlock(d.body)
        } else if s.is(ThrowStmtSyntax.self) {
            unsupported("throw 错误处理", s, "syntax.errorHandling")
        } else if s.is(DeferStmtSyntax.self) {
            unsupported("defer", s, "syntax.defer")
        } else if s.is(FallThroughStmtSyntax.self) {
            unsupported("fallthrough", s, "syntax.fallthrough")
        } else if s.is(LabeledStmtSyntax.self) {
            unsupported("带标签的语句", s, "syntax.labeledStatement")
        } else {
            unsupported("此类语句", s, "syntax.statement")
        }
    }

    func compileExprStatement(_ e: ExprSyntax) {
        if let i = e.as(IfExprSyntax.self) {
            withLoc(i) { compileIfStatement(i) }
            return
        }
        if let sw = e.as(SwitchExprSyntax.self) {
            withLoc(sw) { compileSwitch(sw, builder: false) }
            return
        }
        if let infix = e.as(InfixOperatorExprSyntax.self) {
            if infix.operator.is(AssignmentExprSyntax.self) {
                withLoc(infix) { compileAssignment(infix) }
                return
            }
            if let op = infix.operator.as(BinaryOperatorExprSyntax.self), let bop = compoundOps[op.operator.text] {
                withLoc(infix) { compileCompound(infix, bop) }
                return
            }
        }
        _ = compileExpr(e, expected: nil)
        emit(.pop)
    }

    func compileReturn(_ r: ReturnStmtSyntax) {
        if fb.isInit {
            if let e = r.expression { error(.typeCheck, "init 中的 return 不能带值。", e) }
            emit(.loadLocal(0))
            emit(.ret)
            return
        }
        if let e = r.expression {
            let expected: SType? = fb.returnType.isKnown ? fb.returnType : nil
            let t = compileExpr(e, expected: expected)
            if let expected { checkAssignable(expected, t, e) } else if fb.parent != nil, !fb.returnType.isKnown {
                inferredClosureReturn[fb.id] = t
            }
            if fb.returnType == .void {
                error(.typeCheck, "Void 函数不能返回值。", e)
            }
        } else {
            if fb.returnType.isKnown && fb.returnType != .void {
                error(.typeCheck, "非 Void 函数的 return 需要返回值。", r)
            }
            emit(.pushVoid)
        }
        emit(.ret)
    }

    // MARK: - 条件

    /// 编译条件列表；返回"条件不成立"时需要回填的跳转。可选绑定声明在当前作用域。
    func compileConditions(_ conds: ConditionElementListSyntax) -> [Int] {
        var fails: [Int] = []
        for c in conds {
            switch c.condition {
            case .expression(let e):
                let t = compileExpr(e, expected: .bool)
                if t.isKnown && t != .bool {
                    error(.typeCheck, "条件必须是 Bool，得到 '\(t)'。", e)
                }
                fails.append(emitJump { .jumpIfFalse($0) })
            case .optionalBinding(let ob):
                use("syntax.optional.binding")
                guard let ident = ob.pattern.as(IdentifierPatternSyntax.self) else {
                    unsupported("可选绑定中的复杂模式", ob.pattern, "syntax.tuplePattern")
                    continue
                }
                let name = ident.identifier.text
                let annotated = ob.typeAnnotation.map { resolveType($0.type, file: fb.fileIndex, selfType: currentSelfTypeID) }
                let t: SType
                if let initExpr = ob.initializer?.value {
                    t = compileExpr(initExpr, expected: annotated.map { .optional($0) })
                } else {
                    t = withLoc(ident) { compileIdentifierLoad(name, node: Syntax(ident), expected: nil) }
                }
                if t.isKnown && !t.isOptional {
                    error(.typeCheck, "条件绑定的初始值必须是 Optional 类型，得到 '\(t)'。", ob)
                }
                let ok = emitJump { .jumpIfNotNil($0) }
                emit(.pop)
                fails.append(emitJump { .jump($0) })
                patch(ok, to: here)
                let isLet = ob.bindingSpecifier.tokenKind == .keyword(.let)
                let local = declareLocal(name, isLet: isLet, type: annotated ?? t.unwrapped)
                emit(.initLocal(local.slot))
            case .matchingPattern(let mp):
                // if case .x = value
                let t = compileExpr(mp.initializer.value, expected: nil)
                let slot = hiddenLocal()
                emit(.initLocal(slot))
                compilePatternTest(mp.pattern, subjectSlot: slot, subjectType: t)
                fails.append(emitJump { .jumpIfFalse($0) })
            case .availability(let a):
                unsupported("#available 检查", a, "syntax.availability")
            }
        }
        return fails
    }

    func compileIfStatement(_ i: IfExprSyntax) {
        use("syntax.if")
        fb.pushScope()
        let fails = compileConditions(i.conditions)
        compileBlock(i.body)
        fb.popScope()
        guard let elseBody = i.elseBody else {
            for f in fails { patch(f, to: here) }
            return
        }
        let end = emitJump { .jump($0) }
        for f in fails { patch(f, to: here) }
        switch elseBody {
        case .ifExpr(let nested): withLoc(nested) { compileIfStatement(nested) }
        case .codeBlock(let block): compileBlock(block)
        }
        patch(end, to: here)
    }

    func compileGuard(_ g: GuardStmtSyntax) {
        use("syntax.guard")
        let fails = compileConditions(g.conditions)
        let ok = emitJump { .jump($0) }
        for f in fails { patch(f, to: here) }
        compileBlock(g.body)
        if !blockExits(g.body.statements) {
            error(.typeCheck, "guard 的 else 分支必须退出当前作用域（return、break、continue 或 fatalError）。", g.guardKeyword)
        }
        emit(.trap("guard 的 else 分支没有退出作用域"))
        patch(ok, to: here)
    }

    func blockExits(_ items: CodeBlockItemListSyntax) -> Bool {
        guard let last = items.last else { return false }
        switch last.item {
        case .stmt(let s):
            if s.is(ReturnStmtSyntax.self) || s.is(BreakStmtSyntax.self) || s.is(ContinueStmtSyntax.self) || s.is(ThrowStmtSyntax.self) {
                return true
            }
            if let es = s.as(ExpressionStmtSyntax.self) { return exprExits(es.expression) }
            return false
        case .expr(let e): return exprExits(e)
        case .decl: return false
        }
    }

    func exprExits(_ e: ExprSyntax) -> Bool {
        if let call = e.as(FunctionCallExprSyntax.self), let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text == "fatalError"
        }
        if let i = e.as(IfExprSyntax.self), let elseBody = i.elseBody {
            guard blockExits(i.body.statements) else { return false }
            switch elseBody {
            case .codeBlock(let b): return blockExits(b.statements)
            case .ifExpr(let n): return exprExits(ExprSyntax(n))
            }
        }
        return false
    }

    // MARK: - 循环

    func elementType(of t: SType) -> SType {
        switch t {
        case .array(let e): return e
        case .range: return .int
        case .string: return .string
        case .dict(let k, let v): return .tuple([k, v], ["key", "value"])
        default: return .unknown
        }
    }

    func compileFor(_ f: ForStmtSyntax) {
        use("syntax.forIn")
        if f.tryKeyword != nil || f.awaitKeyword != nil {
            unsupported("for try/await", f, "syntax.asyncAwait")
            return
        }
        if f.caseKeyword != nil {
            unsupported("for case 模式", f, "syntax.tuplePattern")
            return
        }
        let seqType = compileExpr(f.sequence, expected: nil)
        if seqType.isKnown {
            switch seqType {
            case .array, .range, .string, .dict: break
            default: error(.typeCheck, "'\(seqType)' 不是可遍历的序列。", f.sequence)
            }
        }
        let elem = elementType(of: seqType)
        let iterSlot = hiddenLocal()
        emit(.iterMake(iterSlot))
        let loopStart = here
        let exit = emitJump { .iterNext(slot: iterSlot, exit: $0) }
        fb.pushScope()
        bindForPattern(f.pattern, elem)
        fb.breakables.append(Breakable(isLoop: true))
        var whereFail: Int?
        if let w = f.whereClause {
            use("syntax.forIn.where")
            _ = compileExpr(w.condition, expected: .bool)
            whereFail = emitJump { .jumpIfFalse($0) }
        }
        compileBlock(f.body)
        let continueTarget = here
        emit(.loop(loopStart))
        fb.popScope()
        let b = fb.breakables.removeLast()
        let end = here
        patch(exit, to: end)
        for p in b.breakPatches { patch(p, to: end) }
        for p in b.continuePatches { patch(p, to: continueTarget) }
        if let whereFail { patch(whereFail, to: continueTarget) }
    }

    func bindForPattern(_ pattern: PatternSyntax, _ elem: SType) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            let v = declareLocal(ident.identifier.text, isLet: true, type: elem)
            emit(.initLocal(v.slot))
        } else if pattern.is(WildcardPatternSyntax.self) {
            emit(.pop)
        } else if let vb = pattern.as(ValueBindingPatternSyntax.self), let ident = vb.pattern.as(IdentifierPatternSyntax.self) {
            let v = declareLocal(ident.identifier.text, isLet: vb.bindingSpecifier.tokenKind == .keyword(.let), type: elem)
            emit(.initLocal(v.slot))
        } else if let tp = pattern.as(TuplePatternSyntax.self) {
            // for (i, x) in arr.enumerated() / for (k, v) in dict
            use("syntax.forIn.tuplePattern")
            let n = tp.elements.count
            var ets: [SType] = Array(repeating: .unknown, count: n)
            if case .tuple(let ts, _) = elem, ts.count == n { ets = ts }
            emit(.destructure(n))
            var locals: [LocalVar?] = []
            for (i, el) in tp.elements.enumerated() {
                if let id = el.pattern.as(IdentifierPatternSyntax.self) {
                    locals.append(declareLocal(id.identifier.text, isLet: true, type: ets[i]))
                } else if el.pattern.is(WildcardPatternSyntax.self) {
                    locals.append(nil)
                } else {
                    unsupported("嵌套元组模式", el.pattern, "syntax.tuplePattern")
                    locals.append(nil)
                }
            }
            for l in locals.reversed() {
                if let l { emit(.initLocal(l.slot)) } else { emit(.pop) }
            }
        } else {
            unsupported("for-in 中的此种模式", pattern, "syntax.tuplePattern")
            emit(.pop)
        }
    }

    func compileWhile(_ w: WhileStmtSyntax) {
        use("syntax.while")
        let start = here
        fb.pushScope()
        let fails = compileConditions(w.conditions)
        fb.breakables.append(Breakable(isLoop: true))
        compileBlock(w.body)
        emit(.loop(start))
        fb.popScope()
        let b = fb.breakables.removeLast()
        let end = here
        for f in fails { patch(f, to: end) }
        for p in b.breakPatches { patch(p, to: end) }
        for p in b.continuePatches { patch(p, to: start) }
    }

    func compileRepeat(_ r: RepeatStmtSyntax) {
        use("syntax.repeatWhile")
        let start = here
        fb.breakables.append(Breakable(isLoop: true))
        compileBlock(r.body)
        let contTarget = here
        _ = compileExpr(r.condition, expected: .bool)
        let exit = emitJump { .jumpIfFalse($0) }
        emit(.loop(start))
        let b = fb.breakables.removeLast()
        let end = here
        patch(exit, to: end)
        for p in b.breakPatches { patch(p, to: end) }
        for p in b.continuePatches { patch(p, to: contTarget) }
    }

    // MARK: - switch

    /// builder 为 true 时每个分支编译为视图并以分支号包装（@ViewBuilder switch）。
    func compileSwitch(_ sw: SwitchExprSyntax, builder: Bool) {
        use("syntax.switch")
        if builder { use("view.ViewBuilder.switch") }
        let subjT = compileExpr(sw.subject, expected: nil)
        let subj = hiddenLocal()
        emit(.initLocal(subj))
        if !builder { fb.breakables.append(Breakable(isLoop: false)) }
        var nextCase: [Int] = []
        var defaultCase: SwitchCaseSyntax?
        var defaultIndex = 0
        var endPatches: [Int] = []
        var coveredCases = Set<Int>()
        var coveredBools = Set<Bool>()
        var hasCatchAll = false
        for (ci, entry) in sw.cases.enumerated() {
            guard case .switchCase(let sc) = entry else {
                unsupported("switch 中的 #if", entry, "syntax.ifConfig")
                continue
            }
            switch sc.label {
            case .default:
                defaultCase = sc
                defaultIndex = ci
                continue
            case .case(let label):
                for p in nextCase { patch(p, to: here) }
                nextCase = []
                fb.pushScope()
                var bodyPatches: [Int] = []
                for item in label.caseItems {
                    withLoc(item) {
                        compilePatternTest(item.pattern, subjectSlot: subj, subjectType: subjT)
                    }
                    if let w = item.whereClause {
                        use("syntax.switch.where")
                        let fail = emitJump { .jumpIfFalse($0) }
                        _ = compileExpr(w.condition, expected: .bool)
                        bodyPatches.append(emitJump { .jumpIfTrue($0) })
                        patch(fail, to: here)
                    } else {
                        bodyPatches.append(emitJump { .jumpIfTrue($0) })
                        noteCoverage(item.pattern, subjT, &coveredCases, &coveredBools, &hasCatchAll)
                    }
                }
                nextCase.append(emitJump { .jump($0) })
                for p in bodyPatches { patch(p, to: here) }
                if builder {
                    compileBuilderBlock(sc.statements)
                    emit(.wrapConditional(ci))
                } else {
                    if sc.statements.isEmpty { error(.typeCheck, "switch 的每个 case 至少要有一条语句（可用 break）。", sc) }
                    compileStatements(sc.statements)
                }
                endPatches.append(emitJump { .jump($0) })
                fb.popScope()
            }
        }
        for p in nextCase { patch(p, to: here) }
        if let d = defaultCase {
            fb.pushScope()
            if builder {
                compileBuilderBlock(d.statements)
                emit(.wrapConditional(defaultIndex))
            } else {
                compileStatements(d.statements)
            }
            fb.popScope()
        } else {
            checkExhaustive(sw, subjT, coveredCases, coveredBools, hasCatchAll)
            emit(.trap("switch 没有匹配的分支"))
        }
        let end = here
        for p in endPatches { patch(p, to: end) }
        if !builder {
            let b = fb.breakables.removeLast()
            for p in b.breakPatches { patch(p, to: end) }
        }
    }

    /// 带关联值的 enum case 模式：`.ok(let x)`、`R.err(0, let s)`、`case let .ok(x)`。
    /// 栈顶留 Bool；`let` 绑定在测试中直接声明并初始化（未命中分支时为 nil 占位，
    /// 但只有命中的分支体可达，故体内的绑定值正确；`enumPayload` 在 case 不符时压 nil 而非 trap）。
    func compileAssociatedCallPattern(_ call: FunctionCallExprSyntax, subjectSlot subj: Int, subjectType subjT: SType,
                                      forceLet: Bool = false) {
        use("syntax.enum.associatedValues")
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
            error(.typeCheck, "此种模式不是 enum case。", call.calledExpression)
            emit(.pushBool(false))
            return
        }
        let caseName = member.declName.baseName.text
        var tid: Int?
        if member.base == nil {
            if case .named(let t, _) = subjT, types[t].kind == .enumType { tid = t }
        } else if let b = member.base?.as(DeclReferenceExprSyntax.self), let t = typeByName[b.baseName.text],
                  types[t].kind == .enumType {
            tid = t
        }
        guard let tid else {
            error(.typeCheck, "无法把模式 '.\(caseName)(…)' 解析为 enum case（请确保 switch 的值是已知 enum 类型）。",
                  member.declName)
            emit(.pushBool(false))
            return
        }
        guard let idx = types[tid].caseIndex(caseName) else {
            error(.nameResolution, "enum '\(types[tid].name)' 没有 case '\(caseName)'。", member.declName)
            emit(.pushBool(false))
            return
        }
        let info = types[tid].cases[idx]
        if info.associated.isEmpty {
            error(.typeCheck, "case '.\(caseName)' 没有关联值，不能带括号匹配。", call)
            emit(.pushBool(false))
            return
        }
        let params = info.associated
        let args = Array(call.arguments)
        guard args.count == params.count else {
            error(.typeCheck, "case '.\(caseName)' 有 \(params.count) 个关联值，模式中给了 \(args.count) 个。", call)
            emit(.pushBool(false))
            return
        }
        for (i, a) in args.enumerated() {
            if a.label?.text != params[i].label {
                error(.typeCheck, "case '.\(caseName)' 第 \(i + 1) 个关联值的标签应为 '\(params[i].label ?? "_")'。", a)
            }
        }
        // 形参静态类型（绑定声明用）
        let paramTypes: [SType] = params.map { p in
            p.type.map { resolveType($0, file: fb.fileIndex, selfType: currentSelfTypeID) } ?? .unknown
        }
        // 分类：绑定 vs 值比较
        enum ArgKind { case bind(name: String, isLet: Bool); case skip; case value(ExprSyntax) }
        var kinds: [ArgKind] = []
        var ok = true
        for a in args {
            if let pat = a.expression.as(PatternExprSyntax.self) {
                let inner = pat.pattern
                if let vb = inner.as(ValueBindingPatternSyntax.self),
                   let id = vb.pattern.as(IdentifierPatternSyntax.self) {
                    kinds.append(.bind(name: id.identifier.text, isLet: vb.bindingSpecifier.tokenKind == .keyword(.let)))
                } else if let id = inner.as(IdentifierPatternSyntax.self) {
                    kinds.append(.bind(name: id.identifier.text, isLet: true))
                } else if inner.is(WildcardPatternSyntax.self) {
                    kinds.append(.skip)
                } else {
                    unsupported("关联值中的此种子模式", inner, "syntax.enum.associatedValues")
                    ok = false
                }
            } else if let ref = a.expression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "_" {
                kinds.append(.skip)
            } else if a.expression.is(DiscardAssignmentExprSyntax.self) {
                kinds.append(.skip)
            } else if forceLet, let ref = a.expression.as(DeclReferenceExprSyntax.self), ref.argumentNames == nil {
                kinds.append(.bind(name: ref.baseName.text, isLet: true))
            } else {
                kinds.append(.value(a.expression))
            }
        }
        guard ok else {
            emit(.pushBool(false))
            return
        }
        // 先声明绑定（槽位），测试成功后再初始化
        var slots: [Int?] = []
        for (i, k) in kinds.enumerated() {
            switch k {
            case .bind(let name, let isLet):
                slots.append(declareLocal(name, isLet: isLet, type: paramTypes[i]).slot)
            default:
                slots.append(nil)
            }
        }
        emit(.loadLocal(subj))
        emit(.matchEnumCase(type: tid, caseIndex: idx))
        var failJumps: [Int] = []
        failJumps.append(emitJump { .jumpIfFalse($0) })
        for (i, k) in kinds.enumerated() {
            if case .value(let e) = k {
                emit(.loadLocal(subj))
                emit(.enumPayload(index: i))
                let et = paramTypes[i]
                let lt = compileExpr(e, expected: et.isKnown ? et : nil)
                if et.isKnown && lt.isKnown && et.isConcreteScalar && lt.isConcreteScalar && et.unwrapped != lt.unwrapped {
                    error(.typeCheck, "关联值模式类型 '\(lt)' 与 case 声明 '\(et)' 不匹配。", e)
                }
                emit(.binary(.eq, .none))
                failJumps.append(emitJump { .jumpIfFalse($0) })
            }
        }
        for (i, s) in slots.enumerated() {
            if let s {
                emit(.loadLocal(subj))
                emit(.enumPayload(index: i))
                emit(.initLocal(s))
            }
        }
        emit(.pushBool(true))
        let end = emitJump { .jump($0) }
        for f in failJumps { patch(f, to: here) }
        emit(.pushBool(false))
        patch(end, to: here)
    }

    func noteCoverage(_ p: PatternSyntax, _ t: SType, _ cases: inout Set<Int>, _ bools: inout Set<Bool>, _ catchAll: inout Bool) {
        if p.is(WildcardPatternSyntax.self) { catchAll = true; return }
        if let vb = p.as(ValueBindingPatternSyntax.self) {
            // `case let .ok(x)`：内层若是带关联值的 case 也计入穷尽
            if let inner = vb.pattern.as(ExpressionPatternSyntax.self),
               let call = inner.expression.as(FunctionCallExprSyntax.self),
               let m = call.calledExpression.as(MemberAccessExprSyntax.self),
               case .named(let tid, _) = t, types[tid].kind == .enumType,
               let idx = types[tid].caseIndex(m.declName.baseName.text) {
                cases.insert(idx)
                return
            }
            if vb.pattern.is(IdentifierPatternSyntax.self) { catchAll = true }
            return
        }
        if p.is(WildcardPatternSyntax.self) { catchAll = true; return }
        if let vb = p.as(ValueBindingPatternSyntax.self), vb.pattern.is(IdentifierPatternSyntax.self) { catchAll = true; return }
        guard let ep = p.as(ExpressionPatternSyntax.self) else { return }
        if let b = ep.expression.as(BooleanLiteralExprSyntax.self) { bools.insert(b.literal.tokenKind == .keyword(.true)) }
        // 带关联值的 case 模式 `.ok(…)` 同样计入穷尽（where 子句的分支本就不计入，由调用方区分）
        if let call = ep.expression.as(FunctionCallExprSyntax.self),
           let m = call.calledExpression.as(MemberAccessExprSyntax.self),
           case .named(let tid, _) = t, types[tid].kind == .enumType,
           let idx = types[tid].caseIndex(m.declName.baseName.text) {
            cases.insert(idx)
            return
        }
        if case .named(let tid, _) = t, let m = ep.expression.as(MemberAccessExprSyntax.self),
           let idx = types[tid].caseIndex(m.declName.baseName.text) {
            cases.insert(idx)
        }
    }

    func checkExhaustive(_ sw: SwitchExprSyntax, _ t: SType, _ cases: Set<Int>, _ bools: Set<Bool>, _ catchAll: Bool) {
        if catchAll || !t.isKnown { return }
        if case .named(let tid, _) = t, types[tid].kind == .enumType {
            let missing = types[tid].cases.indices.filter { !cases.contains($0) }.map { "." + types[tid].cases[$0].name }
            if !missing.isEmpty {
                error(.typeCheck, "switch 必须穷尽：缺少 \(missing.joined(separator: "、"))（或添加 default）。", sw.switchKeyword)
            }
            return
        }
        if t == .bool && bools.count == 2 { return }
        error(.typeCheck, "switch 必须穷尽，请添加 default 分支。", sw.switchKeyword)
    }

    /// 编译一个模式测试：结果（Bool）留在栈顶；值绑定模式声明到当前作用域。
    func compilePatternTest(_ pattern: PatternSyntax, subjectSlot subj: Int, subjectType subjT: SType) {
        if pattern.is(WildcardPatternSyntax.self) {
            emit(.pushBool(true))
            return
        }
        if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            // `case let .ok(x)`：整个模式前缀 let/var，内层按绑定处理
            if let inner = vb.pattern.as(ExpressionPatternSyntax.self),
               let call = inner.expression.as(FunctionCallExprSyntax.self),
               call.calledExpression.is(MemberAccessExprSyntax.self) {
                compileAssociatedCallPattern(call, subjectSlot: subj, subjectType: subjT, forceLet: true)
                return
            }
            guard let ident = vb.pattern.as(IdentifierPatternSyntax.self) else {
                unsupported("带关联值绑定的模式", vb, "syntax.enum.associatedValues")
                emit(.pushBool(false))
                return
            }
            use("syntax.switch.valueBinding")
            let v = declareLocal(ident.identifier.text, isLet: vb.bindingSpecifier.tokenKind == .keyword(.let), type: subjT)
            emit(.loadLocal(subj))
            emit(.initLocal(v.slot))
            emit(.pushBool(true))
            return
        }
        guard let ep = pattern.as(ExpressionPatternSyntax.self) else {
            if pattern.is(TuplePatternSyntax.self) {
                unsupported("元组模式", pattern, "syntax.tuplePattern")
            } else if pattern.is(IsTypePatternSyntax.self) {
                unsupported("类型检查模式 is", pattern, "syntax.typeCasting")
            } else {
                unsupported("此种模式", pattern, "syntax.tuplePattern")
            }
            emit(.pushBool(false))
            return
        }
        let e = ep.expression
        // 枚举 case：.up 或 Direction.up
        if let m = e.as(MemberAccessExprSyntax.self) {
            let caseName = m.declName.baseName.text
            var enumType: Int?
            if m.base == nil {
                if case .named(let tid, _) = subjT, types[tid].kind == .enumType { enumType = tid }
            } else if let b = m.base?.as(DeclReferenceExprSyntax.self), let tid = typeByName[b.baseName.text], types[tid].kind == .enumType {
                enumType = tid
            }
            if let tid = enumType {
                guard let idx = types[tid].caseIndex(caseName) else {
                    error(.nameResolution, "enum '\(types[tid].name)' 没有 case '\(caseName)'。", m.declName)
                    emit(.pushBool(false))
                    return
                }
                emit(.loadLocal(subj))
                emit(.matchEnumCase(type: tid, caseIndex: idx))
                return
            }
            if m.base == nil && !subjT.isKnown {
                emit(.loadLocal(subj))
                emit(.matchSymbolCase(caseName))
                return
            }
        }
        if e.is(FunctionCallExprSyntax.self), let call = e.as(FunctionCallExprSyntax.self), call.calledExpression.is(MemberAccessExprSyntax.self) {
            compileAssociatedCallPattern(call, subjectSlot: subj, subjectType: subjT)
            return
        }
        if e.is(TupleExprSyntax.self), let t = e.as(TupleExprSyntax.self), t.elements.count > 1 {
            unsupported("元组模式", e, "syntax.tuplePattern")
            emit(.pushBool(false))
            return
        }
        // 区间模式
        if let infix = e.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           op.operator.text == "..." || op.operator.text == "..<" {
            _ = compileExpr(e, expected: nil)
            emit(.loadLocal(subj))
            emit(.rangeContains)
            return
        }
        // 表达式模式：subject == expr
        emit(.loadLocal(subj))
        let t = compileExpr(e, expected: subjT.isKnown ? subjT : nil)
        if subjT.isKnown && t.isKnown && subjT.unwrapped != t.unwrapped && subjT.isConcreteScalar && t.isConcreteScalar {
            error(.typeCheck, "case 模式类型 '\(t)' 与 switch 值类型 '\(subjT)' 不匹配。", e)
        }
        emit(.binary(.eq, .none))
    }
}
