import Foundation
import RuntimeContracts

/// 受支持的标准库子集（运行期实现）。编译期签名见 BuiltinSignatures.swift；二者与 capability catalog 保持一致。
enum Stdlib {
    // MARK: - 成员（属性）

    static func member(_ vm: VM, _ v: Value, _ name: String) throws -> Value {
        switch v {
        case .array(let a):
            switch name {
            case "count": return .int(a.count)
            case "isEmpty": return .bool(a.isEmpty)
            case "first": return a.first ?? .none
            case "last": return a.last ?? .none
            case "indices": return .range(RangeValue(lower: 0, upper: a.count, closed: false))
            case "startIndex": return .int(0)
            case "endIndex": return .int(a.count)
            default: break
            }
        case .string(let s):
            switch name {
            case "count": return .int(s.count)
            case "isEmpty": return .bool(s.isEmpty)
            case "first": return s.first.map { .string(String($0)) } ?? .none
            case "last": return s.last.map { .string(String($0)) } ?? .none
            case "description": return .string(s)
            default: break
            }
        case .dict(let d):
            switch name {
            case "count": return .int(d.count)
            case "isEmpty": return .bool(d.count == 0)
            case "keys": return .array(d.keys)
            case "values": return .array(d.values)
            default: break
            }
        case .range(let r):
            switch name {
            case "count": return .int(r.count)
            case "isEmpty": return .bool(r.count == 0)
            case "lowerBound": return .int(r.lower)
            case "upperBound": return .int(r.upper)
            case "first": return r.count > 0 ? .int(r.lower) : .none
            case "last": return r.count > 0 ? .int(r.endExclusive - 1) : .none
            default: break
            }
        case .int(let i):
            switch name {
            case "description": return .string(String(i))
            case "magnitude": return .int(Int(bitPattern: i.magnitude))
            default: break
            }
        case .double(let d):
            switch name {
            case "description": return .string(d.description)
            case "isNaN": return .bool(d.isNaN)
            case "isInfinite": return .bool(d.isInfinite)
            case "isFinite": return .bool(d.isFinite)
            default: break
            }
        case .bool(let b):
            if name == "description" { return .string(b ? "true" : "false") }
        case .tuple(let t):
            if let i = t.labels.firstIndex(of: name) { return t.elements[i] }
            if let i = Int(name), i < t.elements.count { return t.elements[i] }
        case .record(let r):
            let info = vm.program.types[r.type]
            if let i = info.fieldIndex[name] { return try deref(r.fields[i]) }
        case .enumCase(let t, let i):
            let info = vm.program.types[t]
            if name == "rawValue", let raws = info.rawValues {
                switch raws[i] {
                case .int(let x): return .int(x)
                case .string(let s): return .string(s)
                case .double(let d): return .double(d)
                }
            }
        case .metatype(let t):
            let info = vm.program.types[t]
            if name == "allCases", info.kind == .enumType {
                return .array((0..<info.caseNames.count).map { .enumCase(type: t, index: $0) })
            }
        default:
            break
        }
        throw VMError.typeMismatch("'\(ValueOps.typeName(v))' 没有成员 '\(name)'（或运行时尚不支持）。")
    }

    // MARK: - 下标

    static func subscriptGet(_ vm: VM, _ recv: Value, _ keys: [Value], label: String?) throws -> Value {
        switch recv {
        case .array(let a):
            guard keys.count == 1 else { break }
            switch keys[0] {
            case .int(let i):
                guard i >= 0 && i < a.count else {
                    throw VMError.trap("数组下标越界：索引 \(i)，数组长度 \(a.count)（Swift: Index out of range）")
                }
                return a[i]
            case .range(let r):
                guard r.lower >= 0 && r.endExclusive <= a.count else {
                    throw VMError.trap("数组区间下标越界：\(r.lower)..<\(r.endExclusive)，数组长度 \(a.count)（Swift: Array index is out of range）")
                }
                return .array(Array(a[r.lower..<r.endExclusive]))
            default: break
            }
        case .dict(let d):
            guard let k = keys.first else { break }
            let h = try hashKey(k)
            if label == "default", keys.count == 2 { return d.get(h) ?? keys[1] }
            return d.get(h) ?? .none
        case .string:
            throw VMError.unsupported("String 下标（String.Index）", capabilityID: "stdlib.String.subscript")
        default:
            break
        }
        throw VMError.typeMismatch("'\(ValueOps.typeName(recv))' 不支持这种下标。")
    }

