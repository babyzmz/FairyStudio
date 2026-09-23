import RuntimeContracts
import SwiftSyntax

/// 调用实参（含尾随闭包）。
struct CallArg {
    let label: String?
    let expr: ExprSyntax
    let isTrailing: Bool
    var closure: ClosureExprSyntax? { expr.as(ClosureExprSyntax.self) }
}

/// 形参描述（用户函数 / init / memberwise init 统一匹配）。
struct FormalParam {
    let label: String?
    let type: SType
    let hasDefault: Bool
    let defaultValue: ExprSyntax?
    /// memberwise init：对应的字段索引
    var fieldIndex: Int = -1
}

enum MethodReceiver {
    case implicitSelf
    case expr(ExprSyntax)
    case staticType
}

extension Compiler {
    func collectArgs(_ call: FunctionCallExprSyntax) -> [CallArg] {
        var args = call.arguments.map { CallArg(label: $0.label?.text, expr: $0.expression, isTrailing: false) }
        if let tc = call.trailingClosure { args.append(CallArg(label: nil, expr: ExprSyntax(tc), isTrailing: true)) }
        for mt in call.additionalTrailingClosures {
            args.append(CallArg(label: mt.label.text, expr: ExprSyntax(mt.closure), isTrailing: true))
            use("syntax.closure.multipleTrailing")
        }
        if call.trailingClosure != nil { use("syntax.closure.trailing") }
        return args
    }

    /// Swift 的实参-形参匹配（标签按顺序匹配，可省略有默认值的形参；首个尾随闭包前向扫描到下一个函数类型形参）。
    func matchParams(_ params: [FormalParam], _ args: [CallArg]) -> [Int?]? {
        var mapping = [Int?](repeating: nil, count: params.count)
        var pi = 0
        for (ai, a) in args.enumerated() where !a.isTrailing {
            while pi < params.count && params[pi].label != a.label {
                if !params[pi].hasDefault { return nil }
                pi += 1
            }
            guard pi < params.count else { return nil }
            mapping[pi] = ai
            pi += 1
        }
        var first = true
        for (ai, a) in args.enumerated() where a.isTrailing {
            if first && a.label == nil {
                while pi < params.count {
                    if case .function = params[pi].type { break }
                    if !params[pi].type.isKnown { break }
                    if !params[pi].hasDefault { return nil }
                    pi += 1
                }
                guard pi < params.count else { return nil }
                mapping[pi] = ai
                pi += 1
            } else {
                guard let idx = (pi..<params.count).first(where: { params[$0].label == a.label }) else { return nil }
                for j in pi..<idx where !params[j].hasDefault { return nil }
                mapping[idx] = ai
                pi = idx + 1
            }
            first = false
        }
        for j in 0..<params.count where mapping[j] == nil && !params[j].hasDefault { return nil }
        return mapping
    }

    func formalParams(_ ps: [ParamSig]) -> [FormalParam] {
        ps.map { FormalParam(label: $0.label, type: $0.type, hasDefault: $0.defaultValue != nil, defaultValue: $0.defaultValue) }
    }

    func signatureText(_ base: String, _ ps: [FormalParam]) -> String {
        base + "(" + ps.map { ($0.label ?? "_") + ":" }.joined() + ")"
    }

    /// 按形参顺序编译实参（缺省的使用默认值表达式）。返回实参类型。
    @discardableResult
    func compileMatchedArgs(_ params: [FormalParam], _ mapping: [Int?], _ args: [CallArg]) -> [SType] {
        var types: [SType] = []
        for (i, p) in params.enumerated() {
            if let ai = mapping[i] {
                let t = compileArgValue(args[ai], expected: p.type.isKnown ? p.type : nil)
                if p.type.isKnown { checkAssignable(p.type, t, args[ai].expr) }
                types.append(t)
            } else if let d = p.defaultValue {
                use("syntax.function.defaultArguments")
                types.append(compileExpr(d, expected: p.type.isKnown ? p.type : nil))
            } else if p.type.isOptional {
                emit(.pushNil)
                types.append(p.type)
            } else {
                emit(.pushVoid)
                types.append(.unknown)
            }
        }
        return types
    }

