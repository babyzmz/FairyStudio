import RuntimeContracts

/// 左值（place）操作：赋值、复合赋值、mutating 调用、`$` 投影。
///
/// 规则：在持有某个存储位置的 inout 访问期间，绝不回调 VM（否则会违反 Swift 独占访问）。
/// 需要回调闭包的 mutating 操作（sort(by:)、removeAll(where:)）以及用户 mutating 方法，
/// 采用"取出 → 执行 → 写回"，与 Swift 的独占访问语义一致。
enum PlaceOps {
    static func modify<R>(_ program: IRProgram, _ v: inout Value, _ steps: ArraySlice<ConcreteStep>,
                          _ body: (inout Value) throws -> R) throws -> R {
        switch v {
        case .box(let b):
            return try modify(program, &b.value, steps, body)
        case .stateCell(let c):
            let r = try modify(program, &c.value, steps, body)
            c.markDirty()
            return r
        case .binding(let bv):
            var cur = try bv.get()
            let r = try modify(program, &cur, steps, body)
            try bv.set(cur)
            return r
        default:
            break
        }
        guard let step = steps.first else { return try body(&v) }
        let rest = steps.dropFirst()
        switch step {
        case .field(let i):
            guard case .record(var rec) = v, i < rec.fields.count else {
                throw VMError.typeMismatch("对 '\(ValueOps.typeName(v))' 的属性赋值失败。")
            }
            v = .void
            defer { v = .record(rec) }
            return try modify(program, &rec.fields[i], rest, body)
        case .member(let name):
            switch v {
            case .record(var rec):
                let info = program.types[rec.type]
                guard let i = info.fieldIndex[name] else {
                    if info.computed[name] != nil {
                        throw VMError.unsupported("给计算属性 '\(name)' 赋值（计算属性 setter）", capabilityID: "syntax.struct.computedSetter")
                    }
                    throw VMError.typeMismatch("'\(info.name)' 没有可赋值的属性 '\(name)'。")
                }
                v = .void
                defer { v = .record(rec) }
                return try modify(program, &rec.fields[i], rest, body)
            case .tuple(var t):
                guard let i = t.labels.firstIndex(of: name) else { throw VMError.typeMismatch("元组没有标签 '\(name)'。") }
                v = .void
                defer { v = .tuple(t) }
                return try modify(program, &t.elements[i], rest, body)
            default:
                throw VMError.typeMismatch("'\(ValueOps.typeName(v))' 没有可赋值的属性 '\(name)'。")
            }
        case .tupleIndex(let i):
            guard case .tuple(var t) = v, i < t.elements.count else { throw VMError.typeMismatch("元组下标越界。") }
            v = .void
            defer { v = .tuple(t) }
            return try modify(program, &t.elements[i], rest, body)
        case .key(let keys, let label):
            switch v {
            case .array(var a):
                guard keys.count == 1, case .int(let i) = keys[0] else {
                    throw VMError.typeMismatch("数组下标必须是 Int。")
                }
                guard i >= 0 && i < a.count else {
                    throw VMError.trap("数组下标越界：索引 \(i)，数组长度 \(a.count)（Swift: Index out of range）")
                }
                v = .void
                defer { v = .array(a) }
                return try modify(program, &a[i], rest, body)
            case .dict(var d):
                guard let key = keys.first else { throw VMError.typeMismatch("字典下标缺少键。") }
                let h = try hashKey(key)
                var cur: Value
                if label == "default", keys.count == 2 {
                    cur = d.get(h) ?? keys[1]
                } else {
                    cur = d.get(h) ?? .none
                    if cur.isNil && !rest.isEmpty {
                        throw VMError.trap("字典中不存在键 \(key)，无法通过它修改（强制解包 nil）")
                    }
                }
                v = .void
                defer { v = .dict(d) }
                let r = try modify(program, &cur, rest, body)
                if cur.isNil { d.remove(h) } else { d.set(key, hash: h, cur) }
                return r
            default:
                throw VMError.typeMismatch("'\(ValueOps.typeName(v))' 不支持下标赋值。")
            }
        case .unwrap:
            if v.isNil {
                throw VMError.trap("强制解包遇到 nil（Swift: Unexpectedly found nil while unwrapping an Optional value）")
            }
            return try modify(program, &v, rest, body)
        case .optionalChain:
            if v.isNil { throw OptionalChainNil() }
            return try modify(program, &v, rest, body)
        }
    }

