import RuntimeContracts
import SwiftSyntax

/// 类型名作为表达式基出现。
enum StaticTypeRef {
    case user(Int)
    case builtin(String)
}

/// 不受支持的 SwiftUI 视图名（capabilityID 用 view.X）。
let unsupportedViewNames: Set<String> = [
    "DatePicker", "ColorPicker", "Label", "Link", "Menu", "TabView", "LazyVStack", "LazyHStack",
    "LazyVGrid", "LazyHGrid", "Grid", "GridRow", "GeometryReader", "Circle", "Rectangle", "RoundedRectangle", "Capsule", "Ellipse",
    "Path", "Canvas", "TimelineView", "AsyncImage", "TextEditor", "Gauge", "ShareLink", "NavigationSplitView",
    "LinearGradient", "RadialGradient", "AngularGradient", "ToolbarItem", "EditButton", "ControlGroup", "DisclosureGroup",
    "OutlineGroup", "Table", "ContentUnavailableView", "ViewThatFits", "AnyView",
]

extension Compiler {
    func unsupportedNameCapability(_ name: String) -> String {
        unsupportedViewNames.contains(name) ? "view.\(name)" : "stdlib.\(name)"
    }

    // MARK: - 可见性

    /// 顶层声明的跨文件可见性检查。返回 false 表示不可见（已报错）。
    func checkVisible(_ name: String, declFile: Int, access: AccessLevel, _ node: some SyntaxProtocol) -> Bool {
        if access.isFileScoped && declFile != fb.fileIndex {
            error(.nameResolution, "找不到 '\(name)'：它在 \(files[declFile].fileName) 中声明为 \(access.keyword)，在 \(files[fb.fileIndex].fileName) 中不可见。",
                  node)
            return false
        }
        return true
    }

    /// 成员的跨文件可见性检查。
    func checkMemberVisible(_ member: String, of t: TypeDecl, declFile: Int, access: AccessLevel, _ node: some SyntaxProtocol) {
        if access.isFileScoped && declFile != fb.fileIndex {
            error(.nameResolution, "'\(member)' 是 '\(t.name)' 的 \(access.keyword) 成员（声明于 \(files[declFile].fileName)），在 \(files[fb.fileIndex].fileName) 中不可访问。",
                  node)
        }
    }

    // MARK: - 标识符

    func emitLoad(_ rv: ResolvedVar) {
        switch rv.location {
        case .local(let s): emit(.loadLocal(s))
        case .capture(let i): emit(.loadCapture(i))
        }
    }

    func isDollarShorthand(_ name: String) -> Bool {
        name.hasPrefix("$") && name.count > 1 && name.dropFirst().allSatisfy(\.isNumber)
    }

    func compileDeclReference(_ ref: DeclReferenceExprSyntax, expected: SType?) -> SType {
        let name = ref.baseName.text
        if ref.argumentNames != nil {
            unsupported("带参数标签的函数引用", ref, "syntax.functionReference")
            emit(.pushVoid)
            return .unknown
        }
        if case .binaryOperator = ref.baseName.tokenKind {
            return compileOperatorFunction(name, expected: expected, node: Syntax(ref))
        }
        if name.hasPrefix("$") && !isDollarShorthand(name) {
            return compileProjection(ExprSyntax(ref))
        }
        return compileIdentifierLoad(name, node: Syntax(ref), expected: expected)
    }

