import RuntimeContracts
@_spi(Compiler) import SwiftParser
import SwiftSyntax

extension Compiler {
    // MARK: - 入口

    /// 编译表达式：总是恰好压入一个值，返回静态类型（可能为 unknown）。
    @discardableResult
    func compileExpr(_ e: ExprSyntax, expected: SType?) -> SType {
        exprDepth += 1
        defer { exprDepth -= 1 }
        if exprDepth > 180 {
            error(.typeCheck, "表达式嵌套过深。", e)
            emit(.pushVoid)
            return .unknown
        }
        return withLoc(e) {
            if chainContainsOptional(e) {
                use("syntax.optional.chaining")
                fb.optionalChainPatches.append([])
                let t = compileExprInner(e, expected: expected)
                let patches = fb.optionalChainPatches.removeLast()
                for p in patches { patch(p, to: here) }
                return t.isOptional ? t : (t.isKnown ? .optional(t) : .unknown)
            }
            return compileExprInner(e, expected: expected)
        }
    }

    /// 可选链中的基表达式：不再建立新的链。
    func compileChainBase(_ e: ExprSyntax) -> SType {
        withLoc(e) { compileExprInner(e, expected: nil) }
    }

    func chainContainsOptional(_ e: ExprSyntax) -> Bool {
        if e.is(OptionalChainingExprSyntax.self) { return false }
        var cur: ExprSyntax? = e
        while let c = cur {
            if c.is(OptionalChainingExprSyntax.self) { return true }
            if let m = c.as(MemberAccessExprSyntax.self) { cur = m.base } else if let f = c.as(FunctionCallExprSyntax.self) {
                cur = f.calledExpression
            } else if let s = c.as(SubscriptCallExprSyntax.self) { cur = s.calledExpression } else if let fu = c.as(ForceUnwrapExprSyntax.self) {
                cur = fu.expression
            } else { return false }
        }
        return false
    }

    func compileExprInner(_ e: ExprSyntax, expected: SType?) -> SType {
        if let lit = e.as(IntegerLiteralExprSyntax.self) { return compileIntLiteral(lit, expected: expected) }
        if let lit = e.as(FloatLiteralExprSyntax.self) {
            use("syntax.literal.double")
            guard let v = lit.representedLiteralValue else {
                error(.parse, "无效的浮点字面量。", lit)
                emit(.pushVoid)
                return .unknown
            }
            if expected?.unwrapped == .int {
                error(.typeCheck, "不能把 Double 字面量 \(lit.literal.text) 用作 Int（Swift 不做隐式转换）。", lit)
            }
            emit(.pushDouble(v))
            return .double
        }
        if let s = e.as(StringLiteralExprSyntax.self) { return compileStringLiteral(s) }
        if let b = e.as(BooleanLiteralExprSyntax.self) {
            use("syntax.literal.bool")
            emit(.pushBool(b.literal.tokenKind == .keyword(.true)))
            return .bool
        }
        if e.is(NilLiteralExprSyntax.self) {
            use("syntax.optional")
            emit(.pushNil)
            if let expected, expected.isOptional { return expected }
            return .optional(.unknown)
        }
        if let ref = e.as(DeclReferenceExprSyntax.self) { return compileDeclReference(ref, expected: expected) }
        if let m = e.as(MemberAccessExprSyntax.self) { return compileMemberAccess(m, expected: expected) }
        if let call = e.as(FunctionCallExprSyntax.self) { return compileCall(call, expected: expected) }
        if let sub = e.as(SubscriptCallExprSyntax.self) { return compileSubscript(sub, expected: expected) }
        if let infix = e.as(InfixOperatorExprSyntax.self) { return compileInfix(infix, expected: expected) }
        if let p = e.as(PrefixOperatorExprSyntax.self) { return compilePrefix(p, expected: expected) }
        if let fu = e.as(ForceUnwrapExprSyntax.self) {
            use("syntax.optional.forceUnwrap")
            let t = compileChainBase(fu.expression)
            emit(.forceUnwrap)
            return t.unwrapped
        }
        if let oc = e.as(OptionalChainingExprSyntax.self) {
            let t = compileChainBase(oc.expression)
            if fb.optionalChainPatches.isEmpty {
                error(.typeCheck, "'?' 只能用于可选链。", oc)
                return t
            }
            let p = emitJump { .jumpIfNil($0) }
            fb.optionalChainPatches[fb.optionalChainPatches.count - 1].append(p)
            return t.unwrapped
        }
        if let t = e.as(TernaryExprSyntax.self) { return compileTernary(t, expected: expected) }
        if let c = e.as(ClosureExprSyntax.self) { return compileClosure(c, expected: expected, builder: false) }
        if let a = e.as(ArrayExprSyntax.self) { return compileArrayLiteral(a, expected: expected) }
        if let d = e.as(DictionaryExprSyntax.self) { return compileDictLiteral(d, expected: expected) }
        if let t = e.as(TupleExprSyntax.self) { return compileTuple(t, expected: expected) }
        if let kp = e.as(KeyPathExprSyntax.self) { return compileKeyPath(kp) }
        if e.is(IfExprSyntax.self) || e.is(SwitchExprSyntax.self) {
            unsupported("if / switch 表达式（作为值使用）", e, "syntax.ifExpression")
        } else if e.is(AsExprSyntax.self) || e.is(IsExprSyntax.self) {
            unsupported("类型转换 as / is", e, "syntax.typeCasting")
        } else if e.is(TryExprSyntax.self) {
            unsupported("try 错误处理", e, "syntax.errorHandling")
        } else if e.is(AwaitExprSyntax.self) {
            unsupported("await 异步", e, "syntax.asyncAwait")
        } else if e.is(InOutExprSyntax.self) {
            unsupported("inout 参数 &x", e, "syntax.function.inout")
        } else if e.is(MacroExpansionExprSyntax.self) {
            unsupported("宏展开", e, "syntax.macro")
        } else if e.is(SuperExprSyntax.self) {
            unsupported("super", e, "syntax.class")
        } else if e.is(DiscardAssignmentExprSyntax.self) {
            error(.typeCheck, "'_' 只能出现在赋值号左侧。", e)
        } else if e.is(GenericSpecializationExprSyntax.self) {
            unsupported("显式泛型参数", e, "syntax.generics")
        } else if e.is(PostfixOperatorExprSyntax.self) {
            unsupported("后缀运算符", e, "syntax.operatorDecl")
        } else if let a = e.as(AssignmentExprSyntax.self) {
            error(.typeCheck, "赋值不能作为值使用。", a)
        } else {
            unsupported("此种表达式", e, "syntax.expression")
        }
        emit(.pushVoid)
        return .unknown
    }

