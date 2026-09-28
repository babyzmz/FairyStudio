import RuntimeContracts
import SwiftSyntax

extension Compiler {
    // MARK: - 类型语法 → 静态类型

    func resolveType(_ t: TypeSyntax, file: Int, selfType: Int? = nil) -> SType {
        if let id = t.as(IdentifierTypeSyntax.self) {
            let name = id.name.text
            let args = id.genericArgumentClause?.arguments.compactMap { arg -> TypeSyntax? in
                if case .type(let ty) = arg.argument { return ty }
                return nil
            } ?? []
            switch name {
            case "Int": return .int
            case "Double": return .double
            case "CGFloat": use("stdlib.CGFloat"); return .double
            case "Bool": return .bool
            case "String": return .string
            case "Character": use("stdlib.Character"); return .string
            case "Void": return .void
            case "Array" where args.count == 1: return .array(resolveType(args[0], file: file, selfType: selfType))
            case "Dictionary" where args.count == 2:
                return .dict(resolveType(args[0], file: file, selfType: selfType), resolveType(args[1], file: file, selfType: selfType))
            case "Optional" where args.count == 1: return .optional(resolveType(args[0], file: file, selfType: selfType))
            case "Binding" where args.count == 1: return .binding(resolveType(args[0], file: file, selfType: selfType))
            case "Range", "ClosedRange": return .range(closed: name == "ClosedRange")
            case "Self":
                if let s = selfType { return .named(s, types[s].name) }
            default:
                break
            }
            if let tid = typeByName[name] {
                let td = types[tid]
                if td.access.isFileScoped && td.fileIndex != file {
                    error(.nameResolution, "找不到类型 '\(name)'：它在 \(files[td.fileIndex].fileName) 中声明为 \(td.access.keyword)，其他文件不可见。",
                          id, file: file)
                    return .unknown
                }
                return .named(tid, name)
            }
            if knownUnsupportedTypes.contains(name) {
                error(.unsupportedAPI, "运行时尚不支持类型 '\(name)'。", id, file: file, capability: "stdlib.\(name)")
                return .unknown
            }
            if ["View", "Scene", "App"].contains(name) { return .view }
            error(.nameResolution, "找不到类型 '\(name)'。", id, file: file)
            return .unknown
        }
        if let a = t.as(ArrayTypeSyntax.self) { return .array(resolveType(a.element, file: file, selfType: selfType)) }
        if let d = t.as(DictionaryTypeSyntax.self) {
            return .dict(resolveType(d.key, file: file, selfType: selfType), resolveType(d.value, file: file, selfType: selfType))
        }
        if let o = t.as(OptionalTypeSyntax.self) {
            use("syntax.optional")
            return .optional(resolveType(o.wrappedType, file: file, selfType: selfType))
        }
        if let o = t.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return .optional(resolveType(o.wrappedType, file: file, selfType: selfType))
        }
        if let s = t.as(SomeOrAnyTypeSyntax.self) {
            let c = s.constraint.trimmedDescription
            if s.someOrAnySpecifier.text == "some" && (c == "View" || c == "Scene") { return .view }
            unsupported("不透明/存在类型 '\(t.trimmedDescription)'", t, "syntax.protocol", file: file)
            return .unknown
        }
        if let f = t.as(FunctionTypeSyntax.self) {
            if f.effectSpecifiers != nil { unsupported("async/throws 函数类型", f, "syntax.asyncAwait", file: file) }
            let ps = f.parameters.map { resolveType($0.type, file: file, selfType: selfType) }
            return .function(ps, resolveType(f.returnClause.type, file: file, selfType: selfType))
        }
        if let tt = t.as(TupleTypeSyntax.self) {
            if tt.elements.isEmpty { return .void }
            if tt.elements.count == 1, let e = tt.elements.first, e.firstName == nil { return resolveType(e.type, file: file, selfType: selfType) }
            use("syntax.tuple")
            return .tuple(tt.elements.map { resolveType($0.type, file: file, selfType: selfType) },
                          tt.elements.map { $0.firstName?.text })
        }
        if let at = t.as(AttributedTypeSyntax.self) { return resolveType(at.baseType, file: file, selfType: selfType) }
        unsupported("类型写法 '\(t.trimmedDescription)'", t, "syntax.typeAnnotation", file: file)
        return .unknown
    }

    /// 纯语法的初值类型推断（用于没有类型标注的存储属性 / 全局变量）。
    func literalType(_ e: ExprSyntax) -> SType {
        if e.is(IntegerLiteralExprSyntax.self) { return .int }
        if e.is(FloatLiteralExprSyntax.self) { return .double }
        if e.is(StringLiteralExprSyntax.self) { return .string }
        if e.is(BooleanLiteralExprSyntax.self) { return .bool }
        if let p = e.as(PrefixOperatorExprSyntax.self), p.operator.text == "-" { return literalType(p.expression) }
        if let a = e.as(ArrayExprSyntax.self) {
            var t: SType = .unknown
            for el in a.elements {
                let et = literalType(el.expression)
                if t == .unknown { t = et } else if t == .int && et == .double { t = .double }
            }
            return t == .unknown && a.elements.isEmpty ? .unknown : .array(t)
        }
        if let d = e.as(DictionaryExprSyntax.self), case .elements(let els) = d.content, let first = els.first {
            return .dict(literalType(first.key), literalType(first.value))
        }
        if let call = e.as(FunctionCallExprSyntax.self) {
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let n = ref.baseName.text
                if let tid = typeByName[n] { return .named(tid, n) }
                if n == "String" { return .string }
            }
            if let arr = call.calledExpression.as(ArrayExprSyntax.self), arr.elements.count == 1, let el = arr.elements.first,
               let tn = el.expression.as(DeclReferenceExprSyntax.self) {
                return .array(typeFromName(tn.baseName.text))
            }
            if let dict = call.calledExpression.as(DictionaryExprSyntax.self), case .elements(let els) = dict.content, els.count == 1,
               let el = els.first {
                return .dict(typeFromName(el.key.trimmedDescription), typeFromName(el.value.trimmedDescription))
            }
        }
        if let m = e.as(MemberAccessExprSyntax.self), let base = m.base?.as(DeclReferenceExprSyntax.self),
           let tid = typeByName[base.baseName.text] {
            let td = types[tid]
            if td.kind == .enumType && td.caseIndex(m.declName.baseName.text) != nil { return .named(tid, td.name) }
        }
        if let infix = e.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           ["+", "-", "*", "/"].contains(op.operator.text) {
            let l = literalType(infix.leftOperand), r = literalType(infix.rightOperand)
            if l == .double || r == .double { return .double }
            if l == .int && r == .int { return .int }
            if l == .string && r == .string { return .string }
        }
        return .unknown
    }

    func typeFromName(_ n: String) -> SType {
        switch n {
        case "Int": return .int
        case "Double", "CGFloat": return .double
        case "String", "Character": return .string
        case "Bool": return .bool
        default: if let t = typeByName[n] { return .named(t, n) }
        }
        return .unknown
    }

    // MARK: - 签名解析与函数编号分配

    func resolveSignatures() {
        for t in types {
            let f = t.fileIndex
            for field in t.fields {
                if let ts = field.typeSyntax { field.type = resolveType(ts, file: field.fileIndex, selfType: t.id) } else if let i = field.initializer {
                    field.type = literalType(i)
                }
            }
            for c in t.computed {
                if let ts = c.typeSyntax { c.type = resolveType(ts, file: c.fileIndex, selfType: t.id) }
                c.functionID = allocFunction()
                if c.setterBody != nil { c.setterFunctionID = allocFunction() }
            }
            for f in t.fields where f.didSetBody != nil { f.didSetFunctionID = allocFunction() }
            for g in t.statics where g.didSetBody != nil { g.didSetFunctionID = allocFunction() }
            for m in t.methods {
                resolveFunc(m, selfType: t.id)
            }
            for i in t.inits {
                for k in i.params.indices {
                    if let ts = i.params[k].typeSyntax { i.params[k].type = resolveType(ts, file: i.fileIndex, selfType: t.id) }
                }
                i.functionID = allocFunction()
            }
            if t.fields.contains(where: { $0.initializer != nil || ($0.type.isOptional && !$0.isLet) }) {
                t.defaultsFunction = allocFunction()
            }
            if t.kind == .enumType {
                if t.cases.isEmpty && t.rawType == nil {
                    // 空枚举合法（命名空间用途），无需处理
                }
                computeRawValues(t)
            }
            _ = f
        }
        for key in funcs.keys.sorted() {
            for fn in funcs[key] ?? [] { resolveFunc(fn, selfType: nil) }
        }
        for g in globals {
            if let ts = g.typeSyntax { g.type = resolveType(ts, file: g.fileIndex, selfType: g.ownerType) } else if let i = g.initializer {
                g.type = literalType(i)
            }
            if g.didSetBody != nil { g.didSetFunctionID = allocFunction() }
            if !g.isMainTopLevel { globalInitFunctions[g.globalID] = allocFunction() }
        }
    }

    func resolveFunc(_ fn: FuncDecl, selfType: Int?) {
        for k in fn.params.indices {
            if let ts = fn.params[k].typeSyntax { fn.params[k].type = resolveType(ts, file: fn.fileIndex, selfType: selfType) }
        }
        if let r = fn.node.signature.returnClause { fn.returnType = resolveType(r.type, file: fn.fileIndex, selfType: selfType) }
        fn.functionID = allocFunction()
    }

    func computeRawValues(_ t: TypeDecl) {
        guard let raw = t.rawType else {
            for c in t.cases where c.rawValue != nil {
                error(.typeCheck, "enum '\(t.name)' 没有声明原始值类型，case '\(c.name)' 不能有原始值。", c.node, file: t.fileIndex)
            }
            return
        }
        var out: [RawValueConst] = []
        var next = 0
        var seen = Set<RawValueConst>()
        for c in t.cases {
            var v: RawValueConst?
            if let e = c.rawValue {
                switch raw {
                case .int:
                    if let lit = e.as(IntegerLiteralExprSyntax.self), let x = lit.representedLiteralValue { v = .int(x) } else if
                        let p = e.as(PrefixOperatorExprSyntax.self), p.operator.text == "-",
                        let lit = p.expression.as(IntegerLiteralExprSyntax.self), let x = lit.representedLiteralValue { v = .int(-x) }
                    if case .int(let x)? = v { next = x &+ 1 }
                case .string:
                    if let s = e.as(StringLiteralExprSyntax.self), let x = s.representedLiteralValue { v = .string(x) }
                case .double:
                    if let d = e.as(FloatLiteralExprSyntax.self), let x = d.representedLiteralValue { v = .double(x) } else if
                        let i = e.as(IntegerLiteralExprSyntax.self), let x = i.representedLiteralValue { v = .double(Double(x)) }
                default: break
                }
                if v == nil {
                    error(.typeCheck, "enum 原始值必须是与原始值类型一致的字面量。", e, file: t.fileIndex)
                    v = .int(0)
                }
            } else {
                switch raw {
                case .int: v = .int(next); next &+= 1
                case .string: v = .string(c.name)
                default:
                    error(.typeCheck, "Double 原始值的 case '\(c.name)' 需要显式原始值。", c.node, file: t.fileIndex)
                    v = .double(0)
                }
            }
            if let v {
                if seen.contains(v) { error(.typeCheck, "enum 原始值重复。", c.node, file: t.fileIndex) }
                seen.insert(v)
                out.append(v)
            }
        }
        _rawValues[t.id] = out
    }

    // MARK: - 运行期类型元数据

    func buildRuntimeTypes() {
        runtimeTypes = types.map { t in
            var info = RuntimeTypeInfo(id: t.id, name: t.name, kind: t.kind == .structType ? .structType : .enumType)
            info.fieldNames = t.fields.map(\.name)
            info.fieldTypes = t.fields.map(\.type)
            info.fieldWrappers = t.fields.map(\.wrapper)
            for (i, f) in t.fields.enumerated() { info.fieldIndex[f.name] = i }
            for c in t.computed where !c.isStatic { info.computed[c.name] = c.functionID }
            for c in t.computed where !c.isStatic && c.setterFunctionID >= 0 { info.computedSetters[c.name] = c.setterFunctionID }
            for f in t.fields where f.didSetFunctionID >= 0 { info.didSetFields[f.name] = f.didSetFunctionID }
            for m in t.methods {
                info.methods[m.fullName] = MethodInfo(function: m.functionID, isMutating: m.isMutating, isStatic: m.isStatic,
                                                      paramLabels: m.labels, paramTypes: m.params.map(\.type), returnType: m.returnType,
                                                      defaultArgCount: m.params.filter { $0.defaultValue != nil }.count)
            }
            info.isView = t.isView
            info.isApp = t.isApp
            info.bodyGetter = t.computed.first { $0.name == "body" && !$0.isStatic }?.functionID
            info.defaultsFunction = t.defaultsFunction >= 0 ? t.defaultsFunction : nil
            info.zeroArgInit = t.inits.first(where: { $0.params.isEmpty })?.functionID
            info.caseNames = t.cases.map(\.name)
            info.casePayloadLabels = t.cases.map { $0.associated.map(\.label) }
            info.rawValues = _rawValues[t.id]
            info.conformances = Set(t.conformances)
            return info
        }
    }
}
