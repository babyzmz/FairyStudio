import RuntimeContracts
import SwiftSyntax

/// 支持（或可安全忽略语义）的协议遵循。
let supportedConformances: Set<String> = [
    "View", "App", "Identifiable", "Hashable", "Equatable", "CaseIterable", "CustomStringConvertible", "Sendable",
]

/// 受支持之外、但属于 SwiftUI 的属性包装器（给出精确 capabilityID）。
let knownPropertyWrappers: Set<String> = [
    "ObservedObject", "StateObject", "EnvironmentObject", "Environment", "AppStorage", "SceneStorage", "FocusState",
    "Namespace", "Published", "GestureState", "Query", "Bindable", "Observable",
]

extension Compiler {
    /// 该文件是否作为脚本文件（顶层语句按顺序执行）。
    func isScriptFile(_ f: Int) -> Bool { files.count == 1 || files[f].isMainSwift }

    func fileHasStatements(_ f: Int) -> Bool {
        files[f].tree.statements.contains { item in
            if case .decl = item.item { return false }
            return true
        }
    }

    // MARK: - 第一遍：收集全部顶层声明

    func buildIndex() {
        for f in files {
            let scriptVars = isScriptFile(f.index) && fileHasStatements(f.index)
            for item in f.tree.statements {
                switch item.item {
                case .decl(let d):
                    indexTopDecl(d, file: f.index, scriptVars: scriptVars, item: item)
                case .stmt, .expr:
                    topLevelItems.append((f.index, item))
                }
            }
        }
        // 第二遍：扩展（此时所有类型都已登记，扩展顺序不影响结果）
        for (file, ext) in extensions { indexExtension(ext, file: file) }
        checkTopLevelPlacement()
    }

    func checkTopLevelPlacement() {
        let mainTypes = types.filter(\.isMain)
        var scriptFiles = Set<Int>()
        for (f, item) in topLevelItems {
            if case .decl = item.item { continue }
            if !isScriptFile(f) {
                error(.typeCheck, "顶层语句只能出现在 main.swift 中（\(files[f].fileName) 不是脚本入口文件）。", item, file: f,
                      capability: "syntax.topLevelCode", suggestion: "把这些语句移到 main.swift，或放进函数/视图中。")
            } else {
                scriptFiles.insert(f)
            }
        }
        if mainTypes.count > 1 {
            for t in mainTypes.dropFirst() {
                error(.typeCheck, "存在多个 @main 入口（\(mainTypes.map(\.name).joined(separator: "、"))）。", t.node, file: t.fileIndex,
                      capability: "syntax.mainApp")
            }
        }
        if let m = mainTypes.first, !scriptFiles.isEmpty {
            error(.typeCheck, "@main 类型 '\(m.name)' 与 main.swift 顶层语句不能同时存在：程序只能有一个入口。", m.node, file: m.fileIndex,
                  capability: "syntax.mainApp")
        }
    }

    func checkGenericsAndEffects(_ node: some SyntaxProtocol, generic: GenericParameterClauseSyntax?, whereClause: GenericWhereClauseSyntax?,
                                 file: Int) -> Bool {
        if let generic {
            unsupported("泛型参数", generic, "syntax.generics", file: file)
            return false
        }
        if let whereClause {
            unsupported("泛型 where 子句", whereClause, "syntax.generics", file: file)
            return false
        }
        return true
    }