    func compileIdentifierLoad(_ name: String, node: Syntax, expected: SType?) -> SType {
        if name == "self" {
            if let rv = fb.lookup("self") {
                emitLoad(rv)
                return rv.info.type
            }
            if let t = fb.enclosingStaticType {
                emit(.pushMetatype(t))
                return .metatype(t, types[t].name)
            }
            error(.nameResolution, "这里没有 self（不在类型的方法中）。", node)
            emit(.pushVoid)
            return .unknown
        }
        if name == "Self", let t = currentSelfTypeID {
            emit(.pushMetatype(t))
            return .metatype(t, types[t].name)
        }
        if let rv = fb.lookup(name) {
            emitLoad(rv)
            return rv.info.type
        }
        // 隐式 self 成员
        if let selfType = selfTypeDecl() {
            if let (i, f) = selfType.fields.enumerated().first(where: { $0.element.name == name }), let rv = fb.lookup("self") {
                checkMemberVisible(name, of: selfType, declFile: f.fileIndex, access: f.access, node)
                emitLoad(rv)
                emit(.getField(i))
                return f.type
            }
            if let c = selfType.computedProp(name), !c.isStatic, let rv = fb.lookup("self") {
                checkMemberVisible(name, of: selfType, declFile: c.fileIndex, access: c.access, node)
                emitLoad(rv)
                emit(.getComputed(function: c.functionID))
                return c.type
            }
            if !selfType.methods(named: name).isEmpty {
                if case .function? = expected { return compileMethodReferenceClosure(name, selfType, node) }
                unsupported("方法引用（不调用的方法名）", node, "syntax.functionReference")
                emit(.pushVoid)
                return .unknown
            }
        }
        // 静态上下文成员
        if let st = fb.enclosingStaticType {
            let t = types[st]
            if let g = t.staticField(name) {
                emit(.loadGlobal(g.globalID))
                return g.type
            }
            if let c = t.computedProp(name), c.isStatic {
                emit(.call(function: c.functionID, argc: 0))
                return c.type
            }
        }
        if let gid = globalByName[name] {
            let g = globals[gid]
            _ = checkVisible(name, declFile: g.fileIndex, access: g.access, node)
            emit(.loadGlobal(gid))
            return g.type
        }
        if let list = funcs[name] {
            let visible = list.filter { !$0.access.isFileScoped || $0.fileIndex == fb.fileIndex }
            if visible.isEmpty, let f = list.first {
                _ = checkVisible(name, declFile: f.fileIndex, access: f.access, node)
            } else if let f = visible.first {
                if visible.count > 1 { warning("函数 '\(name)' 有多个重载，作为值使用时取第一个。", node) }
                emit(.pushFunction(f.functionID))
                return .function(f.params.map(\.type), f.returnType)
            }
            emit(.pushVoid)
            return .unknown
        }
        if let tid = typeByName[name] {
            _ = checkVisible(name, declFile: types[tid].fileIndex, access: types[tid].access, node)
            emit(.pushMetatype(tid))
            return .metatype(tid, name)
        }
        if builtinTypeNames.contains(name) || builtinFunctionNames.contains(name) {
            emit(.pushVoid)
            return .builtinType(name)
        }
        if knownUnsupportedTypes.contains(name) || knownUnsupportedFunctions.contains(name) {
            unsupportedAPI(name, node, unsupportedNameCapability(name))
            emit(.pushVoid)
            return .unknown
        }
        error(.nameResolution, "找不到 '\(name)'（未声明的变量、函数或类型）。", node)
        emit(.pushVoid)
        return .unknown
    }

    func selfTypeDecl() -> TypeDecl? {
        if case .named(let t, _)? = fb.peek("self")?.type { return types[t] }
        return nil
    }

    /// `action: increment` 这类方法引用：合成一个捕获 self 并调用该方法的闭包。
    func compileMethodReferenceClosure(_ name: String, _ t: TypeDecl, _ node: Syntax) -> SType {
        guard let decl = t.methods(named: name).first(where: { !$0.isStatic && $0.params.isEmpty }) else {
            unsupported("带参数的方法引用", node, "syntax.functionReference")
            emit(.pushVoid)
            return .unknown
        }
        if decl.isMutating {
            unsupported("mutating 方法引用", node, "syntax.functionReference")
            emit(.pushVoid)
            return .unknown
        }
        use("syntax.functionReference")
        let id = allocFunction()
        var caps: [CaptureSource] = []
        let parent = fb
        withFunction(id: id, name: "\(t.name).\(decl.fullName) 引用", file: fb.fileIndex, parent: parent) { b in
            b.returnType = decl.returnType
            if let rv = fb.lookup("self") { emitLoad(rv) } else { emit(.pushVoid) }
            emit(.call(function: decl.functionID, argc: 1))
            emit(.ret)
            caps = b.captures
        }
        emit(.makeClosure(function: id, captures: caps))
        return .function([], decl.returnType)
    }

    /// `+`、`>` 等运算符作为函数值（`reduce(0, +)`、`sorted(by: >)`）。
    func compileOperatorFunction(_ op: String, expected: SType?, node: Syntax) -> SType {
        guard let bop = BinOp(rawValue: op), bop != .halfOpenRange, bop != .closedRange else {
            unsupported("运算符 '\(op)' 作为函数值", node, "syntax.functionReference")
            emit(.pushVoid)
            return .unknown
        }
        use("syntax.functionReference")
        var ps: [SType] = [.unknown, .unknown]
        if case .function(let eps, _)? = expected, eps.count == 2 { ps = eps }
        let id = allocFunction()
        let parent = fb
        withFunction(id: id, name: "运算符 \(op)", file: fb.fileIndex, parent: parent) { b in
            b.paramCount = 2
            _ = declareLocal("lhs", isLet: true, type: ps[0])
            _ = declareLocal("rhs", isLet: true, type: ps[1])
            emit(.loadLocal(0))
            emit(.loadLocal(1))
            emit(.binary(bop, .none))
            emit(.ret)
        }
        emit(.makeClosure(function: id, captures: []))
        return .function(ps, bop.isComparison ? .bool : ps[0])
    }

    // MARK: - 成员访问

