import RuntimeContracts
import SwiftSyntax

/// 编译期左值描述。
struct PlaceInfo {
    var root: PlaceRoot
    var steps: [PlaceStep] = []
    var keyExprs: [(ExprSyntax, SType?)] = []
    var type: SType
    var mutable: Bool
    var immutableReason: String?
    /// 路径经过 @State / @Binding 字段（写穿到状态存储，不受外层不可变限制）
    var throughWrapper = false
    var accessViolation: String?
    var isLazyGlobal = false
}

extension Compiler {
    func placeRoot(_ rv: ResolvedVar) -> PlaceRoot {
        switch rv.location {
        case .local(let s): return .local(s)
        case .capture(let i): return .capture(i)
        }
    }

    func resolvePlace(_ e: ExprSyntax, stripDollar: Bool = false) -> PlaceInfo? {
        if let t = e.as(TupleExprSyntax.self), t.elements.count == 1, let only = t.elements.first, only.label == nil {
            return resolvePlace(only.expression, stripDollar: stripDollar)
        }
        if let ref = e.as(DeclReferenceExprSyntax.self) {
            var name = ref.baseName.text
            if stripDollar && name.hasPrefix("$") { name.removeFirst() }
            return resolveNamePlace(name, node: Syntax(ref))
        }
        if let m = e.as(MemberAccessExprSyntax.self), let base = m.base {
            let name = m.declName.baseName.text
            if let tref = staticTypeReference(base), case .user(let tid) = tref {
                guard let g = types[tid].staticField(name) else { return nil }
                return PlaceInfo(root: .global(g.globalID), type: g.type, mutable: !g.isLet,
                                 immutableReason: g.isLet ? "'\(name)' 是 static let 常量" : nil, isLazyGlobal: true)
            }
            guard var p = resolvePlace(base, stripDollar: stripDollar) else { return nil }
            switch p.type {
            case .named(let tid, _):
                let t = types[tid]
                if let i = t.fields.firstIndex(where: { $0.name == name }) {
                    let f = t.fields[i]
                    checkMemberVisible(name, of: t, declFile: f.fileIndex, access: f.access, m.declName)
                    p.steps.append(.field(i))
                    p.type = f.type
                    applyFieldMutability(&p, f, name)
                } else if t.computedProp(name) != nil {
                    p.steps.append(.member(name))
                    p.type = t.computedProp(name)!.type
                    if programHasComputedSetter(tid: tid, name: name) {
                        p.mutable = true
                        p.immutableReason = nil
                    } else {
                        p.mutable = false
                        p.immutableReason = "计算属性 '\(name)' 没有 setter"
                    }
                } else {
                    error(.nameResolution, "'\(t.name)' 没有成员 '\(name)'。", m.declName)
                    return nil
                }
            case .tuple(let ts, let labels):
                if let i = labels.firstIndex(of: name) {
                    p.steps.append(.tupleIndex(i)); p.type = ts[i]
                } else if let i = Int(name), i < ts.count {
                    p.steps.append(.tupleIndex(i)); p.type = ts[i]
                } else { return nil }
            case .array, .string, .dict, .range, .int, .double, .bool:
                // 内建类型的属性（count 等）只读
                p.steps.append(.member(name))
                p.type = builtinMemberType(p.type, name, program: types) ?? .unknown
                p.mutable = false
                p.immutableReason = "'\(name)' 是只读属性"
            default:
                p.steps.append(.member(name))
                p.type = .unknown
            }
            return p
        }
        if let s = e.as(SubscriptCallExprSyntax.self) {
            guard var p = resolvePlace(s.calledExpression, stripDollar: stripDollar) else { return nil }
            let args = Array(s.arguments)
            guard !args.isEmpty, s.trailingClosure == nil else { return nil }
            var label: String?
            var keyTypes: [SType?] = []
            var resultType: SType = .unknown
            switch p.type {
            case .array(let el):
                keyTypes = [.int]
                resultType = el
            case .dict(let k, let v):
                if args.count == 2, args[1].label?.text == "default" {
                    label = "default"
                    keyTypes = [k, v]
                    resultType = v
                } else {
                    keyTypes = [k]
                    resultType = .optional(v)
                }
            case .string:
                unsupportedAPI("String 下标（String.Index）", s, "stdlib.String.subscript")
                return nil
            default:
                if args.count == 2, args[1].label?.text == "default" { label = "default" }
                keyTypes = args.map { _ in nil }
            }
            for (i, a) in args.enumerated() {
                p.keyExprs.append((a.expression, i < keyTypes.count ? keyTypes[i] : nil))
            }
            p.steps.append(.subscriptKey(argc: args.count, label: label))
            p.type = resultType
            return p
        }
        if let f = e.as(ForceUnwrapExprSyntax.self) {
            guard var p = resolvePlace(f.expression, stripDollar: stripDollar) else { return nil }
            p.steps.append(.unwrap)
            p.type = p.type.unwrapped
            return p
        }
        if let oc = e.as(OptionalChainingExprSyntax.self) {
            guard var p = resolvePlace(oc.expression, stripDollar: stripDollar) else { return nil }
            use("syntax.optional.chaining")
            p.steps.append(.optionalChain)
            p.type = p.type.unwrapped
            return p
        }
        return nil
    }