    func indexTopDecl(_ d: DeclSyntax, file: Int, scriptVars: Bool, item: CodeBlockItemSyntax) {
        if let imp = d.as(ImportDeclSyntax.self) {
            let module = imp.path.first?.name.text ?? ""
            use("syntax.import")
            if !["SwiftUI", "Foundation", "Swift"].contains(module) {
                error(.unsupportedAPI, "运行时尚不支持导入模块 '\(module)'（只支持 SwiftUI、Foundation 的受支持子集）。", imp, file: file,
                      capability: "syntax.import")
            }
        } else if let s = d.as(StructDeclSyntax.self) {
            indexType(name: s.name.text, kind: .structType, node: Syntax(s), attributes: s.attributes, modifiers: s.modifiers,
                      inheritance: s.inheritanceClause, generic: s.genericParameterClause, whereClause: s.genericWhereClause,
                      members: s.memberBlock, file: file)
        } else if let e = d.as(EnumDeclSyntax.self) {
            indexType(name: e.name.text, kind: .enumType, node: Syntax(e), attributes: e.attributes, modifiers: e.modifiers,
                      inheritance: e.inheritanceClause, generic: e.genericParameterClause, whereClause: e.genericWhereClause,
                      members: e.memberBlock, file: file)
        } else if let ext = d.as(ExtensionDeclSyntax.self) {
            extensions.append((file, ext))
        } else if let fn = d.as(FunctionDeclSyntax.self) {
            guard let decl = makeFuncDecl(fn, file: file, inType: nil) else { return }
            if let existing = funcs[decl.baseName]?.first(where: { $0.overloadKey == decl.overloadKey }) {
                error(.nameResolution, "函数 '\(decl.fullName)' 重复定义（另一处在 \(files[existing.fileIndex].fileName)）。", fn.name, file: file)
                return
            }
            funcs[decl.baseName, default: []].append(decl)
            use("syntax.function")
        } else if let v = d.as(VariableDeclSyntax.self) {
            indexGlobalVar(v, file: file, scriptVars: scriptVars)
            if scriptVars { topLevelItems.append((file, item)) }
        } else if let c = d.as(ClassDeclSyntax.self) {
            unsupported("class '\(c.name.text)'（类与继承）", c.classKeyword, "syntax.class", file: file)
        } else if let a = d.as(ActorDeclSyntax.self) {
            unsupported("actor '\(a.name.text)'", a.actorKeyword, "syntax.actor", file: file)
        } else if let p = d.as(ProtocolDeclSyntax.self) {
            unsupported("protocol '\(p.name.text)'（自定义协议）", p.protocolKeyword, "syntax.protocol", file: file)
        } else if let t = d.as(TypeAliasDeclSyntax.self) {
            unsupported("typealias", t.typealiasKeyword, "syntax.typealias", file: file)
        } else if d.is(OperatorDeclSyntax.self) || d.is(PrecedenceGroupDeclSyntax.self) {
            unsupported("自定义运算符", d, "syntax.operatorDecl", file: file)
        } else if d.is(MacroDeclSyntax.self) || d.is(MacroExpansionDeclSyntax.self) {
            unsupported("宏", d, "syntax.macro", file: file)
        } else if d.is(IfConfigDeclSyntax.self) {
            unsupported("条件编译 #if", d, "syntax.ifConfig", file: file)
        } else {
            unsupported("此类声明", d, "syntax.declaration", file: file)
        }
    }

