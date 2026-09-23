import RuntimeContracts

/// 解释器运行期值。
///
/// - 数组/字典/结构体/元组借助 Swift 自身的写时复制实现值语义。
/// - Optional 采用"扁平表示"：`nil` 为 `.none`，非 nil 的可选值就是被包装的值本身；
///   打印时依据静态类型补上 `Optional(…)`（见 Describe.swift）。
/// - `.box` / `.stateCell` / `.binding` 是引用单元，读取局部变量、字段时自动解引用，不会出现在普通表达式结果中。
enum Value {
    case void
    case none
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case dict(DictValue)
    case range(RangeValue)
    case tuple(TupleValue)
    case record(RecordValue)
    case enumCase(type: Int, index: Int)
    case closure(ClosureObject)
    case function(Int)
    case metatype(Int)
    case view(ViewNode)
    case box(Box)
    case stateCell(StateCell)
    case binding(BindingValue)
    case symbol(String)
    case keyPath([String])
    case iterator(IteratorBox)

    var isNil: Bool { if case .none = self { return true }; return false }
}

struct RangeValue: Hashable {
    var lower: Int
    var upper: Int
    var closed: Bool
    /// 半开区间形式的上界（closed 时 +1；溢出由构造处检查）。
    var endExclusive: Int { closed ? upper &+ 1 : upper }
    var count: Int {
        let (d, o) = endExclusive.subtractingReportingOverflow(lower)
        return o ? Int.max : Swift.max(0, d)
    }
}

struct TupleValue {
    var elements: [Value]
    var labels: [String?]
}

struct RecordValue {
    let type: Int
    var fields: [Value]
}

/// 被闭包按引用捕获的 var 所在的箱子。
final class Box {
    var value: Value
    init(_ value: Value) { self.value = value }
}

final class ClosureObject {
    let function: IRFunction
    var captures: [Value]
    init(function: IRFunction, captures: [Value]) { self.function = function; self.captures = captures }
}

/// 可哈希的键表示（字典键、ForEach 稳定 id、switch 比较）。
indirect enum HashKey: Hashable {
    case none
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case enumCase(Int, Int)
    case tuple([HashKey])
    case array([HashKey])
    case record(Int, [HashKey])
    case symbol(String)
}

/// 保持插入顺序的字典（Swift 原生 Dictionary 的遍历顺序本身不确定；我们选择确定的插入顺序）。
struct DictValue {
    final class Storage {
        var keys: [Value] = []
        var values: [Value] = []
        var index: [HashKey: Int] = [:]
        func copy() -> Storage {
            let s = Storage(); s.keys = keys; s.values = values; s.index = index; return s
        }
    }
    private(set) var storage = Storage()

    init() {}

    var count: Int { storage.keys.count }
    var keys: [Value] { storage.keys }
    var values: [Value] { storage.values }

    func get(_ key: HashKey) -> Value? {
        guard let i = storage.index[key] else { return nil }
        return storage.values[i]
    }

    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
    }

    mutating func set(_ key: Value, hash: HashKey, _ value: Value) {
        makeUnique()
        if let i = storage.index[hash] {
            storage.values[i] = value
        } else {
            storage.index[hash] = storage.keys.count
            storage.keys.append(key)
            storage.values.append(value)
        }
    }

    @discardableResult
    mutating func remove(_ hash: HashKey) -> Value? {
        guard let i = storage.index[hash] else { return nil }
        makeUnique()
        let old = storage.values[i]
        storage.keys.remove(at: i)
        storage.values.remove(at: i)
        storage.index[hash] = nil
        for j in i..<storage.keys.count {
            if let k = try? hashKey(storage.keys[j]) { storage.index[k] = j }
        }
        return old
    }

    mutating func removeAll() { storage = Storage() }
}

/// 可变迭代器状态（存放在隐藏局部槽位中）。
final class IteratorBox {
    enum Source {
        case array([Value])
        case range(lower: Int, endExclusive: Int)
        case stride(from: Double, to: Double, by: Double, inclusive: Bool, isInt: Bool)
        case dict(keys: [Value], values: [Value])
    }
    let source: Source
    var index: Int = 0
    init(_ source: Source) { self.source = source }

    func next() -> Value? {
        switch source {
        case .array(let a):
            guard index < a.count else { return nil }
            defer { index += 1 }
            return a[index]
        case .range(let lo, let hi):
            let v = lo &+ index
            guard v < hi, index >= 0 else { return nil }
            index += 1
            return .int(v)
        case .stride(let from, let to, let by, let inclusive, let isInt):
            let v = from + Double(index) * by
            let ok: Bool
            if by > 0 { ok = inclusive ? v <= to : v < to } else if by < 0 { ok = inclusive ? v >= to : v > to } else { ok = false }
            guard ok else { return nil }
            index += 1
            return isInt ? .int(Int(v)) : .double(v)
        case .dict(let keys, let values):
            guard index < keys.count else { return nil }
            defer { index += 1 }
            return .tuple(TupleValue(elements: [keys[index], values[index]], labels: ["key", "value"]))
        }
    }
}

/// 路径的具体一步（下标键已求值）。用于左值修改与 Binding。
enum ConcreteStep {
    case field(Int)
    case member(String)
    case tupleIndex(Int)
    case key([Value], label: String?)
    case unwrap
    case optionalChain
}

/// 可选链左值遇到 nil：整个赋值/调用跳过。
struct OptionalChainNil: Error {}

/// `$state` / `$binding.x` 产生的绑定：指向某个状态单元内的路径。
final class BindingValue {
    let cell: StateCell
    let path: [ConcreteStep]
    init(cell: StateCell, path: [ConcreteStep]) { self.cell = cell; self.path = path }
}

func hashKey(_ v: Value) throws -> HashKey {
    switch v {
    case .none: return .none
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .enumCase(let t, let i): return .enumCase(t, i)
    case .symbol(let s): return .symbol(s)
    case .tuple(let t): return .tuple(try t.elements.map { try hashKey($0) })
    case .array(let a): return .array(try a.map { try hashKey($0) })
    case .record(let r): return .record(r.type, try r.fields.map { try hashKey(try deref($0)) })
    case .box(let b): return try hashKey(b.value)
    case .stateCell(let c): return try hashKey(c.value)
    default: throw VMError.typeMismatch("该值不能作为字典键或 id（需要 Hashable）")
    }
}

/// 自动解引用引用单元（箱、状态单元、绑定）。绑定读取可能越界等，因此会抛出。
@inline(__always)
func deref(_ v: Value) throws -> Value {
    switch v {
    case .box(let b): return try deref(b.value)
    case .stateCell(let c): return c.value
    case .binding(let b): return try b.get()
    default: return v
    }
}