    func compileArgValue(_ a: CallArg, expected: SType?) -> SType {
        if let c = a.closure { return compileClosure(c, expected: expected, builder: false) }
        return compileExpr(a.expr, expected: expected)
    }

    // MARK: - 调用入口

    func compileCall(_ call: FunctionCallExprSyntax, expected: SType?) -> SType {
        let args = collectArgs(call)
        let callee = call.calledExpression
        if let ref = callee.as(DeclReferenceExprSyntax.self), ref.argumentNames == nil, !ref.baseName.text.hasPrefix("$") || isDollarShorthand(ref.baseName.text) {
            return compileNamedCall(ref.baseName.text, node: Syntax(ref), args: args, expected: expected, call: call)
        }
        if let m = callee.as(MemberAccessExprSyntax.self) {
            return compileMemberCall(m, args: args, expected: expected, call: call)
        }
        if let arr = callee.as(ArrayExprSyntax.self), arr.elements.count == 1, args.isEmpty, let el = arr.elements.first {
            let et = typeFromTypeExpr(el.expression)
            emit(.makeArray(0))
            return .array(et)
        }
        if let d = callee.as(DictionaryExprSyntax.self), case .elements(let els) = d.content, els.count == 1, args.isEmpty, let el = els.first {
            emit(.makeDict(0))
            return .dict(typeFromTypeExpr(el.key), typeFromTypeExpr(el.value))
        }
        // 调用一个函数值
        let ct = compileExpr(callee, expected: nil)
        return compileCallValue(ct, args: args)
    }

    func typeFromTypeExpr(_ e: ExprSyntax) -> SType {
        if let ref = e.as(DeclReferenceExprSyntax.self) { return typeFromName(ref.baseName.text) }
        if let a = e.as(ArrayExprSyntax.self), a.elements.count == 1, let el = a.elements.first { return .array(typeFromTypeExpr(el.expression)) }
        return .unknown
    }

    /// 被调用者已在栈上。
    func compileCallValue(_ ct: SType, args: [CallArg]) -> SType {
        var ps: [SType] = []
        var ret: SType = .unknown
        if case .function(let p, let r) = ct {
            ps = p
            ret = r
            if p.count != args.count {
                error(.typeCheck, "调用参数个数不匹配：需要 \(p.count) 个，提供了 \(args.count) 个。", args.first?.expr ?? ExprSyntax(NilLiteralExprSyntax()))
            }
        } else if ct.isKnown && ct != .symbol {
            if case .metatype = ct {} else if case .builtinType = ct {} else {
                error(.typeCheck, "'\(ct)' 类型的值不能被调用。", args.first?.expr ?? ExprSyntax(NilLiteralExprSyntax()))
            }
        }
        for (i, a) in args.enumerated() {
            _ = compileArgValue(a, expected: i < ps.count ? ps[i] : nil)
        }
        emit(.callValue(argc: args.count))
        return ret
    }