    /// 只读地沿路径取值（每一步自动解引用）。
    static func read(_ program: IRProgram, _ v: Value, _ steps: ArraySlice<ConcreteStep>) throws -> Value {
        var cur = try deref(v)
        for step in steps {
            switch step {
            case .field(let i):
                guard case .record(let r) = cur, i < r.fields.count else { throw VMError.typeMismatch("属性访问失败。") }
                cur = try deref(r.fields[i])
            case .member(let name):
                switch cur {
                case .record(let r):
                    guard let i = program.types[r.type].fieldIndex[name] else {
                        throw VMError.typeMismatch("'\(program.types[r.type].name)' 没有存储属性 '\(name)'。")
                    }
                    cur = try deref(r.fields[i])
                case .tuple(let t):
                    guard let i = t.labels.firstIndex(of: name) else { throw VMError.typeMismatch("元组没有标签 '\(name)'。") }
                    cur = t.elements[i]
                default:
                    throw VMError.typeMismatch("'\(ValueOps.typeName(cur))' 没有属性 '\(name)'。")
                }
            case .tupleIndex(let i):
                guard case .tuple(let t) = cur, i < t.elements.count else { throw VMError.typeMismatch("元组下标越界。") }
                cur = t.elements[i]
            case .key(let keys, let label):
                switch cur {
                case .array(let a):
                    guard keys.count == 1, case .int(let i) = keys[0] else { throw VMError.typeMismatch("数组下标必须是 Int。") }
                    guard i >= 0 && i < a.count else {
                        throw VMError.trap("数组下标越界：索引 \(i)，数组长度 \(a.count)（Swift: Index out of range）")
                    }
                    cur = a[i]
                case .dict(let d):
                    guard let key = keys.first else { throw VMError.typeMismatch("字典下标缺少键。") }
                    if label == "default", keys.count == 2 { cur = d.get(try hashKey(key)) ?? keys[1] } else {
                        cur = d.get(try hashKey(key)) ?? .none
                    }
                default:
                    throw VMError.typeMismatch("'\(ValueOps.typeName(cur))' 不支持下标。")
                }
            case .unwrap:
                if cur.isNil {
                    throw VMError.trap("强制解包遇到 nil（Swift: Unexpectedly found nil while unwrapping an Optional value）")
                }
            case .optionalChain:
                if cur.isNil { throw OptionalChainNil() }
            }
            cur = try deref(cur)
        }
        return cur
    }
}

extension BindingValue {
    func get() throws -> Value {
        try PlaceOps.read(cell.program, cell.value, path[...])
    }
    func set(_ newValue: Value) throws {
        try PlaceOps.modify(cell.program, &cell.value, path[...]) { $0 = newValue }
        cell.markDirty()
    }
}

extension VM {
    func concreteSteps(_ steps: [PlaceStep], keys: [Value]) -> [ConcreteStep] {
        var out: [ConcreteStep] = []
        out.reserveCapacity(steps.count)
        var k = 0
        for s in steps {
            switch s {
            case .field(let i): out.append(.field(i))
            case .member(let n): out.append(.member(n))
            case .tupleIndex(let i): out.append(.tupleIndex(i))
            case .unwrap: out.append(.unwrap)
            case .optionalChain: out.append(.optionalChain)
            case .subscriptKey(let argc, let label):
                out.append(.key(Array(keys[k..<(k + argc)]), label: label))
                k += argc
            }
        }
        return out
    }

    func modifyRoot<R>(_ root: PlaceRoot, frameIndex fi: Int, _ steps: [ConcreteStep], _ body: (inout Value) throws -> R) throws -> R {
        switch root {
        case .local(let s):
            let idx = frames[fi].base + s
            return try PlaceOps.modify(program, &stack[idx], steps[...], body)
        case .capture(let i):
            guard let c = frames[fi].closure else { throw VMError.internalError("非闭包帧访问捕获") }
            return try PlaceOps.modify(program, &c.captures[i], steps[...], body)
        case .global(let g):
            try ensureGlobal(g)
            return try PlaceOps.modify(program, &globals[g], steps[...], body)
        }
    }

    func rawRoot(_ root: PlaceRoot, frameIndex fi: Int) throws -> Value {
        switch root {
        case .local(let s): return stack[frames[fi].base + s]
        case .capture(let i):
            guard let c = frames[fi].closure else { throw VMError.internalError("非闭包帧访问捕获") }
            return c.captures[i]
        case .global(let g):
            try ensureGlobal(g)
            return globals[g]
        }
    }

    func readRoot(_ root: PlaceRoot, frameIndex fi: Int, _ steps: [ConcreteStep]) throws -> Value {
        try PlaceOps.read(program, try rawRoot(root, frameIndex: fi), steps[...])
    }

    func writePlace(root: PlaceRoot, steps: [ConcreteStep], frameIndex fi: Int, value: Value) throws {
        try modifyRoot(root, frameIndex: fi, steps) { $0 = value }
    }

    /// 取出左值当前值并在原位置留下 void（mutating 调用期间的独占访问）。
    func takeRoot(_ root: PlaceRoot, frameIndex fi: Int, _ steps: [ConcreteStep]) throws -> Value {
        try modifyRoot(root, frameIndex: fi, steps) { v -> Value in
            let old = v
            v = .void
            return old
        }
    }

