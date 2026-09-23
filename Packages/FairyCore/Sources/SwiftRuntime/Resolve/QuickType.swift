import RuntimeContracts
import SwiftSyntax

/// 不发射代码、不登记捕获的轻量类型推断（用于字面量定型、重载选择、决定方法调用是否按左值编译）。
extension Compiler {
    func quickType(_ e: ExprSyntax, depth: Int = 0) -> SType {
        if depth > 24 { return .unknown }
        let d = depth + 1
        if let k = numericLiteralKind(e) { return k }
        if e.is(StringLiteralExprSyntax.self) { return .string }
        if e.is(BooleanLiteralExprSyntax.self) { return .bool }
        if e.is(NilLiteralExprSyntax.self) { return .optional(.unknown) }
        if e.is(ClosureExprSyntax.self) { return .function([], .unknown) }
        if e.is(KeyPathExprSyntax.self) { return .keyPath }
        if let t = e.as(TupleExprSyntax.self), t.elements.count == 1, let only = t.elements.first, only.label == nil {
            return quickType(only.expression, depth: d)
        }
        if let ref = e.as(DeclReferenceExprSyntax.self) { return quickName(ref.baseName.text) }
        if let fu = e.as(ForceUnwrapExprSyntax.self) { return quickType(fu.expression, depth: d).unwrapped }
        if let oc = e.as(OptionalChainingExprSyntax.self) { return quickType(oc.expression, depth: d).unwrapped }
        if let a = e.as(ArrayExprSyntax.self) {
            if let first = a.elements.first { return .array(quickType(first.expression, depth: d)) }
            return .array(.unknown)
        }
        if let dict = e.as(DictionaryExprSyntax.self) {
            if case .elements(let els) = dict.content, let first = els.first {
                return .dict(quickType(first.key, depth: d), quickType(first.value, depth: d))
            }
            return .dict(.unknown, .unknown)
        }
        if let p = e.as(PrefixOperatorExprSyntax.self) {
            return p.operator.text == "!" ? .bool : quickType(p.expression, depth: d)
        }
        if let t = e.as(TernaryExprSyntax.self) {
            let a = quickType(t.thenExpression, depth: d)
            return a.isKnown ? a : quickType(t.elseExpression, depth: d)
        }
        if let infix = e.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self) {
            let o = op.operator.text
            switch o {
            case "==", "!=", "<", "<=", ">", ">=", "&&", "||": return .bool
            case "..<": return .range(closed: false)
            case "...": return .range(closed: true)
            case "??": return quickType(infix.rightOperand, depth: d)
            default:
                let l = quickType(infix.leftOperand, depth: d)
                if l.isKnown && numericLiteralKind(infix.leftOperand) == nil { return l }
                let r = quickType(infix.rightOperand, depth: d)
                return r.isKnown ? r : l
            }
        }
        if let m = e.as(MemberAccessExprSyntax.self) {
            let name = m.declName.baseName.text
            guard let base = m.base else { return .unknown }
            if let tref = staticTypeReference(base) {
                switch tref {
                case .user(let tid):
                    let t = types[tid]
                    if t.caseIndex(name) != nil { return .named(tid, t.name) }
                    if let g = t.staticField(name) { return g.type }
                    if let c = t.computedProp(name), c.isStatic { return c.type }
                    if name == "allCases" { return .array(.named(tid, t.name)) }
                    return .unknown
                case .builtin(let tn):
                    if tn == "Int" { return .int }
                    if tn == "Double" || tn == "CGFloat" { return .double }
                    return .symbol
                }
            }
            return quickMember(quickType(base, depth: d), name)
        }
        if let s = e.as(SubscriptCallExprSyntax.self) {
            let bt = quickType(s.calledExpression, depth: d)
            switch bt {
            case .array(let el):
                if let k = s.arguments.first, quickType(k.expression, depth: d) == .range(closed: false) || quickType(k.expression, depth: d) == .range(closed: true) {
                    return bt
                }
                return el
            case .dict(_, let v):
                return s.arguments.count == 2 ? v : .optional(v)
            default: return .unknown
            }
        }
        if let call = e.as(FunctionCallExprSyntax.self) { return quickCall(call, depth: d) }
        return .unknown
    }

    func quickName(_ name: String) -> SType {
        if name == "self" {
            if let v = fb.peek("self") { return v.type }
            return .unknown
        }
        if let v = fb.peek(name) { return v.type }
        if name.hasPrefix("$") && !isDollarShorthand(name) {
            let inner = quickName(String(name.dropFirst()))
            return .binding(inner)
        }
        if let t = selfTypeDecl() {
            if let f = t.field(name) { return f.type }
            if let c = t.computedProp(name), !c.isStatic { return c.type }
        }
        if let st = fb.enclosingStaticType {
            if let g = types[st].staticField(name) { return g.type }
        }
        if let g = globalByName[name] { return globals[g].type }
        if let f = funcs[name]?.first { return .function(f.params.map(\.type), f.returnType) }
        if let t = typeByName[name] { return .metatype(t, name) }
        return .unknown
    }

    func quickMember(_ bt: SType, _ name: String) -> SType {
        switch bt {
        case .named(let tid, _):
            let t = types[tid]
            if let f = t.field(name) { return f.type }
            if let c = t.computedProp(name), !c.isStatic { return c.type }
            if name == "rawValue", let r = t.rawType { return r }
            return .unknown
        default:
            return builtinMemberType(bt, name, program: types) ?? .unknown
        }
    }

    func quickCall(_ call: FunctionCallExprSyntax, depth: Int) -> SType {
        let callee = call.calledExpression
        if let ref = callee.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let v = fb.peek(name) {
                if case .function(_, let r) = v.type { return r }
                return .unknown
            }
            if let t = selfTypeDecl(), let m = t.methods(named: name).first { return m.returnType }
            if let tid = typeByName[name] {
                if types[tid].kind == .enumType { return .optional(.named(tid, name)) }
                return .named(tid, name)
            }
            if let f = funcs[name]?.first { return f.returnType }
            switch name {
            case "Int", "Double", "CGFloat":
                let target: SType = name == "Int" ? .int : .double
                if let a = call.arguments.first, quickType(a.expression, depth: depth) == .string { return .optional(target) }
                return target
            case "String": return .string
            case "print", "precondition", "assert": return .void
            case "min", "max", "abs":
                return commonNumericType(call.arguments.map(\.expression)) ?? .unknown
            case "sqrt", "floor", "ceil", "round", "sin", "cos", "exp", "log", "pow": return .double
            case "Array":
                if let a = call.arguments.first { return .array(elementType(of: quickType(a.expression, depth: depth))) }
                return .array(.unknown)
            default:
                if viewSignatures[name] != nil { return name == "Color" ? .symbol : .view }
                return .unknown
            }
        }
        if let arr = callee.as(ArrayExprSyntax.self), arr.elements.count == 1, let el = arr.elements.first {
            return .array(typeFromTypeExpr(el.expression))
        }
        if let m = callee.as(MemberAccessExprSyntax.self), let base = m.base {
            let name = m.declName.baseName.text
            if let tref = staticTypeReference(base), case .user(let tid) = tref {
                return types[tid].methods(named: name).first?.returnType ?? .unknown
            }
            let bt = quickType(base, depth: depth)
            switch bt {
            case .named(let tid, _):
                if let meth = types[tid].methods(named: name).first { return meth.returnType }
                if types[tid].isView { return .view }
                return .unknown
            case .view:
                return .view
            default:
                var labels = call.arguments.map { $0.label?.text }
                if call.trailingClosure != nil {
                    for tl in [nil, "by", "where"] as [String?] {
                        if let s = builtinMethodSig(bt, fullName(name, labels + [tl])) { return s.result(.unknown, []) }
                    }
                    labels.append(nil)
                }
                if let s = builtinMethodSig(bt, fullName(name, labels)) {
                    let argTypes = call.arguments.map { quickType($0.expression, depth: depth) }
                    return s.result(.unknown, argTypes)
                }
                return .unknown
            }
        }
        return .unknown
    }
}