    // MARK: - 下标

    func compileSubscript(_ s: SubscriptCallExprSyntax, expected: SType?) -> SType {
        if isProjectionRoot(s.calledExpression) { return compileProjection(ExprSyntax(s)) }
        if s.trailingClosure != nil {
            unsupported("带尾随闭包的下标", s, "syntax.subscriptDecl")
            emit(.pushVoid)
            return .unknown
        }
        let bt = compileChainBase(s.calledExpression)
        let args = Array(s.arguments)
        var label: String?
        if args.count == 2, args[1].label?.text == "default" { label = "default" }
        if args.contains(where: { $0.label != nil && $0.label?.text != "default" }) || args.isEmpty || args.count > 2 {
            error(.typeCheck, "不支持的下标形式。", s)
        }
        switch bt {
        case .array(let el):
            let kt = compileExpr(args[0].expression, expected: .int)
            emit(.subscriptGet(argc: 1, label: nil))
            if case .range = kt { return bt }
            if kt.isKnown && kt != .int { error(.typeCheck, "数组下标必须是 Int，得到 '\(kt)'。", args[0].expression) }
            use("stdlib.Array.subscript")
            return el
        case .dict(let k, let v):
            use("stdlib.Dictionary.subscript")
            compileExpr(args[0].expression, expected: k)
            if label == "default" {
                compileExpr(args[1].expression, expected: v)
                emit(.subscriptGet(argc: 2, label: "default"))
                return v
            }
            emit(.subscriptGet(argc: 1, label: nil))
            return .optional(v)
        case .string:
            unsupportedAPI("String 下标（String.Index）", s, "stdlib.String.subscript")
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        case .named(let tid, _):
            unsupported("自定义下标（'\(types[tid].name)' 上的 subscript）", s, "syntax.subscriptDecl")
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        default:
            for a in args { compileExpr(a.expression, expected: nil) }
            emit(.subscriptGet(argc: args.count, label: label))
            return .unknown
        }
    }

    // MARK: - 字面量