    // MARK: - mutating 方法

    static let arrayMutating: Set<String> = [
        "append(_:)", "append(contentsOf:)", "insert(_:at:)", "remove(at:)", "removeLast()", "removeFirst()",
        "removeAll()", "removeAll(where:)", "popLast()", "sort()", "sort(by:)", "reverse()", "swapAt(_:_:)",
    ]
    static let stringMutating: Set<String> = ["append(_:)", "append(contentsOf:)", "removeAll()", "removeLast()", "removeFirst()"]
    static let dictMutating: Set<String> = ["removeValue(forKey:)", "updateValue(_:forKey:)", "removeAll()"]
    static let allMutatingNames: Set<String> = arrayMutating.union(stringMutating).union(dictMutating).union(["toggle()"])

    static func isMutatingMethod(_ name: String, receiver: Value) -> Bool {
        switch receiver {
        case .array: return arrayMutating.contains(name)
        case .string: return stringMutating.contains(name)
        case .dict: return dictMutating.contains(name)
        case .bool: return name == "toggle()"
        default: return false
        }
    }

    static func mutatingNeedsCallback(_ name: String) -> Bool { name == "sort(by:)" || name == "removeAll(where:)" }

    /// 执行 mutating 内建方法。vm 为 nil 时不得回调闭包（原地修改路径）。
    static func callMutating(_ vm: VM?, _ v: inout Value, _ name: String, _ args: [Value], meter: BudgetMeter? = nil) throws -> Value {
        let meter = meter ?? vm?.meter
        switch v {
        case .array(var a):
            v = .void
            defer { v = .array(a) }
            switch name {
            case "append(_:)":
                a.append(args[0])
                try meter?.checkCollection(a.count)
                return .void
            case "append(contentsOf:)":
                switch args[0] {
                case .array(let b): a.append(contentsOf: b)
                case .range(let r): a.append(contentsOf: (r.lower..<r.endExclusive).map { .int($0) })
                default: throw VMError.typeMismatch("append(contentsOf:) 需要数组。")
                }
                try meter?.checkCollection(a.count)
                return .void
            case "insert(_:at:)":
                guard case .int(let i) = args[1] else { throw VMError.typeMismatch("insert(_:at:) 的位置必须是 Int。") }
                guard i >= 0 && i <= a.count else {
                    throw VMError.trap("insert(_:at:) 位置越界：\(i)，数组长度 \(a.count)（Swift: Array index is out of range）")
                }
                a.insert(args[0], at: i)
                try meter?.checkCollection(a.count)
                return .void
            case "remove(at:)":
                guard case .int(let i) = args[0] else { throw VMError.typeMismatch("remove(at:) 的位置必须是 Int。") }
                guard i >= 0 && i < a.count else {
                    throw VMError.trap("remove(at:) 下标越界：索引 \(i)，数组长度 \(a.count)（Swift: Index out of range）")
                }
                return a.remove(at: i)
            case "removeLast()":
                guard !a.isEmpty else { throw VMError.trap("对空数组调用 removeLast()（Swift: Can't remove last element from an empty collection）") }
                return a.removeLast()
            case "removeFirst()":
                guard !a.isEmpty else { throw VMError.trap("对空数组调用 removeFirst()（Swift: Can't remove first element from an empty collection）") }
                return a.removeFirst()
            case "popLast()":
                return a.popLast() ?? .none
            case "removeAll()":
                a.removeAll()
                return .void
            case "removeAll(where:)":
                guard let vm else { throw VMError.internalError("removeAll(where:) 需要回调") }
                var kept: [Value] = []
                for e in a where !(try ValueOps.truthy(try callElement(vm, args[0], e))) { kept.append(e) }
                a = kept
                return .void
            case "sort()":
                a = try sortValues(a, by: nil, vm: vm)
                return .void
            case "sort(by:)":
                a = try sortValues(a, by: args[0], vm: vm)
                return .void
            case "reverse()":
                a.reverse()
                return .void
            case "swapAt(_:_:)":
                guard case .int(let i) = args[0], case .int(let j) = args[1] else { throw VMError.typeMismatch("swapAt 需要 Int。") }
                guard i >= 0, i < a.count, j >= 0, j < a.count else {
                    throw VMError.trap("swapAt 下标越界（Swift: Index out of range）")
                }
                a.swapAt(i, j)
                return .void
            default: break
            }
        case .string(var s):
            v = .void
            defer { v = .string(s) }
            switch name {
            case "append(_:)", "append(contentsOf:)":
                guard case .string(let t) = args[0] else { throw VMError.typeMismatch("String.append 需要 String。") }
                s += t
                try meter?.checkString(s)
                return .void
            case "removeAll()":
                s = ""
                return .void
            case "removeLast()":
                guard !s.isEmpty else { throw VMError.trap("对空字符串调用 removeLast()（Swift: Can't remove last element from an empty collection）") }
                return .string(String(s.removeLast()))
            case "removeFirst()":
                guard !s.isEmpty else { throw VMError.trap("对空字符串调用 removeFirst()（Swift: Can't remove first element from an empty collection）") }
                return .string(String(s.removeFirst()))
            default: break
            }
        case .dict(var d):
            v = .void
            defer { v = .dict(d) }
            switch name {
            case "removeValue(forKey:)":
                return d.remove(try hashKey(args[0])) ?? .none
            case "updateValue(_:forKey:)":
                let h = try hashKey(args[1])
                let old = d.get(h) ?? .none
                d.set(args[1], hash: h, args[0])
                try meter?.checkCollection(d.count)
                return old
            case "removeAll()":
                d.removeAll()
                return .void
            default: break
            }
        case .bool(let b):
            if name == "toggle()" { v = .bool(!b); return .void }
        default:
            break
        }
        throw VMError.typeMismatch("'\(ValueOps.typeName(v))' 没有 mutating 方法 '\(name)'。")
    }