    /// 该计算属性是否有 setter（本编译单元内）。
    func programHasComputedSetter(tid: Int, name: String) -> Bool {
        types[tid].computedProp(name)?.setterFunctionID ?? -1 >= 0
    }

    func applyFieldMutability(_ p: inout PlaceInfo, _ f: StoredFieldDecl, _ name: String) {        if f.wrapper != .none {
            p.throughWrapper = true
            p.mutable = true
            p.immutableReason = nil
        } else if f.isLet {
            p.mutable = false
            p.immutableReason = "'\(name)' 是 let 常量属性"
        }
        if f.setterAccess.isFileScoped && f.fileIndex != fb.fileIndex {
            p.accessViolation = "'\(name)' 的 setter 是 \(f.setterAccess.keyword)（声明于 \(files[f.fileIndex].fileName)），不能在 \(files[fb.fileIndex].fileName) 中修改。"
        }
    }

    func resolveNamePlace(_ name: String, node: Syntax) -> PlaceInfo? {
        if name == "self" {
            guard let rv = fb.lookup("self") else { return nil }
            return PlaceInfo(root: placeRoot(rv), type: rv.info.type, mutable: !rv.info.isLet,
                             immutableReason: rv.info.isLet ? "self 不可变（非 mutating 方法或闭包中捕获的 self）" : nil)
        }
        if let rv = fb.lookup(name) {
            var p = PlaceInfo(root: placeRoot(rv), type: rv.info.type, mutable: !rv.info.isLet,
                              immutableReason: rv.info.isLet ? "'\(name)' 是 let 常量" : nil)
            if case .binding(let inner) = rv.info.type {
                p.throughWrapper = true
                p.mutable = true
                p.type = inner
            }
            return p
        }
        if let t = selfTypeDecl(), let i = t.fields.firstIndex(where: { $0.name == name }), let rv = fb.lookup("self") {
            let f = t.fields[i]
            checkMemberVisible(name, of: t, declFile: f.fileIndex, access: f.access, node)
            var p = PlaceInfo(root: placeRoot(rv), steps: [.field(i)], type: f.type, mutable: !rv.info.isLet,
                              immutableReason: rv.info.isLet ? "self 不可变：在非 mutating 方法中不能修改属性 '\(name)'" : nil)
            applyFieldMutability(&p, f, name)
            return p
        }
        if let st = fb.enclosingStaticType, let g = types[st].staticField(name) {
            return PlaceInfo(root: .global(g.globalID), type: g.type, mutable: !g.isLet,
                             immutableReason: g.isLet ? "'\(name)' 是 static let 常量" : nil, isLazyGlobal: true)
        }
        if let gid = globalByName[name] {
            let g = globals[gid]
            _ = checkVisible(name, declFile: g.fileIndex, access: g.access, node)
            return PlaceInfo(root: .global(gid), type: g.type, mutable: !g.isLet,
                             immutableReason: g.isLet ? "'\(name)' 是 let 常量" : nil, isLazyGlobal: !g.isMainTopLevel)
        }
        return nil
    }

    /// 该 place 是否为带 didSet 的全局变量（需要走 .place 以便触发观察器，不能用 storeGlobal 快速路径）。
    func placeNeedsObserverPath(_ p: PlaceInfo) -> Bool {
        if case .global(let g) = p.root, p.steps.isEmpty {
            return globals[g].didSetFunctionID >= 0
        }
        return false
    }