    func staticTypeReference(_ e: ExprSyntax) -> StaticTypeRef? {
        guard let ref = e.as(DeclReferenceExprSyntax.self) else { return nil }
        let name = ref.baseName.text
        if fb.peek(name) != nil { return nil }
        if name == "Self", let t = currentSelfTypeID { return .user(t) }
        if let t = typeByName[name] { return .user(t) }
        if builtinTypeNames.contains(name) || knownUnsupportedTypes.contains(name) { return .builtin(name) }
        return nil
    }

    func compileMemberAccess(_ m: MemberAccessExprSyntax, expected: SType?) -> SType {
        let name = m.declName.baseName.text
        // Date.now（只读时钟；Date 为保留的内建类型名，不经过用户类型表）
        if name == "now", let base = m.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "Date",
           fb.peek("Date") == nil, typeByName["Date"] == nil {
            use("stdlib.Date")
            emit(.callBuiltin(name: "Date", labels: []))
            return .date
        }
        guard let base = m.base else { return compileImplicitMember(name, expected: expected, node: Syntax(m)) }
        if isProjectionRoot(base) { return compileProjection(ExprSyntax(m)) }
        if let tref = staticTypeReference(base) {
            switch tref {
            case .user(let tid): return compileStaticMember(tid, name, node: Syntax(m.declName))
            case .builtin(let tn): return compileBuiltinStatic(tn, name, node: Syntax(m))
            }
        }
        let bt = compileChainBase(base)
        return compileMemberOnValue(bt, name, node: Syntax(m.declName))
    }

    func compileStaticMember(_ tid: Int, _ name: String, node: Syntax) -> SType {
        let t = types[tid]
        if let idx = t.caseIndex(name) {
            use("syntax.enum")
            if !t.cases[idx].associated.isEmpty {
                error(.typeCheck, "case '.\(name)' 需要提供关联值，例如 `\(t.name).\(name)(…)`。", node)
                emit(.pushVoid)
                return .unknown
            }
            emit(.pushEnum(type: tid, caseIndex: idx))
            return .named(tid, t.name)
        }
        if let g = t.staticField(name) {
            checkMemberVisible(name, of: t, declFile: g.fileIndex, access: g.access, node)
            emit(.loadGlobal(g.globalID))
            return g.type
        }
        if let c = t.computedProp(name), c.isStatic {
            checkMemberVisible(name, of: t, declFile: c.fileIndex, access: c.access, node)
            emit(.call(function: c.functionID, argc: 0))
            return c.type
        }
        if name == "allCases" && t.kind == .enumType && t.conformances.contains("CaseIterable") {
            emit(.pushMetatype(tid))
            emit(.getMember("allCases"))
            return .array(.named(tid, t.name))
        }
        error(.nameResolution, "类型 '\(t.name)' 没有静态成员 '\(name)'。", node)
        emit(.pushVoid)
        return .unknown
    }

    func compileBuiltinStatic(_ typeName: String, _ name: String, node: Syntax) -> SType {
        switch (typeName, name) {
        case ("Int", "max"): emit(.pushInt(Int.max)); return .int
        case ("Int", "min"): emit(.pushInt(Int.min)); return .int
        case ("Double", "pi"), ("CGFloat", "pi"): emit(.pushDouble(Double.pi)); return .double
        case ("Double", "infinity"), ("CGFloat", "infinity"): emit(.pushDouble(Double.infinity)); return .double
        case ("Double", "nan"): emit(.pushDouble(Double.nan)); return .double
        case ("Double", "greatestFiniteMagnitude"): emit(.pushDouble(Double.greatestFiniteMagnitude)); return .double
        case ("Color", _):
            use("view.Color")
            if ColorValue.Named(rawValue: name) != nil || name == "accentColor" {
                emit(.pushSymbol(name))
                return .symbol
            }
        case ("Font", _):
            if TextStyle(rawValue: name) != nil {
                emit(.pushSymbol(name))
                return .symbol
            }
        default:
            break
        }
        unsupportedAPI("\(typeName).\(name)", node, knownUnsupportedTypes.contains(typeName) ? unsupportedNameCapability(typeName) : "stdlib.\(typeName).\(name)")
        emit(.pushVoid)
        return .unknown
    }

