import RuntimeContracts
import SwiftSyntax

/// @ViewBuilder 专门支持：语句序列 → 视图组；if/else、switch → 带分支号的条件视图；ForEach 为内建视图。
/// 这不是通用 result builder。
extension Compiler {
    /// 编译一段 @ViewBuilder 语句，压入恰好一个视图值。
    func compileBuilderBlock(_ items: CodeBlockItemListSyntax) {
        use("view.ViewBuilder")
        let savedBuilder = fb.isBuilder
        fb.isBuilder = true
        fb.pushScope()
        var n = 0
        for item in items {
            withLoc(item) {
                switch item.item {
                case .decl(let d):
                    if let v = d.as(VariableDeclSyntax.self) {
                        compileLocalVar(v)
                    } else {
                        unsupported("@ViewBuilder 中的此类声明", d, "view.ViewBuilder")
                    }
                case .expr(let e):
                    n += compileBuilderExpr(e)
                case .stmt(let s):
                    if let es = s.as(ExpressionStmtSyntax.self) {
                        n += compileBuilderExpr(es.expression)
                    } else if s.is(ForStmtSyntax.self) {
                        error(.unsupportedSyntax, "@ViewBuilder 中不能使用 for 循环；请改用 ForEach。", s, capability: "view.ViewBuilder",
                              suggestion: "ForEach(items, id: \\.self) { item in … }")
                    } else if s.is(ReturnStmtSyntax.self) {
                        unsupported("@ViewBuilder 中的 return", s, "view.ViewBuilder")
                    } else {
                        unsupported("@ViewBuilder 中的此类语句", s, "view.ViewBuilder")
                    }
                }
            }
        }
        fb.popScope()
        emit(.makeViewGroup(n))
        fb.isBuilder = savedBuilder
    }