    // MARK: - 回调辅助

    /// 以元素调用闭包；双参数闭包接收二元组元素时自动解构（`dict.map { k, v in … }`）。
    static func callElement(_ vm: VM, _ fn: Value, _ elem: Value) throws -> Value {
        if case .tuple(let t) = elem, t.elements.count == 2, paramCount(vm, fn) == 2 {
            return try vm.invoke(fn, t.elements)
        }
        return try vm.invoke(fn, [elem])
    }

    static func paramCount(_ vm: VM, _ fn: Value) -> Int {
        switch fn {
        case .closure(let c): return c.function.paramCount
        case .function(let f): return vm.program.functions[f].paramCount
        default: return -1
        }
    }

    static func sortValues(_ a: [Value], by fn: Value?, vm: VM?) throws -> [Value] {
        var failure: Error?
        let sorted = a.sorted { x, y in
            if failure != nil { return false }
            do {
                if let fn {
                    guard let vm else { throw VMError.internalError("排序需要回调") }
                    return try ValueOps.truthy(try vm.invoke(fn, [x, y]))
                }
                return try ValueOps.less(x, y)
            } catch {
                failure = error
                return false
            }
        }
        if let failure { throw failure }
        return sorted
    }

    /// 把可遍历值转为元素数组（Range/String/Dictionary 物化为数组，受集合预算约束）。
    static func elements(_ vm: VM, _ v: Value) throws -> [Value]? {
        switch v {
        case .array(let a): return a
        case .range(let r):
            try vm.meter.checkCollection(r.count)
            return (r.lower..<r.endExclusive).map { .int($0) }
        case .string(let s): return s.map { .string(String($0)) }
        case .dict(let d):
            return d.keys.indices.map { .tuple(TupleValue(elements: [d.keys[$0], d.values[$0]], labels: ["key", "value"])) }
        default: return nil
        }
    }
}