    func indexType(name: String, kind: TypeDecl.Kind, node: Syntax, attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax,
                   inheritance: InheritanceClauseSyntax?, generic: GenericParameterClauseSyntax?, whereClause: GenericWhereClauseSyntax?,
                   members: MemberBlockSyntax, file: Int) {
        if let existing = typeByName[name] {
            error(.nameResolution, "类型 '\(name)' 重复定义（另一处在 \(files[types[existing].fileIndex].fileName)）。", node, file: file)
            return
        }
        if builtinTypeNames.contains(name) || knownUnsupportedTypes.contains(name) {
            error(.nameResolution, "类型名 '\(name)' 与标准库/SwiftUI 类型冲突，请换一个名字。", node, file: file)
            return
        }
        // 泛型类型整体不索引（避免把泛型参数误报为"找不到类型"）
        guard checkGenericsAndEffects(node, generic: generic, whereClause: whereClause, file: file) else { return }
        let t = TypeDecl(id: types.count, name: name, kind: kind, fileIndex: file, node: node, access: readAccess(modifiers).access)
        types.append(t)
        typeByName[name] = t.id
        use(kind == .structType ? "syntax.struct" : "syntax.enum")
        for attr in attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let an = a.attributeName.trimmedDescription
            if an == "main" { t.isMain = true; use("syntax.mainApp") } else if an == "Observable" {
                unsupported("宏 @Observable", a, "syntax.macro", file: file)
            } else {
                unsupported("类型上的属性 @\(an)", a, "syntax.attribute", file: file)
            }
        }
        if let inheritance { addConformances(t, inheritance, file: file, allowRawType: kind == .enumType) }
        indexMembers(members, into: t, file: file, isExtension: false)
    }

    func addConformances(_ t: TypeDecl, _ clause: InheritanceClauseSyntax, file: Int, allowRawType: Bool) {
        for (i, inh) in clause.inheritedTypes.enumerated() {
            let n = inh.type.trimmedDescription
            if allowRawType && i == 0 && ["Int", "String", "Double", "Character"].contains(n) {
                t.rawType = n == "Int" ? .int : (n == "Double" ? .double : .string)
                use("syntax.enum.rawValue")
                continue
            }
            if supportedConformances.contains(n) {
                t.conformances.append(n)
                if n == "CaseIterable" { use("syntax.enum.caseIterable") }
                if n == "View" { use("view.customView") }
            } else if typeByName[n] != nil {
                unsupported("继承 '\(n)'", inh, "syntax.class", file: file)
            } else {
                unsupported("遵循协议 '\(n)'", inh, "syntax.protocol", file: file)
            }
        }
    }

    func indexExtension(_ ext: ExtensionDeclSyntax, file: Int) {
        let name = ext.extendedType.trimmedDescription
        use("syntax.extension")
        guard let tid = typeByName[name] else {
            if builtinTypeNames.contains(name) || knownUnsupportedTypes.contains(name) {
                unsupported("扩展标准库/系统类型 '\(name)'", ext.extendedType, "syntax.extension.stdlibType", file: file)
            } else {
                error(.nameResolution, "找不到要扩展的类型 '\(name)'。", ext.extendedType, file: file)
            }
            return
        }
        if let w = ext.genericWhereClause { unsupported("带 where 子句的扩展", w, "syntax.generics", file: file) }
        let t = types[tid]
        if let inh = ext.inheritanceClause { addConformances(t, inh, file: file, allowRawType: false) }
        indexMembers(ext.memberBlock, into: t, file: file, isExtension: true)
    }

    // MARK: - 成员

    func indexMembers(_ block: MemberBlockSyntax, into t: TypeDecl, file: Int, isExtension: Bool) {
        for member in block.members {
            let d = member.decl
            if let v = d.as(VariableDeclSyntax.self) {
                indexMemberVar(v, into: t, file: file, isExtension: isExtension)
            } else if let fn = d.as(FunctionDeclSyntax.self) {
                guard let decl = makeFuncDecl(fn, file: file, inType: t) else { continue }
                if t.methods.contains(where: { $0.overloadKey == decl.overloadKey && $0.isStatic == decl.isStatic }) {
                    error(.nameResolution, "方法 '\(decl.fullName)' 在 '\(t.name)' 中重复定义。", fn.name, file: file)
                    continue
                }
                t.methods.append(decl)
                use("syntax.struct.method")
                if decl.isMutating { use("syntax.struct.mutating") }
                if decl.isStatic { use("syntax.struct.static") }
                if t.kind == .enumType { use("syntax.enum.methods") }
            } else if let ini = d.as(InitializerDeclSyntax.self) {
                if ini.optionalMark != nil {
                    unsupported("可失败构造器 init?", ini.initKeyword, "syntax.struct.failableInit", file: file)
                    continue
                }
                if ini.signature.effectSpecifiers != nil {
                    unsupported("async/throws 构造器", ini.signature, "syntax.errorHandling", file: file)
                    continue
                }
                if !checkGenericsAndEffects(ini, generic: ini.genericParameterClause, whereClause: ini.genericWhereClause, file: file) { continue }
                let decl = InitDecl(node: ini, fileIndex: file, access: readAccess(ini.modifiers).access)
                if decl.params.contains(where: { $0.isInout || $0.isVariadic }) {
                    unsupported("构造器的可变参数", ini.signature, "syntax.function.variadic", file: file)
                    continue
                }
                t.inits.append(decl)
                if !isExtension { t.hasInitInBody = true }
                use("syntax.struct.init")
            } else if let c = d.as(EnumCaseDeclSyntax.self) {
                guard t.kind == .enumType else { continue }
                for el in c.elements {
                    if t.caseIndex(el.name.text) != nil {
                        error(.nameResolution, "enum case '\(el.name.text)' 重复定义。", el, file: file)
                        continue
                    }
                    let info = EnumCaseInfo(name: el.name.text, rawValue: el.rawValue?.value, node: Syntax(el))
                    if let pc = el.parameterClause {
                        if t.rawType != nil {
                            error(.typeCheck, "enum '\(t.name)' 有原始值类型，case '\(el.name.text)' 不能再带关联值。", pc, file: file)
                            continue
                        }
                        if el.rawValue != nil {
                            error(.typeCheck, "带关联值的 case '\(el.name.text)' 不能同时有原始值。", el, file: file)
                            continue
                        }
                        if t.conformances.contains("CaseIterable") {
                            error(.typeCheck, "带关联值的 enum '\(t.name)' 不能遵循 CaseIterable（无法合成 allCases）。", el, file: file)
                        }
                        use("syntax.enum.associatedValues")
                        for p in pc.parameters {
                            let first = p.firstName?.text
                            info.associated.append((label: first == nil || first == "_" ? nil : first, type: p.type))
                        }
                        if info.associated.isEmpty {
                            error(.typeCheck, "case '\(el.name.text)' 的关联值至少需要一个参数。", pc, file: file)
                            continue
                        }
                    }
                    t.cases.append(info)
                }
            } else if d.is(StructDeclSyntax.self) || d.is(EnumDeclSyntax.self) || d.is(ClassDeclSyntax.self) {
                unsupported("嵌套类型", d, "syntax.nestedType", file: file)
            } else if d.is(SubscriptDeclSyntax.self) {
                unsupported("自定义下标 subscript", d, "syntax.subscriptDecl", file: file)
            } else if d.is(TypeAliasDeclSyntax.self) {
                unsupported("typealias", d, "syntax.typealias", file: file)
            } else if d.is(DeinitializerDeclSyntax.self) {
                unsupported("deinit", d, "syntax.class", file: file)
            } else if d.is(IfConfigDeclSyntax.self) {
                unsupported("条件编译 #if", d, "syntax.ifConfig", file: file)
            } else {
                unsupported("此类成员声明", d, "syntax.declaration", file: file)
            }
        }
    }

    func makeFuncDecl(_ fn: FunctionDeclSyntax, file: Int, inType: TypeDecl?) -> FuncDecl? {
        if case .binaryOperator = fn.name.tokenKind {
            unsupported("运算符函数 '\(fn.name.text)'", fn.name, "syntax.operatorDecl", file: file)
            return nil
        }
        if case .prefixOperator = fn.name.tokenKind {
            unsupported("运算符函数 '\(fn.name.text)'", fn.name, "syntax.operatorDecl", file: file)
            return nil
        }
        if !checkGenericsAndEffects(fn, generic: fn.genericParameterClause, whereClause: fn.genericWhereClause, file: file) { return nil }
        if let eff = fn.signature.effectSpecifiers {
            if eff.asyncSpecifier != nil {
                unsupported("async 函数", eff, "syntax.asyncAwait", file: file)
            } else {
                unsupported("throws 函数（错误处理）", eff, "syntax.errorHandling", file: file)
            }
            return nil
        }
        var isViewBuilder = false
        for attr in fn.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let an = a.attributeName.trimmedDescription
            switch an {
            case "ViewBuilder": isViewBuilder = true; use("view.ViewBuilder")
            case "discardableResult": break
            default: unsupported("函数上的属性 @\(an)", a, "syntax.attribute", file: file)
            }
        }
        let isStatic = hasModifier(fn.modifiers, .static)
        let isMutating = hasModifier(fn.modifiers, .mutating)
        if inType == nil && (isStatic || isMutating) {
            error(.typeCheck, "顶层函数不能是 static 或 mutating。", fn.name, file: file)
        }
        let decl = FuncDecl(node: fn, fileIndex: file, access: readAccess(fn.modifiers).access, isStatic: isStatic,
                            isMutating: isMutating, isViewBuilder: isViewBuilder)
        if decl.params.contains(where: \.isVariadic) {
            unsupported("可变参数（...）", fn.signature, "syntax.function.variadic", file: file)
            return nil
        }
        for p in decl.params where p.isInout && p.defaultValue != nil {
            error(.typeCheck, "inout 参数 '\(p.name)' 不能有默认值。", fn.signature, file: file)
        }
        if fn.body == nil {
            error(.typeCheck, "函数 '\(fn.name.text)' 缺少函数体。", fn.name, file: file)
            return nil
        }
        return decl
    }

    func indexGlobalVar(_ v: VariableDeclSyntax, file: Int, scriptVars: Bool) {
        for attr in v.attributes {
            if let a = attr.as(AttributeSyntax.self) {
                unsupported("全局变量上的属性 @\(a.attributeName.trimmedDescription)", a, "syntax.attribute", file: file)
            }
        }
        let isLet = v.bindingSpecifier.tokenKind == .keyword(.let)
        use(isLet ? "syntax.let" : "syntax.var")
        for binding in v.bindings {
            if let tp = binding.pattern.as(TuplePatternSyntax.self) {
                // 顶层解构声明：每个元素登记为独立全局变量，脚本体按顺序求值并存入（见 compileTopLevelVar）。
                // 非脚本文件（分散的全局变量）暂不支持。
                if !scriptVars {
                    unsupported("元组模式 / 解构声明", binding.pattern, "syntax.tuplePattern", file: file)
                    continue
                }
                use("syntax.tuplePattern")
                var annoElems: [SType]?
                if let ta = binding.typeAnnotation {
                    let at = resolveType(ta.type, file: file, selfType: nil)
                    if case .tuple(let ts, _) = at, ts.count == tp.elements.count { annoElems = ts }
                    else { error(.typeCheck, "解构声明的类型标注应为 \(tp.elements.count) 元组，得到 '\(at)'。", ta, file: file) }
                }
                if binding.initializer == nil {
                    error(.typeCheck, "解构声明需要初始值。", binding.pattern, file: file)
                }
                for (i, el) in tp.elements.enumerated() {
                    guard let id = el.pattern.as(IdentifierPatternSyntax.self) else {
                        if !el.pattern.is(WildcardPatternSyntax.self) {
                            unsupported("嵌套元组模式", el.pattern, "syntax.tuplePattern", file: file)
                        }
                        continue
                    }
                    let name = id.identifier.text
                    if globalByName[name] != nil {
                        error(.nameResolution, "全局变量 '\(name)' 重复定义。", id, file: file)
                        continue
                    }
                    let g = GlobalDecl(name: name, typeSyntax: nil, initializer: nil, isLet: isLet, fileIndex: file,
                                       node: Syntax(id), access: readAccess(v.modifiers).access,
                                       isMainTopLevel: true, ownerType: nil)
                    if let ae = annoElems?[i] { g.type = ae }
                    g.globalID = globals.count
                    globals.append(g)
                    globalByName[name] = g.globalID
                }
                continue
            }
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                unsupported("元组模式 / 解构声明", binding.pattern, "syntax.tuplePattern", file: file)
                // 仍登记其中的名字，避免后续引用被误报为"找不到"
                for name in patternNames(binding.pattern) where globalByName[name] == nil {
                    let g = GlobalDecl(name: name, typeSyntax: nil, initializer: nil, isLet: isLet, fileIndex: file,
                                       node: Syntax(binding.pattern), access: .internal, isMainTopLevel: true, ownerType: nil)
                    g.globalID = globals.count
                    globals.append(g)
                    globalByName[name] = g.globalID
                }
                continue
            }
            let name = ident.identifier.text
            if let acc = binding.accessorBlock {
                // 全局存储变量的 didSet（`var x = 0 { didSet { … } }`）；其余访问器不支持
                var didSetBody: CodeBlockItemListSyntax?
                var didSetParam: String?
                var badGlobalAccessor = false
                var willSetSeen = false
                switch acc.accessors {
                case .getter:
                    badGlobalAccessor = true
                case .accessors(let list):
                    for a in list {
                        switch a.accessorSpecifier.tokenKind {
                        case .keyword(.didSet):
                            didSetBody = a.body?.statements
                            didSetParam = a.parameters?.name.text
                            use("syntax.struct.propertyObservers")
                        case .keyword(.willSet):
                            willSetSeen = true
                            warning("willSet 观察器暂不支持（已忽略）；didSet 可用。", a, file: file)
                        default:
                            badGlobalAccessor = true
                        }
                    }
                }
                if badGlobalAccessor || (didSetBody == nil && !willSetSeen) {
                    unsupported("全局计算变量", binding, "syntax.globalComputed", file: file)
                    continue
                }
                if didSetBody == nil {
                    // 只有 willSet（已警告忽略）：跳过本块，按普通全局变量继续登记
                } else {
                    if isLet {
                        error(.typeCheck, "let 常量 '\(name)' 不能有 didSet 观察器。", ident, file: file)
                        continue
                    }
                    if let g = globalByName[name] {
                        error(.nameResolution, "全局变量 '\(name)' 重复定义（另一处在 \(files[globals[g].fileIndex].fileName)）。", ident, file: file)
                        continue
                    }
                    let g = GlobalDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                                       isLet: isLet, fileIndex: file, node: Syntax(ident), access: readAccess(v.modifiers).access,
                                       isMainTopLevel: scriptVars, ownerType: nil)
                    g.didSetBody = didSetBody
                    g.didSetParam = didSetParam
                    g.globalID = globals.count
                    globals.append(g)
                    globalByName[name] = g.globalID
                    continue
                }
            }
            if let g = globalByName[name] {
                error(.nameResolution, "全局变量 '\(name)' 重复定义（另一处在 \(files[globals[g].fileIndex].fileName)）。", ident, file: file)
                continue
            }
            if binding.initializer == nil && binding.typeAnnotation == nil {
                error(.typeCheck, "变量 '\(name)' 需要类型标注或初始值。", ident, file: file)
            }
            if !scriptVars && binding.initializer == nil {
                error(.typeCheck, "全局变量 '\(name)' 必须有初始值。", ident, file: file)
            }
            let g = GlobalDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                               isLet: isLet, fileIndex: file, node: Syntax(ident), access: readAccess(v.modifiers).access,
                               isMainTopLevel: scriptVars, ownerType: nil)
            g.globalID = globals.count
            globals.append(g)
            globalByName[name] = g.globalID
        }
    }

    /// 模式中出现的标识符（用于不支持的解构声明的错误恢复）。
    func patternNames(_ p: PatternSyntax) -> [String] {
        if let i = p.as(IdentifierPatternSyntax.self) { return [i.identifier.text] }
        if let t = p.as(TuplePatternSyntax.self) { return t.elements.flatMap { patternNames($0.pattern) } }
        if let v = p.as(ValueBindingPatternSyntax.self) { return patternNames(v.pattern) }
        return []
    }

    func indexMemberVar(_ v: VariableDeclSyntax, into t: TypeDecl, file: Int, isExtension: Bool) {
        var wrapper = PropertyWrapperKind.none
        var isViewBuilder = false
        for attr in v.attributes {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let an = a.attributeName.trimmedDescription
            switch an {
            case "State":
                wrapper = .state
                use("propertyWrapper.State")
            case "Binding":
                wrapper = .binding
                use("propertyWrapper.Binding")
            case "ViewBuilder":
                isViewBuilder = true
            default:
                if knownPropertyWrappers.contains(an) {
                    unsupported("属性包装器 @\(an)", a, "propertyWrapper.\(an)", file: file)
                } else {
                    unsupported("属性 @\(an)（自定义属性包装器或宏）", a, "syntax.attribute", file: file)
                }
                return
            }
        }
        if hasModifier(v.modifiers, .lazy) {
            unsupported("lazy 属性", v, "syntax.struct.lazy", file: file)
            return
        }
        let isStatic = hasModifier(v.modifiers, .static)
        let isLet = v.bindingSpecifier.tokenKind == .keyword(.let)
        let access = readAccess(v.modifiers)
        if wrapper != .none && (t.kind != .structType || !t.isView && !t.isApp) {
            if !t.isView {
                warning("@\(wrapper == .state ? "State" : "Binding") 只在 View 中有意义。", v, file: file)
            }
        }
        for binding in v.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                unsupported("元组模式 / 解构声明", binding.pattern, "syntax.tuplePattern", file: file)
                continue
            }
            let name = ident.identifier.text
            if let acc = binding.accessorBlock {
                // 收集访问器：get / set / willSet / didSet
                var getterBody: CodeBlockItemListSyntax?
                var setterBody: CodeBlockItemListSyntax?
                var setterParam = "newValue"
                var didSetBody: CodeBlockItemListSyntax?
                var didSetParam: String?
                var badAccessor = false
                switch acc.accessors {
                case .getter(let items): getterBody = items
                case .accessors(let list):
                    for a in list {
                        switch a.accessorSpecifier.tokenKind {
                        case .keyword(.get):
                            if getterBody != nil {
                                error(.typeCheck, "重复的 get 访问器。", a, file: file)
                                badAccessor = true
                            }
                            getterBody = a.body?.statements
                        case .keyword(.set):
                            if setterBody != nil {
                                error(.typeCheck, "重复的 set 访问器。", a, file: file)
                                badAccessor = true
                            }
                            setterBody = a.body?.statements
                            if let pn = a.parameters?.name { setterParam = pn.text }
                            use("syntax.struct.computedSetter")
                        case .keyword(.willSet):
                            warning("willSet 观察器暂不支持（已忽略）；didSet 可用。", a, file: file)
                        case .keyword(.didSet):
                            if didSetBody != nil {
                                error(.typeCheck, "重复的 didSet 观察器。", a, file: file)
                                badAccessor = true
                            }
                            didSetBody = a.body?.statements
                            didSetParam = a.parameters?.name.text
                            use("syntax.struct.propertyObservers")
                        default:
                            unsupported("访问器 \(a.accessorSpecifier.text)", a, "syntax.declaration", file: file)
                            badAccessor = true
                        }
                    }
                }
                if badAccessor { continue }
                if t.isApp && name == "body" && !isStatic, let gb = getterBody {
                    t.sceneBody = gb
                    continue
                }
                if setterBody != nil {
                    // get/set 计算属性
                    if didSetBody != nil {
                        error(.typeCheck, "计算属性 '\(name)' 不能同时有 set 与 didSet。", ident, file: file)
                        continue
                    }
                    guard let getterBody else {
                        error(.typeCheck, "计算属性 '\(name)' 有 set 但缺少 get。", ident, file: file)
                        continue
                    }
                    if isStatic {
                        error(.unsupportedSyntax, "运行时尚不支持静态计算属性的 setter。", ident, file: file,
                              capability: "syntax.struct.computedSetter")
                        continue
                    }
                    guard binding.typeAnnotation != nil else {
                        error(.typeCheck, "计算属性 '\(name)' 需要类型标注。", ident, file: file)
                        continue
                    }
                    if t.computedProp(name) != nil || t.field(name) != nil {
                        error(.nameResolution, "属性 '\(name)' 在 '\(t.name)' 中重复定义。", ident, file: file)
                        continue
                    }
                    let isBody = t.isView && name == "body"
                    let decl = ComputedDecl(name: name, typeSyntax: binding.typeAnnotation?.type, body: getterBody, isStatic: isStatic,
                                            access: access.access, fileIndex: file, node: Syntax(ident),
                                            isViewBuilder: isViewBuilder || isBody)
                    decl.setterBody = setterBody
                    decl.setterParam = setterParam
                    t.computed.append(decl)
                    use("syntax.struct.computedProperty")
                    continue
                }
                if didSetBody != nil {
                    // didSet 存储属性（读按存储属性，写后触发观察器）
                    if isLet {
                        error(.typeCheck, "let 常量 '\(name)' 不能有 didSet 观察器。", ident, file: file)
                        continue
                    }
                    if isExtension {
                        error(.typeCheck, "扩展中不能声明存储属性 '\(name)'。", ident, file: file)
                        continue
                    }
                    if t.kind == .enumType {
                        error(.typeCheck, "enum 不能包含存储属性 '\(name)'。", ident, file: file)
                        continue
                    }
                    if t.field(name) != nil || t.computedProp(name) != nil {
                        error(.nameResolution, "属性 '\(name)' 在 '\(t.name)' 中重复定义。", ident, file: file)
                        continue
                    }
                    if isStatic {
                        if binding.initializer == nil {
                            error(.typeCheck, "静态存储属性 '\(name)' 必须有初始值。", ident, file: file)
                            continue
                        }
                        if wrapper != .none {
                            error(.typeCheck, "静态属性 '\(name)' 不能使用属性包装器。", ident, file: file)
                            continue
                        }
                        let g = GlobalDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                                           isLet: isLet, fileIndex: file, node: Syntax(ident), access: access.access,
                                           isMainTopLevel: false, ownerType: t.id)
                        g.didSetBody = didSetBody
                        g.didSetParam = didSetParam
                        g.globalID = globals.count
                        globals.append(g)
                        t.statics.append(g)
                        use("syntax.struct.static")
                        continue
                    }
                    if wrapper != .none {
                        error(.typeCheck, "@\(wrapper == .state ? "State" : "Binding") 属性 '\(name)' 不能有 didSet 观察器。", ident, file: file)
                        continue
                    }
                    let f = StoredFieldDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                                            isLet: isLet, wrapper: wrapper, access: access.access,
                                            setterAccess: access.setter ?? access.access, fileIndex: file, node: Syntax(ident))
                    f.didSetBody = didSetBody
                    f.didSetParam = didSetParam
                    t.fields.append(f)
                    continue
                }
                if let body = getterBody {
                    if t.isApp && name == "body" && !isStatic {
                        t.sceneBody = body
                        continue
                    }
                    guard binding.typeAnnotation != nil else {
                        error(.typeCheck, "计算属性 '\(name)' 需要类型标注。", ident, file: file)
                        continue
                    }
                    if t.computedProp(name) != nil || t.field(name) != nil {
                        error(.nameResolution, "属性 '\(name)' 在 '\(t.name)' 中重复定义。", ident, file: file)
                        continue
                    }
                    let isBody = t.isView && name == "body"
                    t.computed.append(ComputedDecl(name: name, typeSyntax: binding.typeAnnotation?.type, body: body, isStatic: isStatic,
                                                   access: access.access, fileIndex: file, node: Syntax(ident),
                                                   isViewBuilder: isViewBuilder || isBody))
                    use("syntax.struct.computedProperty")
                    continue
                }
                // 只有 willSet（已警告忽略）：按普通存储属性处理
            }
            if isStatic {
                if binding.initializer == nil {
                    error(.typeCheck, "静态存储属性 '\(name)' 必须有初始值。", ident, file: file)
                    continue
                }
                let g = GlobalDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                                   isLet: isLet, fileIndex: file, node: Syntax(ident), access: access.access,
                                   isMainTopLevel: false, ownerType: t.id)
                g.globalID = globals.count
                globals.append(g)
                t.statics.append(g)
                use("syntax.struct.static")
                continue
            }
            if isExtension {
                error(.typeCheck, "扩展中不能声明存储属性 '\(name)'。", ident, file: file)
                continue
            }
            if t.kind == .enumType {
                error(.typeCheck, "enum 不能包含存储属性 '\(name)'。", ident, file: file)
                continue
            }
            if t.field(name) != nil || t.computedProp(name) != nil {
                error(.nameResolution, "属性 '\(name)' 在 '\(t.name)' 中重复定义。", ident, file: file)
                continue
            }
            if binding.typeAnnotation == nil && binding.initializer == nil {
                error(.typeCheck, "存储属性 '\(name)' 需要类型标注或初始值。", ident, file: file)
                continue
            }
            if wrapper == .binding && binding.initializer != nil {
                error(.typeCheck, "@Binding 属性 '\(name)' 不能有初始值。", ident, file: file)
            }
            t.fields.append(StoredFieldDecl(name: name, typeSyntax: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                                            isLet: isLet, wrapper: wrapper, access: access.access,
                                            setterAccess: access.setter ?? access.access, fileIndex: file, node: Syntax(ident)))
        }
    }
}