    func compileNamedCall(_ name: String, node: Syntax, args: [CallArg], expected: SType?, call: FunctionCallExprSyntax) -> SType {
        // 1. 局部变量中的闭包 / 嵌套函数
        if fb.peek(name) != nil {
            let ct = compileIdentifierLoad(name, node: node, expected: nil)
            return compileCallValue(ct, args: args)
        }
        // 2. 隐式 self 方法
        if let t = selfTypeDecl() ?? fb.enclosingStaticType.map({ types[$0] }), !t.methods(named: name).isEmpty {
            return compileMethodCallOnType(t.id, receiver: .implicitSelf, name, args: args, node: node)
        }
        // 静态上下文中的静态存储属性 / 全局变量中保存的闭包
        if let st = fb.enclosingStaticType, types[st].staticField(name) != nil {
            let ct = compileIdentifierLoad(name, node: node, expected: nil)
            return compileCallValue(ct, args: args)
        }
        if globalByName[name] != nil {
            let ct = compileIdentifierLoad(name, node: node, expected: nil)
            return compileCallValue(ct, args: args)
        }
        // 3. 用户类型构造
        if let tid = typeByName[name] {
            _ = checkVisible(name, declFile: types[tid].fileIndex, access: types[tid].access, node)
            return compileTypeInit(tid, args: args, node: node)
        }
        // 4. 用户顶层函数
        if let decls = funcs[name] {
            let visible = decls.filter { !$0.access.isFileScoped || $0.fileIndex == fb.fileIndex }
            if visible.isEmpty, let f = decls.first {
                _ = checkVisible(name, declFile: f.fileIndex, access: f.access, node)
                emit(.pushVoid)
                return .unknown
            }
            var matches: [(FuncDecl, [Int?])] = []
            for d in visible {
                if let m = matchParams(formalParams(d.params), args) { matches.append((d, m)) }
            }
            guard let chosen = pickOverload(matches, args) else {
                let sigs = visible.map { signatureText(name, formalParams($0.params)) }.joined(separator: "、")
                error(.typeCheck, "调用 '\(name)' 的参数与声明不匹配（可用：\(sigs)）。", call)
                emit(.pushVoid)
                return .unknown
            }
            use("syntax.function.argumentLabels")
            let (decl, mapping) = chosen
            compileMatchedArgs(formalParams(decl.params), mapping, args)
            emit(.call(function: decl.functionID, argc: decl.params.count))
            if decl.functionID == fb.id { use("syntax.recursion") }
            return decl.returnType
        }
        // 5. 内建
        if builtinFunctionNames.contains(name) { return compileBuiltinFunction(name, args: args, node: node, expected: expected, call: call) }
        if ["Int", "Double", "String", "Array", "Dictionary", "CGFloat", "Bool", "Character"].contains(name) {
            return compileConversion(name, args: args, node: node, call: call)
        }
        if viewSignatures[name] != nil { return compileViewConstruct(name, args: args, node: node, call: call) }
        if name == "WindowGroup" {
            error(.typeCheck, "WindowGroup 只能出现在 @main App 的 body 中。", node, capability: "syntax.mainApp")
            emit(.pushVoid)
            return .unknown
        }
        if knownUnsupportedTypes.contains(name) || knownUnsupportedFunctions.contains(name) {
            unsupportedAPI(name, node, unsupportedNameCapability(name))
            emit(.pushVoid)
            return .unknown
        }
        error(.nameResolution, "找不到 '\(name)'（未声明的函数或类型）。", node)
        emit(.pushVoid)
        return .unknown
    }

    /// 多个重载都匹配时，按实参的推断类型挑选。
    func pickOverload<D>(_ matches: [(D, [Int?])], _ args: [CallArg], params: (D) -> [FormalParam]) -> (D, [Int?])? {
        if matches.count <= 1 { return matches.first }
        var best: (D, [Int?])?
        var bestScore = -1
        for (d, m) in matches {
            var score = 0
            for (i, p) in params(d).enumerated() {
                guard let ai = m[i] else { continue }
                let q = quickType(args[ai].expr)
                if q.isKnown && p.type.isKnown {
                    if q == p.type || q.unwrapped == p.type.unwrapped { score += 2 } else if !(q == .int && p.type == .double && numericLiteralKind(args[ai].expr) != nil) {
                        score -= 5
                    }
                }
            }
            if score > bestScore { bestScore = score; best = (d, m) }
        }
        return best
    }

    func pickOverload(_ matches: [(FuncDecl, [Int?])], _ args: [CallArg]) -> (FuncDecl, [Int?])? {
        pickOverload(matches, args) { self.formalParams($0.params) }
    }