    func compileIntLiteral(_ lit: IntegerLiteralExprSyntax, expected: SType?) -> SType {
        use("syntax.literal.int")
        guard let v = lit.representedLiteralValue else {
            error(.typeCheck, "整数字面量 \(lit.literal.text) 超出 Int 范围。", lit)
            emit(.pushVoid)
            return .unknown
        }
        if expected?.unwrapped == .double {
            emit(.pushDouble(Double(v)))
            return .double
        }
        emit(.pushInt(v))
        return .int
    }

    func compileStringLiteral(_ s: StringLiteralExprSyntax) -> SType {
        use("syntax.literal.string")
        if s.openingQuote.tokenKind == .multilineStringQuote { use("syntax.multilineString") }
        if let v = s.representedLiteralValue {
            emit(.pushString(v))
            return .string
        }
        guard let kind = s.stringLiteralKind else {
            error(.parse, "无效的字符串字面量。", s)
            emit(.pushVoid)
            return .unknown
        }
        use("syntax.stringInterpolation")
        var n = 0
        for seg in s.segments {
            switch seg {
            case .stringSegment(let ss):
                var out = ""
                ss.appendUnescapedLiteralValue(stringLiteralKind: kind, delimiterLength: s.delimiterLength, to: &out)
                if !out.isEmpty {
                    emit(.pushString(out))
                    n += 1
                }
            case .expressionSegment(let es):
                guard es.expressions.count == 1, let only = es.expressions.first, only.label == nil else {
                    unsupported("带参数的字符串插值", es, "syntax.stringInterpolation")
                    continue
                }
                let t = compileExpr(only.expression, expected: nil)
                emit(.describe(t))
                n += 1
            }
        }
        if n == 0 { emit(.pushString("")) } else if n > 1 { emit(.concat(n)) } else {
            // 单段也需确保是字符串
        }
        return .string
    }

    func compileArrayLiteral(_ a: ArrayExprSyntax, expected: SType?) -> SType {
        var elemExpected: SType?
        if case .array(let e)? = expected?.unwrapped, e.isKnown { elemExpected = e }
        if elemExpected == nil {
            // 字面量元素统一：若存在 Double 字面量或已知 Double 元素，整数字面量按 Double 处理
            var sawDouble = false
            for el in a.elements {
                if let lt = numericLiteralKind(el.expression) { if lt == .double { sawDouble = true } } else if quickType(el.expression) == .double {
                    sawDouble = true
                }
            }
            if sawDouble { elemExpected = .double }
        }
        var elemType: SType = elemExpected ?? .unknown
        for el in a.elements {
            let t = compileExpr(el.expression, expected: elemExpected ?? (elemType.isKnown ? elemType : nil))
            if !elemType.isKnown { elemType = t } else if t.isKnown && elemType.isConcreteScalar && t.isConcreteScalar && t != elemType.unwrapped
                        && !(elemType.isOptional && t == elemType.unwrapped) {
                error(.typeCheck, "数组字面量的元素类型不一致（'\(elemType)' 与 '\(t)'）；运行时不支持 [Any]。", el.expression)
            }
        }
        if a.elements.isEmpty && expected == nil {
            error(.typeCheck, "空数组字面量需要显式类型，例如 `var items: [Int] = []`。", a)
        }
        emit(.makeArray(a.elements.count))
        return .array(elemType)
    }

    func compileDictLiteral(_ d: DictionaryExprSyntax, expected: SType?) -> SType {
        var kt: SType = .unknown, vt: SType = .unknown
        if case .dict(let k, let v)? = expected?.unwrapped { kt = k; vt = v }
        switch d.content {
        case .colon:
            if expected == nil { error(.typeCheck, "空字典字面量需要显式类型，例如 `var d: [String: Int] = [:]`。", d) }
            emit(.makeDict(0))
        case .elements(let els):
            for el in els {
                let k = compileExpr(el.key, expected: kt.isKnown ? kt : nil)
                if !kt.isKnown { kt = k }
                let v = compileExpr(el.value, expected: vt.isKnown ? vt : nil)
                if !vt.isKnown { vt = v }
            }
            emit(.makeDict(els.count))
        }
        return .dict(kt, vt)
    }

