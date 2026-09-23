import RuntimeContracts
import SwiftSyntax

extension Compiler {
    /// 编译闭包字面量。捕获分析：闭包体中引用的外层变量登记为捕获；var 按引用（装箱）捕获，let 按值捕获。
    func compileClosure(_ c: ClosureExprSyntax, expected: SType?, builder: Bool) -> SType {
        use("syntax.closure")
        var names: [String] = []
        var declared: [SType?] = []
        var explicitRet: SType?
        if let sig = c.signature {
            if let cap = sig.capture { unsupported("闭包捕获列表 [..]", cap, "syntax.closure.captureList") }
            if sig.effectSpecifiers != nil { unsupported("async/throws 闭包", sig, "syntax.asyncAwait") }
            if let attrs = sig.attributes.first { unsupported("闭包属性", attrs, "syntax.attribute") }
            switch sig.parameterClause {
            case .simpleInput(let list):
                for p in list {
                    names.append(p.name.text)
                    declared.append(nil)
                }
            case .parameterClause(let pc):
                for p in pc.parameters {
                    names.append((p.secondName ?? p.firstName).text)
                    declared.append(p.type.map { resolveType($0, file: fb.fileIndex, selfType: currentSelfTypeID) })
                }
            case nil:
                break
            }
            if let r = sig.returnClause { explicitRet = resolveType(r.type, file: fb.fileIndex, selfType: currentSelfTypeID) }
        } else {
            let n = maxDollarIndex(c) + 1
            if n > 0 { use("syntax.closure.shorthandArgs") }
            names = (0..<n).map { "$\($0)" }
            declared = Array(repeating: nil, count: n)
        }
        var expParams: [SType] = []
        var expRet: SType?
        if case .function(let ps, let r)? = expected {
            expParams = ps
            expRet = r.isKnown ? r : nil
        }
        // 字典元素 (key, value) 元组 → 双参数闭包
        if names.count == 2, expParams.count == 1, case .tuple(let ts, _) = expParams[0], ts.count == 2 { expParams = ts }
        // 宽松：无参数声明的闭包在上下文需要参数时补齐隐藏参数（Swift 会报错；这里不影响语义）
        if names.isEmpty && c.signature == nil && !expParams.isEmpty {
            names = expParams.indices.map { "$\($0)" }
            declared = Array(repeating: nil, count: names.count)
        }
        let paramTypes: [SType] = names.indices.map { i in declared[i] ?? (i < expParams.count ? expParams[i] : .unknown) }
        var retType: SType = explicitRet ?? expRet ?? (builder ? .view : .unknown)
        let id = allocFunction()
        var caps: [CaptureSource] = []
        let parent = fb
        withFunction(id: id, name: "闭包@\(files[fb.fileIndex].fileName):\(range(c)?.start.line ?? 0)", file: fb.fileIndex, parent: parent) { b in
            for (i, n) in names.enumerated() { _ = declareLocal(n, isLet: true, type: paramTypes[i]) }
            b.paramCount = names.count
            b.paramCoercions = paramTypes.map { coercion(for: $0) }
            b.returnType = retType
            if builder {
                b.isBuilder = true
                compileBuilderBlock(c.statements)
                emit(.ret)
                retType = .view
            } else if let single = singleExpression(c.statements) {
                let exp: SType? = retType.isKnown && retType != .void ? retType : nil
                let t = compileExpr(single, expected: exp)
                if let exp { checkAssignable(exp, t, single) }
                if !retType.isKnown { retType = t }
                emit(.ret)
            } else {
                compileStatements(c.statements)
                emit(.pushVoid)
                emit(.ret)
                if !retType.isKnown { retType = inferredClosureReturn[id] ?? .void }
            }
            caps = b.captures
        }
        if caps.contains(where: { if case .local(_, true) = $0 { return true }; return false }) {
            use("syntax.closure.captureByReference")
        }
        emit(.makeClosure(function: id, captures: caps))
        return .function(paramTypes, retType)
    }

    func singleExpression(_ items: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard items.count == 1, let first = items.first, case .expr(let e) = first.item, !isStatementLike(e) else { return nil }
        return e
    }

    /// 闭包体中（不含嵌套闭包）出现的最大 $N。
    func maxDollarIndex(_ c: ClosureExprSyntax) -> Int {
        var maxIndex = -1
        for tok in c.statements.tokens(viewMode: .sourceAccurate) {
            guard case .dollarIdentifier(let text) = tok.tokenKind, let n = Int(text.dropFirst()) else { continue }
            var node: Syntax? = tok.parent
            var owner: ClosureExprSyntax?
            while let cur = node {
                if let cl = cur.as(ClosureExprSyntax.self) { owner = cl; break }
                node = cur.parent
            }
            if owner?.id == c.id { maxIndex = max(maxIndex, n) }
        }
        return maxIndex
    }
}