    func checkMutable(_ p: PlaceInfo, _ node: some SyntaxProtocol, action: String = "修改") {        if let v = p.accessViolation { error(.nameResolution, v, node) }
        if !p.mutable {
            error(.typeCheck, "不能\(action)：\(p.immutableReason ?? "目标不可变")。", node)
        }
    }

    // MARK: - 赋值

    func compileAssignment(_ infix: InfixOperatorExprSyntax) {
        let lhs = infix.leftOperand, rhs = infix.rightOperand
        if lhs.is(DiscardAssignmentExprSyntax.self) {
            compileExpr(rhs, expected: nil)
            emit(.pop)
            return
        }
        if let t = lhs.as(TupleExprSyntax.self), t.elements.count > 1 {
            unsupported("元组解构赋值", lhs, "syntax.tuplePattern")
            return
        }
        guard let p = resolvePlace(lhs) else {
            if !diagnostics.contains(where: { $0.severity == .error && $0.range == range(lhs) }) {
                error(.typeCheck, "不能给这个表达式赋值。", lhs)
            }
            return
        }
        checkMutable(p, lhs)
        let expected: SType? = p.type.isKnown ? p.type : nil
        if p.steps.isEmpty && !p.isLazyGlobal && !placeNeedsObserverPath(p) {
            let t = compileExpr(rhs, expected: expected)
            if let expected { checkAssignable(expected, t, rhs) }
            switch p.root {
            case .local(let s): emit(.storeLocal(s))
            case .capture(let i): emit(.storeCapture(i))
            case .global(let g): emit(.storeGlobal(g))
            }
            return
        }
        for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
        let t = compileExpr(rhs, expected: expected)
        if let expected { checkAssignable(expected, t, rhs) }
        emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .assign))
    }

    func compileCompound(_ infix: InfixOperatorExprSyntax, _ op: BinOp) {
        use("syntax.operator.compoundAssignment")
        let lhs = infix.leftOperand, rhs = infix.rightOperand
        guard let p = resolvePlace(lhs) else {
            error(.typeCheck, "不能给这个表达式赋值。", lhs)
            return
        }
        checkMutable(p, lhs)
        let target = p.type
        let expected: SType? = target.isKnown ? target : nil
        var lit = LiteralSide.none
        if p.steps.isEmpty && !p.isLazyGlobal && !placeNeedsObserverPath(p) {
            switch p.root {
            case .local(let s): emit(.loadLocal(s))
            case .capture(let i): emit(.loadCapture(i))
            case .global(let g): emit(.loadGlobal(g))
            }
            let rt = compileExpr(rhs, expected: expected)
            if !target.isKnown && numericLiteralKind(rhs) == .int { lit = .rhs }
            checkCompoundTypes(target, rt, op, infix)
            emit(.binary(op, lit))
            switch p.root {
            case .local(let s): emit(.storeLocal(s))
            case .capture(let i): emit(.storeCapture(i))
            case .global(let g): emit(.storeGlobal(g))
            }
            return
        }
        for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
        let rt = compileExpr(rhs, expected: expected)
        if !target.isKnown && numericLiteralKind(rhs) == .int { lit = .rhs }
        checkCompoundTypes(target, rt, op, infix)
        emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .compound(op, lit)))
    }

    func checkCompoundTypes(_ target: SType, _ rt: SType, _ op: BinOp, _ node: InfixOperatorExprSyntax) {
        guard target.isKnown, rt.isKnown else { return }
        if target.isOptional {
            error(.typeCheck, "可选值必须先解包才能使用 '\(op.rawValue)='。", node)
            return
        }
        if target.isNumeric && rt.isNumeric && target != rt {
            error(.typeCheck, "复合赋值 '\(op.rawValue)=' 不能用于 '\(target)' 和 '\(rt)'：Swift 不做 Int 与 Double 的隐式转换。", node,
                  suggestion: "使用 Double(x) 或 Int(x) 显式转换。")
        } else if target.isConcreteScalar && rt.isConcreteScalar && target != rt {
            error(.typeCheck, "复合赋值 '\(op.rawValue)=' 不能用于 '\(target)' 和 '\(rt)'。", node)
        }
    }
}