    func compileTuple(_ t: TupleExprSyntax, expected: SType?) -> SType {
        if t.elements.count == 1, let only = t.elements.first, only.label == nil {
            return compileExpr(only.expression, expected: expected)
        }
        if t.elements.isEmpty {
            emit(.pushVoid)
            return .void
        }
        use("syntax.tuple")
        var ets: [SType] = []
        var labels: [String?] = []
        var expTypes: [SType] = []
        if case .tuple(let ts, _)? = expected, ts.count == t.elements.count { expTypes = ts }
        for (i, el) in t.elements.enumerated() {
            ets.append(compileExpr(el.expression, expected: i < expTypes.count ? expTypes[i] : nil))
            labels.append(el.label?.text)
        }
        emit(.makeTuple(labels))
        return .tuple(ets, labels)
    }

    func compileKeyPath(_ kp: KeyPathExprSyntax) -> SType {
        use("syntax.keyPath")
        var names: [String] = []
        for c in kp.components {
            switch c.component {
            case .property(let p):
                let n = p.declName.baseName.text
                if n != "self" { names.append(n) }
            default:
                unsupported("此种 KeyPath 组件", c, "syntax.keyPath")
            }
        }
        emit(.pushKeyPath(names))
        return .keyPath
    }

    // MARK: - 数值字面量树（Int/Double 定型）

    /// 若表达式只由数值字面量与算术组成，返回其默认类型（含浮点字面量则为 Double）。
    func numericLiteralKind(_ e: ExprSyntax) -> SType? {
        if e.is(IntegerLiteralExprSyntax.self) { return .int }
        if e.is(FloatLiteralExprSyntax.self) { return .double }
        if let p = e.as(PrefixOperatorExprSyntax.self), p.operator.text == "-" || p.operator.text == "+" {
            return numericLiteralKind(p.expression)
        }
        if let t = e.as(TupleExprSyntax.self), t.elements.count == 1, let only = t.elements.first, only.label == nil {
            return numericLiteralKind(only.expression)
        }
        if let infix = e.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           ["+", "-", "*", "/", "%"].contains(op.operator.text),
           let l = numericLiteralKind(infix.leftOperand), let r = numericLiteralKind(infix.rightOperand) {
            return l == .double || r == .double ? .double : .int
        }
        return nil
    }

    // MARK: - 运算符