    /// 生成 `$x` 绑定：沿路径找到第一个状态单元或绑定，剩余路径成为绑定路径。
    func makeBinding(_ root: PlaceRoot, frameIndex fi: Int, _ steps: [ConcreteStep]) throws -> Value {
        var current = try rawRoot(root, frameIndex: fi)
        var remaining = steps[...]
        while true {
            switch current {
            case .stateCell(let c): return .binding(BindingValue(cell: c, path: Array(remaining)))
            case .binding(let b): return .binding(BindingValue(cell: b.cell, path: b.path + Array(remaining)))
            case .box(let b): current = b.value; continue
            default: break
            }
            guard let step = remaining.first else {
                throw VMError.typeMismatch("'$' 只能用于 @State 或 @Binding 属性（或其子路径）。")
            }
            remaining = remaining.dropFirst()
            switch (step, current) {
            case (.field(let i), .record(let r)) where i < r.fields.count:
                current = r.fields[i]
            case (.member(let n), .record(let r)):
                guard let i = program.types[r.type].fieldIndex[n] else { throw VMError.typeMismatch("没有属性 '\(n)'。") }
                current = r.fields[i]
            default:
                throw VMError.typeMismatch("'$' 只能用于 @State 或 @Binding 属性（或其子路径）。")
            }
        }
    }

    /// 执行左值指令。返回 true 表示压入了新帧（调用了用户方法）。
    /// 路径中含可选链且遇到 nil 时，整个操作跳过（有结果的操作压入 nil）。
    func execPlace(_ desc: PlaceDesc, op: PlaceOp, frameIndex fi: Int) throws -> Bool {
        let stackMark = stack.count
        do {
            return try execPlaceInner(desc, op: op, frameIndex: fi)
        } catch is OptionalChainNil {
            let consumed: Int
            switch op {
            case .assign, .compound: consumed = 1
            case .callMutating(_, let argc), .callMethod(_, let argc): consumed = argc
            case .load, .projectBinding: consumed = 0
            }
            // 操作数与键已弹出；恢复到弹出后的高度
            let target = stackMark - consumed - desc.keyCount
            if stack.count > target { stack.removeLast(stack.count - target) }
            switch op {
            case .assign, .compound: break
            default: push(.none)
            }
            return false
        }
    }

    private func execPlaceInner(_ desc: PlaceDesc, op: PlaceOp, frameIndex fi: Int) throws -> Bool {
        var operands: [Value] = []
        switch op {
        case .assign, .compound: operands = [pop()]
        case .callMutating(_, let argc), .callMethod(_, let argc): operands = popN(argc)
        case .load, .projectBinding: break
        }
        let keys = popN(desc.keyCount)
        let steps = concreteSteps(desc.steps, keys: keys)
        switch op {
        case .assign:
            let v = operands[0]
            try modifyRoot(desc.root, frameIndex: fi, steps) { $0 = v }
            return false
        case .compound(let bop, let lit):
            let rhs = operands[0]
            let meter = self.meter
            try modifyRoot(desc.root, frameIndex: fi, steps) { v in
                let r = try ValueOps.binary(bop, v, rhs, literal: lit)
                if case .string(let s) = r { try meter.checkString(s) }
                if case .array(let a) = r { try meter.checkCollection(a.count) }
                v = r
            }
            return false
        case .load:
            push(try readRoot(desc.root, frameIndex: fi, steps))
            return false
        case .projectBinding:
            push(try makeBinding(desc.root, frameIndex: fi, steps))
            return false
        case .callMutating(let f, _):
            let selfValue = try takeRoot(desc.root, frameIndex: fi, steps)
            push(selfValue)
            stack.append(contentsOf: operands)
            try pushFrame(program.functions[f], argc: operands.count + 1, closure: nil, dropBelow: 0,
                          onReturn: .writeBack(desc.root, steps))
            return true
        case .callMethod(let name, _):
            let recv = try readRoot(desc.root, frameIndex: fi, steps)
            var typeID: Int?
            switch recv {
            case .record(let r): typeID = r.type
            case .enumCase(let t, _): typeID = t
            default: break
            }
            if let t = typeID, let m = program.types[t].methods[name], !m.isStatic {
                if m.isMutating {
                    let selfValue = try takeRoot(desc.root, frameIndex: fi, steps)
                    push(selfValue)
                    stack.append(contentsOf: operands)
                    try pushFrame(program.functions[m.function], argc: operands.count + 1, closure: nil, dropBelow: 0,
                                  onReturn: .writeBack(desc.root, steps))
                } else {
                    push(recv)
                    stack.append(contentsOf: operands)
                    try pushFrame(program.functions[m.function], argc: operands.count + 1, closure: nil, dropBelow: 0, onReturn: .push)
                }
                return true
            }
            if Stdlib.isMutatingMethod(name, receiver: recv) {
                if Stdlib.mutatingNeedsCallback(name) {
                    var value = try takeRoot(desc.root, frameIndex: fi, steps)
                    let r: Value
                    do {
                        r = try Stdlib.callMutating(self, &value, name, operands)
                    } catch {
                        try? writePlace(root: desc.root, steps: steps, frameIndex: fi, value: value)
                        throw error
                    }
                    try writePlace(root: desc.root, steps: steps, frameIndex: fi, value: value)
                    push(r)
                } else {
                    let meter = self.meter
                    let r = try modifyRoot(desc.root, frameIndex: fi, steps) { v in
                        try Stdlib.callMutating(nil, &v, name, operands, meter: meter)
                    }
                    push(r)
                }
                return false
            }
            push(try Stdlib.callMethod(self, recv, name, operands))
            return false
        }
    }
}