    // MARK: - 方法调用

    func compileMethodCallOnType(_ tid: Int, receiver: MethodReceiver, _ name: String, args: [CallArg], node: Syntax) -> SType {
        let t = types[tid]
        let wantStatic: Bool?
        switch receiver {
        case .staticType: wantStatic = true
        case .expr: wantStatic = false
        case .implicitSelf: wantStatic = fb.peek("self") == nil ? true : nil
        }
        let candidates = t.methods(named: name).filter { wantStatic == nil || $0.isStatic == wantStatic }
        var matches: [(FuncDecl, [Int?])] = []
        for d in candidates {
            if let m = matchParams(formalParams(d.params), args) { matches.append((d, m)) }
        }
        guard let (decl, mapping) = pickOverload(matches, args) else {
            if candidates.isEmpty {
                let kind = wantStatic == true ? "静态方法" : "实例方法"
                error(.nameResolution, "'\(t.name)' 没有\(kind) '\(name)'。", node)
            } else {
                let sigs = candidates.map { signatureText(name, formalParams($0.params)) }.joined(separator: "、")
                error(.typeCheck, "调用 '\(t.name).\(name)' 的参数与声明不匹配（可用：\(sigs)）。", node)
            }
            emit(.pushVoid)
            return .unknown
        }
        checkMemberVisible(name, of: t, declFile: decl.fileIndex, access: decl.access, node)
        let params = formalParams(decl.params)
        if decl.isStatic {
            compileMatchedArgs(params, mapping, args)
            emit(.call(function: decl.functionID, argc: params.count))
            return decl.returnType
        }
        if decl.isMutating {
            let place: PlaceInfo?
            switch receiver {
            case .implicitSelf: place = resolveNamePlace("self", node: node)
            case .expr(let e): place = resolvePlace(e)
            case .staticType: place = nil
            }
            guard let p = place else {
                error(.typeCheck, "不能对不可变的值调用 mutating 方法 '\(name)'。", node)
                emit(.pushVoid)
                return .unknown
            }
            checkMutable(p, node, action: "调用 mutating 方法 '\(name)'")
            for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
            compileMatchedArgs(params, mapping, args)
            emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .callMutating(function: decl.functionID, argc: params.count)))
            return decl.returnType
        }
        switch receiver {
        case .implicitSelf:
            guard let rv = fb.lookup("self") else {
                error(.typeCheck, "静态上下文中不能调用实例方法 '\(name)'。", node)
                emit(.pushVoid)
                return .unknown
            }
            emitLoad(rv)
        case .expr(let e): _ = compileChainBase(e)
        case .staticType: break
        }
        compileMatchedArgs(params, mapping, args)
        emit(.call(function: decl.functionID, argc: params.count + 1))
        if decl.functionID == fb.id { use("syntax.recursion") }
        return decl.returnType
    }

    func compileMemberCall(_ m: MemberAccessExprSyntax, args: [CallArg], expected: SType?, call: FunctionCallExprSyntax) -> SType {
        let name = m.declName.baseName.text
        guard let base = m.base else {
            unsupportedAPI("隐式成员调用 .\(name)(…)", m, "syntax.implicitMemberCall")
            emit(.pushVoid)
            return .unknown
        }
        if let tref = staticTypeReference(base) {
            switch tref {
            case .user(let tid):
                if name == "init" { return compileTypeInit(tid, args: args, node: Syntax(m)) }
                return compileMethodCallOnType(tid, receiver: .staticType, name, args: args, node: Syntax(m.declName))
            case .builtin(let tn):
                unsupportedAPI("\(tn).\(name)(…)", m, knownUnsupportedTypes.contains(tn) ? unsupportedNameCapability(tn) : "stdlib.\(tn).\(name)")
                emit(.pushVoid)
                return .unknown
            }
        }
        if isProjectionRoot(base) {
            unsupported("对 Binding 调用方法", m, "propertyWrapper.Binding")
            emit(.pushVoid)
            return .unknown
        }
        let rt = quickType(base)
        switch rt {
        case .named(let tid, _):
            let t = types[tid]
            if !t.methods(named: name).filter({ !$0.isStatic }).isEmpty {
                return compileMethodCallOnType(tid, receiver: .expr(base), name, args: args, node: Syntax(m.declName))
            }
            if t.isView { return compileModifierCall(base, name, args: args, node: m) }
            error(.nameResolution, "'\(t.name)' 没有方法 '\(name)'。", m.declName)
            emit(.pushVoid)
            return .unknown
        case .view:
            return compileModifierCall(base, name, args: args, node: m)
        case .array, .string, .dict, .range, .int, .double, .bool:
            return compileBuiltinMethodCall(base, rt, name, args: args, node: m)
        case .optional:
            if !base.is(OptionalChainingExprSyntax.self) {
                error(.typeCheck, "可选类型 '\(rt)' 的值必须先解包才能调用 '\(name)'。", m.declName, suggestion: "使用 ?. 可选链、if let 或 !")
            }
        default:
            break
        }
        // 动态分派（接收者类型未知）
        let labels = args.map { $0.isTrailing && $0.label == nil ? nil : $0.label }
        let full = fullName(name, labels)
        let maybeMutating = possiblyMutatingBuiltinNames.contains(full) || userMutatingMethodNames.contains(full)
        if maybeMutating, let p = resolvePlace(base), p.mutable {
            for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
            for a in args { _ = compileArgValue(a, expected: nil) }
            emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .callMethod(name: full, argc: args.count)))
            return .unknown
        }
        _ = compileChainBase(base)
        for a in args { _ = compileArgValue(a, expected: nil) }
        emit(.callMethod(name: full, argc: args.count))
        return .unknown
    }

    var userMutatingMethodNames: Set<String> {
        Set(types.flatMap { $0.methods.filter(\.isMutating).map(\.fullName) })
    }

    func compileBuiltinMethodCall(_ base: ExprSyntax, _ rt: SType, _ name: String, args: [CallArg], node: MemberAccessExprSyntax) -> SType {
        let explicit = args.filter { !$0.isTrailing }.map(\.label)
        let trailing = args.filter(\.isTrailing)
        var candidates: [[String?]] = []
        if trailing.isEmpty {
            candidates = [explicit]
        } else {
            let rest = trailing.dropFirst().map(\.label)
            for tl in [nil, "by", "where", "perform"] as [String?] { candidates.append(explicit + [tl] + rest) }
        }
        var found: (String, MethodSig)?
        for c in candidates {
            let full = fullName(name, c)
            guard let s = builtinMethodSig(rt, full), s.params.count == args.count else { continue }
            // 闭包实参必须落在函数类型形参上（`contains { … }` 选 contains(where:) 而不是 contains(_:)）
            let fits = args.indices.allSatisfy { i in
                guard args[i].closure != nil else { return true }
                if case .function = s.params[i] { return true }
                return false
            }
            if fits { found = (full, s); break }
        }
        let tn = builtinTypeName(rt) ?? "?"
        guard let (full, sig) = found else {
            unsupportedAPI("\(tn).\(fullName(name, candidates.first ?? []))（若这不是标准库方法，请检查拼写）", node.declName, "stdlib.\(tn).\(name)")
            emit(.pushVoid)
            return .unknown
        }
        use(sig.capability)
        var argTypes: [SType] = []
        func compileArgs() {
            for (i, a) in args.enumerated() {
                var exp: SType? = i < sig.params.count ? sig.params[i] : nil
                if exp == .unknown { exp = nil }
                if full == "reduce(_:_:)" {
                    let elem = elementType(of: rt)
                    if i == 0 {
                        if numericLiteralKind(a.expr) != nil && elem.isNumeric { exp = elem }
                    } else {
                        let acc = argTypes.first ?? .unknown
                        exp = .function([acc, elem], acc)
                    }
                }
                argTypes.append(compileArgValue(a, expected: exp))
            }
        }
        if sig.mutating {
            guard let p = resolvePlace(base) else {
                error(.typeCheck, "不能对不可变的值调用 mutating 方法 '\(name)'。", node.declName)
                emit(.pushVoid)
                return .unknown
            }
            checkMutable(p, node.declName, action: "调用 mutating 方法 '\(name)'")
            for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
            compileArgs()
            emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .callMethod(name: full, argc: args.count)))
        } else {
            _ = compileChainBase(base)
            compileArgs()
            emit(.callMethod(name: full, argc: args.count))
        }
        var closureResult: SType = .unknown
        for t in argTypes { if case .function(_, let r) = t { closureResult = r; break } }
        return sig.result(closureResult, argTypes)
    }

    // MARK: - 构造

    func memberwiseParams(_ t: TypeDecl) -> [FormalParam] {
        var out: [FormalParam] = []
        for (i, f) in t.fields.enumerated() {
            if f.isLet && f.initializer != nil { continue }
            let type: SType = f.wrapper == .binding ? .binding(f.type) : f.type
            var p = FormalParam(label: f.name, type: type, hasDefault: f.initializer != nil || (f.type.isOptional && !f.isLet),
                                defaultValue: nil)
            p.fieldIndex = i
            out.append(p)
        }
        return out
    }

    func compileTypeInit(_ tid: Int, args: [CallArg], node: Syntax) -> SType {
        let t = types[tid]
        if t.kind == .enumType {
            if args.count == 1, args[0].label == "rawValue", let raw = t.rawType {
                use("syntax.enum.rawValue")
                emit(.pushMetatype(tid))
                compileExpr(args[0].expr, expected: raw)
                emit(.callBuiltin(name: "__enumFromRaw", labels: [nil, nil]))
                return .optional(.named(tid, t.name))
            }
            unsupported("此种 enum 构造方式", node, "syntax.enum")
            emit(.pushVoid)
            return .unknown
        }
        // 显式 init
        var matches: [(InitDecl, [Int?])] = []
        for i in t.inits {
            if let m = matchParams(formalParams(i.params), args) { matches.append((i, m)) }
        }
        if let (decl, mapping) = pickOverload(matches, args, params: { self.formalParams($0.params) }) {
            checkMemberVisible("init", of: t, declFile: decl.fileIndex, access: decl.access, node)
            let params = formalParams(decl.params)
            compileMatchedArgs(params, mapping, args)
            emit(.callInit(type: tid, function: decl.functionID, argc: params.count))
            return .named(tid, t.name)
        }
        if !t.hasInitInBody {
            let params = memberwiseParams(t)
            if let mapping = matchParams(params, args) {
                use("syntax.struct.memberwiseInit")
                var fields: [Int] = []
                for (i, p) in params.enumerated() {
                    guard let ai = mapping[i] else { continue }
                    let f = t.fields[p.fieldIndex]
                    if f.access.isFileScoped && f.fileIndex != fb.fileIndex {
                        error(.nameResolution, "'\(t.name)' 的逐一成员构造器不可访问：属性 '\(f.name)' 是 \(f.access.keyword)（声明于 \(files[f.fileIndex].fileName)）。",
                              args[ai].expr)
                    }
                    let at = compileArgValue(args[ai], expected: p.type.isKnown ? p.type : nil)
                    if p.type.isKnown { checkAssignable(p.type, at, args[ai].expr) }
                    fields.append(p.fieldIndex)
                }
                emit(.construct(type: tid, fields: fields))
                return .named(tid, t.name)
            }
            if t.inits.isEmpty {
                let sig = signatureText(t.name, params)
                let missing = params.filter { !$0.hasDefault }.map { $0.label ?? "_" }
                error(.typeCheck, "构造 '\(t.name)' 的参数不匹配：逐一成员构造器为 \(sig)" + (missing.isEmpty ? "" : "，必需参数：\(missing.joined(separator: "、"))") + "（标签顺序需与属性声明顺序一致）。", node)
                emit(.pushVoid)
                return .unknown
            }
        }
        let sigs = t.inits.map { signatureText("init", formalParams($0.params)) }.joined(separator: "、")
        error(.typeCheck, "构造 '\(t.name)' 的参数不匹配（可用：\(sigs.isEmpty ? "无" : sigs)）。", node)
        emit(.pushVoid)
        return .unknown
    }

    // MARK: - 内建函数

    func requireNoTrailing(_ args: [CallArg], _ node: Syntax) -> Bool {
        if args.contains(where: \.isTrailing) {
            error(.typeCheck, "此函数不接受尾随闭包。", node)
            return false
        }
        return true
    }

    func compileBuiltinFunction(_ name: String, args: [CallArg], node: Syntax, expected: SType?, call: FunctionCallExprSyntax) -> SType {
        guard requireNoTrailing(args, node) else { emit(.pushVoid); return .unknown }
        let labels = args.map(\.label)
        switch name {
        case "print":
            use("stdlib.print")
            for a in args {
                switch a.label {
                case nil:
                    let t = compileExpr(a.expr, expected: nil)
                    emit(.describe(t))
                case "separator", "terminator":
                    compileExpr(a.expr, expected: .string)
                default:
                    error(.typeCheck, "print 不支持参数标签 '\(a.label!)'。", a.expr)
                    emit(.pushString(""))
                }
            }
            emit(.callBuiltin(name: "print", labels: labels))
            return .void
        case "min", "max":
            use("stdlib.\(name)")
            guard args.count >= 2, labels.allSatisfy({ $0 == nil }) else {
                error(.typeCheck, "\(name) 需要至少两个无标签参数。", call)
                emit(.pushVoid)
                return .unknown
            }
            let common = commonNumericType(args.map(\.expr))
            var ts: [SType] = []
            for a in args { ts.append(compileExpr(a.expr, expected: common)) }
            checkSameTypes(ts, call, name)
            emit(.callBuiltin(name: name, labels: labels))
            return common ?? ts.first(where: \.isKnown) ?? .unknown
        case "abs":
            use("stdlib.abs")
            guard labels == [nil] else { break }
            let t = compileExpr(args[0].expr, expected: expected?.isNumeric == true ? expected : nil)
            emit(.callBuiltin(name: name, labels: labels))
            return t
        case "stride":
            use("stdlib.stride")
            guard labels == ["from", "to", "by"] || labels == ["from", "through", "by"] else { break }
            let common = commonNumericType(args.map(\.expr)) ?? .int
            var ts: [SType] = []
            for a in args { ts.append(compileExpr(a.expr, expected: common)) }
            checkSameTypes(ts, call, name)
            emit(.callBuiltin(name: name, labels: labels))
            return .array(common)
        case "fatalError":
            use("stdlib.fatalError")
            guard labels.isEmpty || labels == [nil] else { break }
            for a in args { compileExpr(a.expr, expected: .string) }
            emit(.callBuiltin(name: name, labels: labels))
            return .unknown
        case "precondition", "assert":
            use("stdlib.\(name)")
            guard labels == [nil] || labels == [nil, nil] else { break }
            compileExpr(args[0].expr, expected: .bool)
            if args.count > 1 { compileExpr(args[1].expr, expected: .string) }
            emit(.callBuiltin(name: name, labels: labels))
            return .void
        case "sqrt", "floor", "ceil", "round", "sin", "cos", "exp", "log":
            use("stdlib.math")
            guard labels == [nil] else { break }
            let t = compileExpr(args[0].expr, expected: .double)
            if t == .int { error(.typeCheck, "\(name) 需要 Double 参数，得到 Int：请使用 Double(x)。", args[0].expr) }
            emit(.callBuiltin(name: name, labels: labels))
            return .double
        case "pow":
            use("stdlib.math")
            guard labels == [nil, nil] else { break }
            compileExpr(args[0].expr, expected: .double)
            compileExpr(args[1].expr, expected: .double)
            emit(.callBuiltin(name: name, labels: labels))
            return .double
        default:
            break
        }
        error(.typeCheck, "'\(name)' 的参数形式不受支持：\(fullName(name, labels))。", call)
        emit(.pushVoid)
        return .unknown
    }

    func commonNumericType(_ exprs: [ExprSyntax]) -> SType? {
        var sawDouble = false, sawInt = false, sawString = false
        for e in exprs {
            if let k = numericLiteralKind(e) {
                if k == .double { sawDouble = true }
                continue
            }
            let q = quickType(e).unwrapped
            if q == .double { sawDouble = true } else if q == .int { sawInt = true } else if q == .string { sawString = true }
        }
        if sawString { return .string }
        if sawDouble { return .double }
        if sawInt { return .int }
        return nil
    }

    func checkSameTypes(_ ts: [SType], _ node: some SyntaxProtocol, _ name: String) {
        let known = ts.filter(\.isKnown)
        if let f = known.first, known.contains(where: { $0 != f && $0.isConcreteScalar && f.isConcreteScalar }) {
            error(.typeCheck, "\(name) 的参数类型不一致（\(known.map(\.description).joined(separator: "、"))）：Swift 不做 Int 与 Double 的隐式转换。", node)
        }
    }

    func compileConversion(_ name: String, args: [CallArg], node: Syntax, call: FunctionCallExprSyntax) -> SType {
        guard requireNoTrailing(args, node) else { emit(.pushVoid); return .unknown }
        let labels = args.map(\.label)
        switch (name, labels) {
        case ("Int", [nil]), ("Double", [nil]), ("CGFloat", [nil]):
            let target = name == "Int" ? "Int" : "Double"
            use("stdlib.\(target).init")
            let t = compileExpr(args[0].expr, expected: nil)
            emit(.callBuiltin(name: target, labels: [nil]))
            if t == .string { return .optional(target == "Int" ? .int : .double) }
            if t.isKnown && !t.isNumeric && t != .unknown {
                error(.typeCheck, "不能把 '\(t)' 转换为 \(target)。", args[0].expr)
            }
            return target == "Int" ? .int : .double
        case ("String", [nil]), ("String", ["describing"]):
            use("stdlib.String.init")
            compileExpr(args[0].expr, expected: nil)
            emit(.callBuiltin(name: "String", labels: labels))
            return .string
        case ("String", ["repeating", "count"]):
            use("stdlib.String.init")
            compileExpr(args[0].expr, expected: .string)
            compileExpr(args[1].expr, expected: .int)
            emit(.callBuiltin(name: "String", labels: labels))
            return .string
        case ("Array", [nil]):
            use("stdlib.Array.init")
            let t = compileExpr(args[0].expr, expected: nil)
            emit(.callBuiltin(name: "Array", labels: labels))
            return .array(elementType(of: t))
        case ("Array", ["repeating", "count"]):
            use("stdlib.Array.init")
            let t = compileExpr(args[0].expr, expected: nil)
            compileExpr(args[1].expr, expected: .int)
            emit(.callBuiltin(name: "Array", labels: labels))
            return .array(t)
        case ("Array", []), ("Dictionary", []):
            emit(.callBuiltin(name: name, labels: []))
            return name == "Array" ? .array(.unknown) : .dict(.unknown, .unknown)
        default:
            break
        }
        if name == "Bool" || name == "Character" {
            unsupportedAPI("\(name)(…) 转换", node, "stdlib.\(name).init")
        } else {
            error(.typeCheck, "'\(fullName(name, labels))' 的参数形式不受支持。", call)
        }
        emit(.pushVoid)
        return .unknown
    }
}