    func compileInfix(_ infix: InfixOperatorExprSyntax, expected: SType?) -> SType {
        if infix.operator.is(AssignmentExprSyntax.self) {
            compileAssignment(infix)
            emit(.pushVoid)
            return .void
        }
        guard let opNode = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            unsupported("此种二元表达式", infix, "syntax.expression")
            emit(.pushVoid)
            return .unknown
        }
        let op = opNode.operator.text
        if let bop = compoundOps[op] {
            compileCompound(infix, bop)
            emit(.pushVoid)
            return .void
        }
        switch op {
        case "&&", "||":
            use("syntax.operator.logical")
            let lt = compileExpr(infix.leftOperand, expected: .bool)
            checkBool(lt, infix.leftOperand)
            let short = emitJump { op == "&&" ? .jumpIfFalse($0) : .jumpIfTrue($0) }
            let rt = compileExpr(infix.rightOperand, expected: .bool)
            checkBool(rt, infix.rightOperand)
            let end = emitJump { .jump($0) }
            patch(short, to: here)
            emit(.pushBool(op == "||"))
            patch(end, to: here)
            return .bool
        case "??":
            use("syntax.operator.nilCoalescing")
            let lt = compileExpr(infix.leftOperand, expected: expected.map { .optional($0.unwrapped) })
            if lt.isKnown && !lt.isOptional {
                warning("'??' 左侧不是 Optional，右侧永远不会被使用。", infix.leftOperand)
            }
            let end = emitJump { .jumpIfNotNil($0) }
            emit(.pop)
            let inner = lt.unwrapped
            let rt = compileExpr(infix.rightOperand, expected: inner.isKnown ? (expected?.isOptional == true ? .optional(inner) : inner) : expected)
            patch(end, to: here)
            if inner.isKnown && rt.isKnown && inner.isConcreteScalar && rt.unwrapped.isConcreteScalar && inner != rt.unwrapped {
                error(.typeCheck, "'??' 两侧类型不一致（'\(inner)' 与 '\(rt)'）。", infix)
            }
            return rt.isOptional ? rt : (inner.isKnown ? inner : rt)
        case "..<", "...":
            use("syntax.range")
            let lt = compileExpr(infix.leftOperand, expected: .int)
            let rt = compileExpr(infix.rightOperand, expected: .int)
            if lt == .double || rt == .double {
                unsupported("Double 区间", infix, "syntax.range")
            }
            emit(.binary(op == "..<" ? .halfOpenRange : .closedRange, .none))
            return .range(closed: op == "...")
        default:
            break
        }
        guard let bop = BinOp(rawValue: op) else {
            unsupported("运算符 '\(op)'", opNode, "syntax.operatorDecl")
            emit(.pushVoid)
            return .unknown
        }
        if bop.isComparison { use("syntax.operator.comparison") } else if ["&", "|", "^", "<<", ">>"].contains(op) {
            use("syntax.operator.bitwise")
        } else if op.hasPrefix("&") { use("syntax.operator.wrapping") } else { use("syntax.operator.arithmetic") }
        return compileBinary(bop, infix.leftOperand, infix.rightOperand, expected: expected, node: Syntax(infix))
    }

    func checkBool(_ t: SType, _ node: some SyntaxProtocol) {
        if t.isKnown && t != .bool { error(.typeCheck, "逻辑运算需要 Bool，得到 '\(t)'。", node) }
    }

    /// 二元算术/比较：字面量按另一侧的类型定型；两侧类型已知且 Int/Double 不一致时报错。
    func compileBinary(_ op: BinOp, _ lhs: ExprSyntax, _ rhs: ExprSyntax, expected: SType?, node: Syntax) -> SType {
        let lLit = numericLiteralKind(lhs)
        let rLit = numericLiteralKind(rhs)
        let arithExpected: SType? = (op.isArithmetic && (expected?.unwrapped == .double || expected?.unwrapped == .int)) ? expected?.unwrapped : nil
        var lt: SType, rt: SType
        var lit = LiteralSide.none
        if let l = lLit, let r = rLit {
            let target: SType = arithExpected ?? ((l == .double || r == .double) ? .double : .int)
            lt = compileExpr(lhs, expected: target)
            rt = compileExpr(rhs, expected: target)
        } else if lLit != nil {
            let q = quickType(rhs)
            if q.unwrapped.isNumeric {
                lt = compileExpr(lhs, expected: q.unwrapped)
            } else if let a = arithExpected {
                lt = compileExpr(lhs, expected: a)
            } else {
                lt = compileExpr(lhs, expected: nil)
                if lt == .int { lit = .lhs }
            }
            rt = compileExpr(rhs, expected: nil)
        } else if rLit != nil {
            lt = compileExpr(lhs, expected: arithExpected)
            if lt.unwrapped.isNumeric {
                rt = compileExpr(rhs, expected: lt.unwrapped)
            } else {
                rt = compileExpr(rhs, expected: arithExpected)
                if rt == .int && !lt.isKnown { lit = .rhs }
            }
        } else if isImplicitMember(lhs) {
            let q = quickType(rhs)
            lt = compileExpr(lhs, expected: q.isKnown ? q : nil)
            rt = compileExpr(rhs, expected: lt.isKnown && lt != .symbol ? lt : nil)
        } else {
            lt = compileExpr(lhs, expected: op.isArithmetic ? arithExpected : nil)
            let rexp: SType? = lt.isKnown && lt != .symbol ? (op.isComparison || op.isArithmetic ? lt.unwrapped : nil) : nil
            rt = compileExpr(rhs, expected: rexp)
        }
        emit(.binary(op, lit))
        // 类型检查
        let lu = lt.unwrapped, ru = rt.unwrapped
        if lu.isKnown && ru.isKnown {
            if lu.isNumeric && ru.isNumeric && lu != ru {
                error(.typeCheck, "二元运算符 '\(op.rawValue)' 不能用于 '\(lt)' 和 '\(rt)' 操作数：Swift 不做 Int 与 Double 的隐式转换。",
                      node, suggestion: "使用 Double(x) 或 Int(x) 显式转换。")
            } else if op.isArithmetic && (lt.isOptional || rt.isOptional) {
                error(.typeCheck, "可选值必须先解包才能参与运算 '\(op.rawValue)'。", node)
            } else if op.isArithmetic && lu.isConcreteScalar && ru.isConcreteScalar && lu != ru {
                error(.typeCheck, "二元运算符 '\(op.rawValue)' 不能用于 '\(lt)' 和 '\(rt)' 操作数。", node)
            } else if op.isArithmetic && (lu == .bool || (lu == .string && op != .add)) {
                error(.typeCheck, "二元运算符 '\(op.rawValue)' 不能用于 '\(lt)'。", node)
            } else if op == .rem && lu == .double {
                error(.typeCheck, "'%' 不能用于 Double，请使用 truncatingRemainder(dividingBy:)。", node)
            } else if op.isComparison && op != .eq && op != .ne && (lt.isOptional || rt.isOptional) {
                error(.typeCheck, "可选值必须先解包才能比较大小。", node)
            }
        }
        if op.isComparison { return .bool }
        return lu.isKnown ? lu : ru
    }

    func isImplicitMember(_ e: ExprSyntax) -> Bool {
        if let m = e.as(MemberAccessExprSyntax.self), m.base == nil { return true }
        return false
    }

    func compilePrefix(_ p: PrefixOperatorExprSyntax, expected: SType?) -> SType {
        switch p.operator.text {
        case "-":
            use("syntax.operator.arithmetic")
            let t = compileExpr(p.expression, expected: expected?.unwrapped.isNumeric == true ? expected?.unwrapped : nil)
            if t.isKnown && !t.isNumeric { error(.typeCheck, "一元 '-' 需要数值，得到 '\(t)'。", p) }
            emit(.unary(.neg))
            return t
        case "+":
            return compileExpr(p.expression, expected: expected)
        case "!":
            use("syntax.operator.logical")
            let t = compileExpr(p.expression, expected: .bool)
            checkBool(t, p.expression)
            emit(.unary(.not))
            return .bool
        case "~":
            use("syntax.operator.bitwise")
            let t = compileExpr(p.expression, expected: .int)
            emit(.unary(.bitNot))
            return t
        default:
            unsupported("前缀运算符 '\(p.operator.text)'", p, "syntax.operatorDecl")
            emit(.pushVoid)
            return .unknown
        }
    }

    func compileTernary(_ t: TernaryExprSyntax, expected: SType?) -> SType {
        use("syntax.operator.ternary")
        let ct = compileExpr(t.condition, expected: .bool)
        checkBool(ct, t.condition)
        let elseJump = emitJump { .jumpIfFalse($0) }
        var exp = expected
        if exp == nil, numericLiteralKind(t.thenExpression) != nil {
            let q = quickType(t.elseExpression)
            if q.isNumeric { exp = q }
        }
        let tt = compileExpr(t.thenExpression, expected: exp)
        let end = emitJump { .jump($0) }
        patch(elseJump, to: here)
        let et = compileExpr(t.elseExpression, expected: exp ?? (tt.isKnown ? tt : nil))
        patch(end, to: here)
        if tt.isKnown && et.isKnown && tt.isConcreteScalar && et.isConcreteScalar && tt != et {
            error(.typeCheck, "三元表达式两个分支类型不一致（'\(tt)' 与 '\(et)'）。", t)
        }
        return tt.isKnown ? tt : et
    }

    // MARK: - 赋值兼容检查

    func checkAssignable(_ target: SType, _ source: SType, _ node: some SyntaxProtocol) {
        guard target.isKnown, source.isKnown else { return }
        if case .binding = target { return }
        if target == source { return }
        if source == .symbol || target == .symbol { return }
        let tu = target.unwrapped
        if source.isOptional && !target.isOptional {
            if source == .optional(.unknown) {
                error(.typeCheck, "不能把 nil 赋给非可选类型 '\(target)'。", node)
            } else {
                error(.typeCheck, "类型 '\(source)' 是可选值，必须先解包才能用作 '\(target)'。", node,
                      suggestion: "使用 if let / guard let / ?? 提供默认值。")
            }
            return
        }
        let su = source.unwrapped
        if !tu.isKnown || !su.isKnown { return }
        if tu == su { return }
        if (tu == .view && isViewType(su)) || (su == .view && isViewType(tu)) { return }
        if case .array(let te) = tu, case .array(let se) = su {
            if !te.isKnown || !se.isKnown || te == se { return }
            if se.unwrapped == te.unwrapped && te.isOptional { return }
        }
        if case .dict = tu, case .dict = su { return }
        if case .function = tu, case .function = su { return }
        if case .tuple = tu, case .tuple = su { return }
        if case .range = tu, case .range = su { return }
        error(.typeCheck, "无法把 '\(source)' 类型的值用作 '\(target)'。", node)
    }

    func isViewType(_ t: SType) -> Bool {
        if t == .view { return true }
        if case .named(let id, _) = t { return types[id].isView }
        return false
    }
}