    func compileImplicitMember(_ name: String, expected: SType?, node: Syntax) -> SType {
        let exp = expected?.unwrapped ?? .unknown
        if case .named(let tid, _) = exp {
            let t = types[tid]
            if t.caseIndex(name) != nil || t.staticField(name) != nil || t.computedProp(name)?.isStatic == true {
                return compileStaticMember(tid, name, node: node)
            }
            error(.nameResolution, "类型 '\(t.name)' 没有成员 '\(name)'。", node)
            emit(.pushVoid)
            return .unknown
        }
        if exp == .double {
            switch name {
            case "infinity": emit(.pushDouble(.infinity)); return .double
            case "pi": emit(.pushDouble(.pi)); return .double
            default: break
            }
        }
        if exp == .int && (name == "max" || name == "min") {
            emit(.pushInt(name == "max" ? Int.max : Int.min))
            return .int
        }
        if !exp.isKnown {
            // 目标类型未知：若恰好一个用户枚举有此 case，则解析到它
            let owners = types.filter { $0.kind == .enumType && $0.caseIndex(name) != nil }
            if owners.count == 1, let t = owners.first, let idx = t.caseIndex(name) {
                emit(.pushEnum(type: t.id, caseIndex: idx))
                return .named(t.id, t.name)
            }
        }
        emit(.pushSymbol(name))
        return .symbol
    }

    func builtinTypeName(_ t: SType) -> String? {
        switch t {
        case .array: return "Array"
        case .string: return "String"
        case .dict: return "Dictionary"
        case .range: return "Range"
        case .int: return "Int"
        case .double: return "Double"
        case .bool: return "Bool"
        default: return nil
        }
    }

    /// 基值已在栈上。
    func compileMemberOnValue(_ bt: SType, _ name: String, node: Syntax) -> SType {
        if bt.isOptional {
            error(.typeCheck, "可选类型 '\(bt)' 的值必须先解包才能访问成员 '\(name)'。", node,
                  suggestion: "使用 ?. 可选链、if let 或 !")
            emit(.getMember(name))
            return .unknown
        }
        switch bt {
        case .named(let tid, _):
            let t = types[tid]
            if let i = t.fields.firstIndex(where: { $0.name == name }) {
                let f = t.fields[i]
                checkMemberVisible(name, of: t, declFile: f.fileIndex, access: f.access, node)
                emit(.getField(i))
                return f.type
            }
            if let c = t.computedProp(name), !c.isStatic {
                checkMemberVisible(name, of: t, declFile: c.fileIndex, access: c.access, node)
                emit(.getComputed(function: c.functionID))
                return c.type
            }
            if name == "rawValue", let raw = t.rawType {
                use("syntax.enum.rawValue")
                emit(.getMember("rawValue"))
                return raw
            }
            if !t.methods(named: name).isEmpty {
                unsupported("方法引用（不调用的方法名）", node, "syntax.functionReference")
                emit(.pop)
                emit(.pushVoid)
                return .unknown
            }
            error(.nameResolution, "'\(t.name)' 没有成员 '\(name)'。", node)
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        case .tuple(let ts, let labels):
            if let i = labels.firstIndex(of: name) {
                emit(.tupleElement(i))
                return ts[i]
            }
            if let i = Int(name), i < ts.count {
                emit(.tupleElement(i))
                return ts[i]
            }
            error(.nameResolution, "元组没有成员 '\(name)'。", node)
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        case .array, .string, .dict, .range, .int, .double, .bool:
            if let mt = builtinMemberType(bt, name, program: types) {
                use("stdlib.\(builtinTypeName(bt)!).\(name)")
                emit(.getMember(name))
                return mt
            }
            unsupportedAPI("\(builtinTypeName(bt)!).\(name)", node, "stdlib.\(builtinTypeName(bt)!).\(name)")
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        case .view:
            unsupported("访问视图的成员 '\(name)'", node, "view.customView")
            emit(.pop)
            emit(.pushVoid)
            return .unknown
        default:
            emit(.getMember(name))
            return .unknown
        }
    }

    // MARK: - $ 投影

    func isProjectionRoot(_ e: ExprSyntax) -> Bool {
        var cur: ExprSyntax? = e
        while let c = cur {
            if let ref = c.as(DeclReferenceExprSyntax.self) {
                let n = ref.baseName.text
                return n.hasPrefix("$") && !isDollarShorthand(n)
            }
            if let m = c.as(MemberAccessExprSyntax.self) { cur = m.base } else if let s = c.as(SubscriptCallExprSyntax.self) {
                cur = s.calledExpression
            } else { return false }
        }
        return false
    }

    /// `$count`、`$model.name`、`$items[i]` → Binding。
    func compileProjection(_ e: ExprSyntax) -> SType {
        guard let p = resolvePlace(e, stripDollar: true) else {
            error(.nameResolution, "无法解析绑定 '\(e.trimmedDescription)'。", e)
            emit(.pushVoid)
            return .unknown
        }
        if !p.throughWrapper {
            error(.typeCheck, "'\(e.trimmedDescription)'：'$' 只能用于 @State 或 @Binding 属性（或它们的子路径）。", e)
        }
        use("propertyWrapper.Binding.projection")
        for (k, kt) in p.keyExprs { compileExpr(k, expected: kt) }
        emit(.place(addPlace(PlaceDesc(root: p.root, steps: p.steps)), .projectBinding))
        return .binding(p.type)
    }
}