    func compileBuilderExpr(_ e: ExprSyntax) -> Int {
        if let i = e.as(IfExprSyntax.self) {
            withLoc(i) { compileBuilderIf(i) }
            return 1
        }
        if let sw = e.as(SwitchExprSyntax.self) {
            withLoc(sw) { compileSwitch(sw, builder: true) }
            return 1
        }
        if let infix = e.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
            error(.typeCheck, "@ViewBuilder 中不能写赋值语句。", e)
            return 0
        }
        let t = compileExpr(e, expected: .view)
        if t.isKnown && !isViewType(t) && t != .symbol {
            error(.typeCheck, "@ViewBuilder 中的表达式必须是 View，得到 '\(t)'。", e)
        }
        return 1
    }

    func compileBuilderIf(_ i: IfExprSyntax) {
        use("view.ViewBuilder.if")
        fb.pushScope()
        let fails = compileConditions(i.conditions)
        compileBuilderBlock(i.body.statements)
        emit(.wrapConditional(0))
        fb.popScope()
        let end = emitJump { .jump($0) }
        for f in fails { patch(f, to: here) }
        switch i.elseBody {
        case nil:
            emit(.makeViewGroup(0))
        case .ifExpr(let nested):
            withLoc(nested) { compileBuilderIf(nested) }
        case .codeBlock(let block):
            compileBuilderBlock(block.statements)
        }
        emit(.wrapConditional(1))
        patch(end, to: here)
    }

    // MARK: - 视图构造

    func matchViewSig(_ sig: [ViewParam], _ args: [CallArg]) -> [Int?]? {
        var mapping = [Int?](repeating: nil, count: sig.count)
        var pi = 0
        for (ai, a) in args.enumerated() where !a.isTrailing {
            while pi < sig.count && sig[pi].label != a.label {
                if !sig[pi].optional { return nil }
                pi += 1
            }
            guard pi < sig.count else { return nil }
            mapping[pi] = ai
            pi += 1
        }
        var first = true
        for (ai, a) in args.enumerated() where a.isTrailing {
            if first && a.label == nil {
                while pi < sig.count && !sig[pi].kind.isClosure {
                    if !sig[pi].optional { return nil }
                    pi += 1
                }
                guard pi < sig.count else { return nil }
                mapping[pi] = ai
                pi += 1
            } else {
                guard let idx = (pi..<sig.count).first(where: { sig[$0].label == a.label }) else { return nil }
                for j in pi..<idx where !sig[j].optional { return nil }
                mapping[idx] = ai
                pi = idx + 1
            }
            first = false
        }
        for j in 0..<sig.count where mapping[j] == nil && !sig[j].optional { return nil }
        return mapping
    }

    func compileViewConstruct(_ name: String, args: [CallArg], node: Syntax, call: FunctionCallExprSyntax) -> SType {
        let cap = viewCapability(name)
        use(cap)
        let sigs = viewSignatures[name] ?? []
        var chosen: ([ViewParam], [Int?])?
        for s in sigs {
            if let m = matchViewSig(s, args) { chosen = (s, m); break }
        }
        guard let (sig, mapping) = chosen else {
            let forms = sigs.map { s in name + "(" + s.map { p in (p.label ?? "_") + ":" + (p.optional ? "?" : "") }.joined(separator: " ") + ")" }
            error(.typeCheck, "\(name) 的参数组合不受支持。支持的形式：\(forms.joined(separator: "；"))。", call, capability: cap)
            emit(.pushVoid)
            return .view
        }
        var labels: [String?] = []
        var dataElem: SType = .unknown
        var hasID = false
        for (pi, p) in sig.enumerated() {
            guard let ai = mapping[pi] else { continue }
            let a = args[ai]
            labels.append(p.label)
            switch p.kind {
            case .string:
                let t = compileExpr(a.expr, expected: .string)
                if t.isKnown && t != .string {
                    error(.typeCheck, "\(name) 需要 String 参数，得到 '\(t)'（可用字符串插值 \"\\(x)\"）。", a.expr)
                }
            case .number:
                let t = compileExpr(a.expr, expected: .double)
                if t.isKnown && !t.isNumeric && t != .symbol { error(.typeCheck, "\(name) 的 \(p.label ?? "参数") 需要数值。", a.expr) }
            case .bool:
                compileExpr(a.expr, expected: .bool)
            case .symbol:
                compileExpr(a.expr, expected: .symbol)
            case .binding:
                let t = compileExpr(a.expr, expected: nil)
                if t.isKnown, case .binding = t {} else if t.isKnown {
                    error(.typeCheck, "\(name) 的 \(p.label ?? "参数") 需要 Binding，请使用 $变量（例如 $name）。", a.expr)
                }
            case .keyPath:
                hasID = true
                compileExpr(a.expr, expected: nil)
            case .data:
                let t = compileExpr(a.expr, expected: nil)
                dataElem = elementType(of: t)
                if t.isKnown {
                    switch t {
                    case .array, .range: break
                    default: error(.typeCheck, "\(name) 的数据需要数组或 Range，得到 '\(t)'。", a.expr)
                    }
                }
            case .view:
                guard let c = a.closure else {
                    error(.typeCheck, "\(name) 的 \(p.label ?? "内容") 需要一个 { … } 视图闭包。", a.expr)
                    emit(.pushVoid)
                    continue
                }
                if c.signature != nil {
                    error(.typeCheck, "\(name) 的内容闭包不接受参数。", c)
                }
                compileBuilderBlock(c.statements)
            case .action:
                _ = compileArgValue(a, expected: .function([], .void))
            case .rowBuilder:
                guard let c = a.closure else {
                    error(.typeCheck, "\(name) 的行内容需要一个 { item in … } 闭包。", a.expr)
                    emit(.pushVoid)
                    continue
                }
                _ = compileClosure(c, expected: .function([dataElem], .view), builder: true)
            case .any:
                compileExpr(a.expr, expected: nil)
            }
        }
        if (name == "ForEach" || name == "List"), sig.contains(where: { $0.kind == .data }), !hasID {
            checkIdentifiable(dataElem, node: call, viewName: name)
        }
        emit(.callBuiltin(name: name, labels: labels))
        return name == "Color" ? .symbol : .view
    }

    func checkIdentifiable(_ elem: SType, node: some SyntaxProtocol, viewName: String) {
        switch elem {
        case .unknown, .int:
            return
        case .named(let tid, _):
            let t = types[tid]
            if t.field("id") != nil || t.computedProp("id") != nil { return }
            error(.typeCheck, "\(viewName) 需要 id: 参数，或元素类型 '\(t.name)' 遵循 Identifiable（提供 id 属性）。", node)
        default:
            error(.typeCheck, "\(viewName) 的元素类型 '\(elem)' 不是 Identifiable，请提供 id: \\.self。", node)
        }
    }

    // MARK: - 修饰符

    func compileModifierCall(_ base: ExprSyntax, _ name: String, args: [CallArg], node: MemberAccessExprSyntax) -> SType {
        guard let sig = modifierSignatures[name] else {
            unsupportedAPI("修饰符 .\(name)(…)", node.declName, "modifier.\(name)")
            emit(.pushVoid)
            return .view
        }
        let cap = name == "foregroundStyle" ? "modifier.foregroundStyle" : "modifier.\(name)"
        use(cap)
        var labels: [String?] = []
        for a in args {
            if a.isTrailing && a.label == nil {
                labels.append(name == "onAppear" || name == "onDisappear" ? "perform" : nil)
            } else {
                labels.append(a.label)
            }
        }
        var ok: Bool
        if name == "frame" {
            let ls = labels.compactMap { $0 }
            ok = ls.count == labels.count && !ls.isEmpty
            var lastIdx = -1
            for l in ls {
                guard let idx = frameLabelOrder.firstIndex(of: l), idx > lastIdx else { ok = false; break }
                lastIdx = idx
            }
        } else {
            ok = sig.labelSets.contains(labels)
        }
        if !ok {
            error(.unsupportedAPI, "修饰符 .\(fullName(name, labels)) 的参数形式运行时尚不支持。", node.declName, capability: cap)
            emit(.pushVoid)
            return .view
        }
        let bt = compileChainBase(base)
        if bt.isKnown && !isViewType(bt) && bt != .symbol {
            error(.typeCheck, "修饰符 .\(name) 只能用于 View，接收者是 '\(bt)'。", node.declName)
        }
        for a in args {
            var exp: SType? = sig.argType
            if name == "padding" || name == "tag" {
                if isImplicitMember(a.expr) { exp = .symbol } else if name == "padding" { exp = .double } else { exp = nil }
            }
            if exp == .unknown { exp = nil }
            if a.closure != nil {
                _ = compileClosure(a.closure!, expected: .function([], .void), builder: false)
            } else if case .function? = exp {
                _ = compileArgValue(a, expected: exp)
            } else {
                let t = compileExpr(a.expr, expected: exp)
                if let exp, exp != .symbol, t.isKnown, t != .symbol {
                    if exp == .double && !t.isNumeric || exp == .string && t != .string || exp == .bool && t != .bool {
                        error(.typeCheck, "修饰符 .\(name) 的参数类型应为 \(exp)，得到 '\(t)'。", a.expr)
                    }
                }
            }
        }
        emit(.callMethod(name: fullName(name, labels), argc: args.count))
        return .view
    }
}
