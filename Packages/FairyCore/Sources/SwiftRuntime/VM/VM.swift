import Foundation
import RuntimeContracts

/// 帧返回时的动作。
enum ReturnAction {
    case push
    /// 返回给宿主（invoke），结束当前嵌套执行。
    case host
    /// mutating 方法：把被调用者槽位 0（self）写回调用者的左值。
    case writeBack(PlaceRoot, [ConcreteStep])
    /// 惰性全局初始化完成。
    case initGlobal(Int)
}

struct Frame {
    let function: IRFunction
    var pc: Int
    let base: Int
    let closure: ClosureObject?
    let onReturn: ReturnAction
    /// 返回时额外移除 base 之下的值个数（callValue 的被调用者）。
    let dropBelow: Int
}

enum ExecOutcome {
    case returned(Value)
    case yielded
}

/// 栈式解释器。只在所属运行实例的执行线程上使用（非 Sendable）。
///
/// 预算检查点：
/// - 指令循环：每 1024 条指令检查取消、步数、时间片与近似堆；
/// - 循环回边（`loop`）与函数调用：检查取消、步数；调用还检查 maxCallDepth；
/// - 大集合操作：追加/拼接/创建时检查 maxCollectionElements 与 maxStringLength。
final class VM {
    let program: IRProgram
    let meter: BudgetMeter
    var stack: [Value] = []
    var frames: [Frame] = []
    var globals: [Value]
    private var globalState: [UInt8]   // 0 未初始化，1 初始化中，2 就绪
    var hostDepth = 0
    let maxHostDepth = 160
    lazy var describer: Describer = Describer(program: program, custom: { [unowned self] v in self.customDescription(v) })
    /// print 输出。
    var console: (ConsoleStream, String) -> Void = { _, _ in }
    private var checkCounter = 0

    init(program: IRProgram, meter: BudgetMeter) {
        self.program = program
        self.meter = meter
        self.globals = Array(repeating: .void, count: program.globals.count)
        self.globalState = Array(repeating: 0, count: program.globals.count)
        stack.reserveCapacity(1024)
    }

    /// 遵循 CustomStringConvertible 且定义了 description 计算属性的用户类型。
    func customDescription(_ v: Value) -> String? {
        let t: Int
        switch v {
        case .record(let r): t = r.type
        case .enumCase(let tt, _): t = tt
        default: return nil
        }
        let info = program.types[t]
        guard info.conformances.contains("CustomStringConvertible"), let g = info.computed["description"] else { return nil }
        if case .string(let s)? = try? invokeFunction(g, [v]) { return s }
        return nil
    }

    /// 发生错误后重置执行状态（全局与状态存储保持不变）。
    func resetExecutionState() {
        stack.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        hostDepth = 0
    }

    // MARK: - 宿主调用入口

    /// 同步调用一个可调用值（闭包 / 函数引用），返回其结果。可重入（stdlib 高阶函数、视图求值使用）。
    func invoke(_ callee: Value, _ args: [Value]) throws -> Value {
        hostDepth += 1
        defer { hostDepth -= 1 }
        if hostDepth > maxHostDepth {
            throw VMError.budget(.hostReentry, "闭包回调嵌套过深（>\(maxHostDepth) 层）。")
        }
        let depth = frames.count
        let stackMark = stack.count
        do {
            switch callee {
            case .closure(let c):
                stack.append(contentsOf: args)
                try pushFrame(c.function, argc: args.count, closure: c, dropBelow: 0, onReturn: .host)
            case .function(let fid):
                stack.append(contentsOf: args)
                try pushFrame(program.functions[fid], argc: args.count, closure: nil, dropBelow: 0, onReturn: .host)
            default:
                throw VMError.typeMismatch("'\(ValueOps.typeName(callee))' 不是可调用的函数或闭包。")
            }
            switch try execute(stopDepth: depth, allowYield: false) {
            case .returned(let v): return v
            case .yielded: throw VMError.internalError("嵌套执行不应让出")
            }
        } catch {
            // 错误向上传播；恢复栈高度以便外层（若捕获）继续保持一致。
            if frames.count > depth { frames.removeLast(frames.count - depth) }
            if stack.count > stackMark { stack.removeLast(stack.count - stackMark) }
            throw error
        }
    }

    /// 调用函数 id（self 需放在 args[0]）。
    func invokeFunction(_ fid: Int, _ args: [Value]) throws -> Value {
        try invoke(.function(fid), args)
    }

    /// 开始执行脚本主体（可让出的顶层执行）。
    func startTopLevel(function fid: Int) throws {
        resetExecutionState()
        try pushFrame(program.functions[fid], argc: 0, closure: nil, dropBelow: 0, onReturn: .host)
    }

    /// 继续顶层执行；时间片用完时返回 .yielded。
    func resumeTopLevel() throws -> ExecOutcome {
        try execute(stopDepth: 0, allowYield: true)
    }

    // MARK: - 帧

    func pushFrame(_ fn: IRFunction, argc: Int, closure: ClosureObject?, dropBelow: Int, onReturn: ReturnAction) throws {
        if argc != fn.paramCount {
            throw VMError.typeMismatch("调用 \(fn.name) 的参数个数不匹配：需要 \(fn.paramCount)，实际 \(argc)。")
        }
        if frames.count >= meter.budget.maxCallDepth {
            throw VMError.budget(.callDepth, "调用深度超过预算（maxCallDepth = \(meter.budget.maxCallDepth)），可能是无限递归。")
        }
        try meter.checkCancel()
        let base = stack.count - argc
        if !fn.paramCoercions.isEmpty {
            for i in 0..<min(argc, fn.paramCoercions.count) where fn.paramCoercions[i] == .intToDouble {
                if case .int(let x) = stack[base + i] { stack[base + i] = .double(Double(x)) }
            }
        }
        let extra = fn.localCount - argc
        if extra > 0 { stack.append(contentsOf: repeatElement(Value.void, count: extra)) }
        frames.append(Frame(function: fn, pc: 0, base: base, closure: closure, onReturn: onReturn, dropBelow: dropBelow))
    }

    // MARK: - 全局

    func loadGlobal(_ g: Int) throws -> Value {
        switch globalState[g] {
        case 2: return try deref(globals[g])
        case 1: throw VMError.trap("全局变量 '\(program.globals[g].name)' 在自身初始化过程中被访问（循环初始化）。")
        default:
            guard let initFn = program.globals[g].initFunction else {
                throw VMError.trap("全局变量 '\(program.globals[g].name)' 在初始化之前被使用。")
            }
            globalState[g] = 1
            let v = try invokeFunction(initFn, [])
            globals[g] = v
            globalState[g] = 2
            return v
        }
    }

    func storeGlobal(_ g: Int, _ v: Value) {
        globals[g] = v
        globalState[g] = 2
    }

    func ensureGlobal(_ g: Int) throws {
        if globalState[g] != 2 { _ = try loadGlobal(g) }
    }

    // MARK: - 预算

    @inline(__always)
    private func periodicCheck(allowYield: Bool) throws -> Bool {
        try meter.checkCancel()
        try meter.checkSteps()
        checkCounter &+= 1
        if checkCounter & 63 == 0 { try checkHeap() }
        if checkCounter & 7 == 0 {
            // 嵌套深度探测：极深的嵌套值（如 a = [a] 循环）在释放/比较/打印时会耗尽宿主栈，提前以预算错误终止。
            for v in stack where NestingProbe.exceeds(v) { throw NestingProbe.error }
            for v in globals where NestingProbe.exceeds(v) { throw NestingProbe.error }
        }
        if meter.sliceExpired() {
            if meter.sliceMode == .yield {
                return allowYield && hostDepth == 0
            }
            throw VMError.budget(.wallClock, "单次执行片段超过墙钟预算（sliceWallClock = \(meter.budget.sliceWallClock)）。")
        }
        return false
    }

    /// 近似堆扫描：遍历栈、全局与捕获（对大集合抽样外推），估计活跃字节数。
    func checkHeap() throws {
        var estimator = HeapEstimator(limit: meter.budget.maxHeapBytesApprox)
        for v in stack { estimator.add(v) }
        for v in globals { estimator.add(v) }
        for f in frames { if let c = f.closure { for v in c.captures { estimator.add(v) } } }
        meter.lastHeapEstimate = estimator.total
        if estimator.total > meter.budget.maxHeapBytesApprox {
            throw VMError.budget(.heap, "近似堆占用超过预算（约 \(estimator.total) 字节 > maxHeapBytesApprox = \(meter.budget.maxHeapBytesApprox)）。")
        }
    }

    // MARK: - 指令循环

    @inline(__always) func pop() -> Value { stack.removeLast() }
    @inline(__always) func push(_ v: Value) { stack.append(v) }
    func popN(_ n: Int) -> [Value] {
        if n == 0 { return [] }
        let r = Array(stack[(stack.count - n)...])
        stack.removeLast(n)
        return r
    }

    /// 执行直到帧数回落到 stopDepth（由 onReturn == .host 的帧返回）。
    func execute(stopDepth: Int, allowYield: Bool) throws -> ExecOutcome {
        var fi = frames.count - 1
        var fn = frames[fi].function
        var pc = frames[fi].pc
        var base = frames[fi].base
        do {
            while true {
                let instr = fn.code[pc]
                pc += 1
                meter.steps &+= 1
                if meter.steps & 1023 == 0 {
                    if try periodicCheck(allowYield: allowYield) && allowYield {
                        // 当前指令已取出但尚未执行：恢复时从它重新开始
                        frames[fi].pc = pc - 1
                        meter.restartSlice()
                        return .yielded
                    }
                }
                switch instr {
                case .pushInt(let i): stack.append(.int(i))
                case .pushDouble(let d): stack.append(.double(d))
                case .pushBool(let b): stack.append(.bool(b))
                case .pushString(let s): stack.append(.string(s))
                case .pushNil: stack.append(.none)
                case .pushVoid: stack.append(.void)
                case .pushSymbol(let s): stack.append(.symbol(s))
                case .pushKeyPath(let p): stack.append(.keyPath(p))
                case .pushFunction(let f): stack.append(.function(f))
                case .pushMetatype(let t): stack.append(.metatype(t))
                case .pushEnum(let t, let i): stack.append(.enumCase(type: t, index: i))
                case .pop: stack.removeLast()
                case .dup: stack.append(stack[stack.count - 1])
                case .swap: stack.swapAt(stack.count - 1, stack.count - 2)

                case .loadLocal(let s):
                    let v = stack[base + s]
                    switch v {
                    case .box, .stateCell, .binding: stack.append(try deref(v))
                    default: stack.append(v)
                    }
                case .initLocal(let s):
                    stack[base + s] = stack.removeLast()
                case .storeLocal(let s):
                    let v = stack.removeLast()
                    switch stack[base + s] {
                    case .box(let b): b.value = v
                    case .binding(let bv): try bv.set(v)
                    case .stateCell(let c): c.value = v; c.markDirty()
                    default: stack[base + s] = v
                    }
                case .loadCapture(let i):
                    guard let c = frames[fi].closure else { throw VMError.internalError("非闭包帧访问捕获") }
                    stack.append(try deref(c.captures[i]))
                case .storeCapture(let i):
                    guard let c = frames[fi].closure else { throw VMError.internalError("非闭包帧访问捕获") }
                    let v = stack.removeLast()
                    switch c.captures[i] {
                    case .box(let b): b.value = v
                    case .binding(let bv): try bv.set(v)
                    case .stateCell(let cell): cell.value = v; cell.markDirty()
                    default: c.captures[i] = v
                    }
                case .loadGlobal(let g):
                    frames[fi].pc = pc
                    stack.append(try loadGlobal(g))
                case .storeGlobal(let g):
                    let v = stack.removeLast()
                    if case .box(let b) = globals[g] { b.value = v } else { storeGlobal(g, v) }

                case .getField(let i):
                    let r = stack.removeLast()
                    guard case .record(let rec) = r, i < rec.fields.count else {
                        throw VMError.typeMismatch("访问存储属性失败：接收者是 '\(ValueOps.typeName(r))'。")
                    }
                    stack.append(try deref(rec.fields[i]))
                case .getMember(let name):
                    let r = stack.removeLast()
                    if let getter = computedGetter(r, name) {
                        stack.append(r)
                        frames[fi].pc = pc
                        try pushFrame(program.functions[getter], argc: 1, closure: nil, dropBelow: 0, onReturn: .push)
                        fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                    } else {
                        frames[fi].pc = pc
                        stack.append(try Stdlib.member(self, r, name))
                    }
                case .getComputed(let getter):
                    frames[fi].pc = pc
                    try pushFrame(program.functions[getter], argc: 1, closure: nil, dropBelow: 0, onReturn: .push)
                    fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                case .tupleElement(let i):
                    let t = stack.removeLast()
                    guard case .tuple(let tv) = t, i < tv.elements.count else {
                        throw VMError.typeMismatch("元组元素访问失败。")
                    }
                    stack.append(tv.elements[i])
                case .destructure(let n):
                    let t = stack.removeLast()
                    guard case .tuple(let tv) = t, tv.elements.count == n else {
                        throw VMError.typeMismatch("无法把 '\(ValueOps.typeName(t))' 解构为 \(n) 元组。")
                    }
                    stack.append(contentsOf: tv.elements)
                case .subscriptGet(let argc, let label):
                    let keys = popN(argc)
                    let recv = stack.removeLast()
                    frames[fi].pc = pc
                    stack.append(try Stdlib.subscriptGet(self, recv, keys, label: label))

                case .place(let idx, let op):
                    frames[fi].pc = pc
                    let pushed = try execPlace(fn.places[idx], op: op, frameIndex: fi)
                    if pushed {
                        fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                    }

                case .binary(let op, let lit):
                    let b = stack.removeLast()
                    let a = stack.removeLast()
                    let r = try ValueOps.binary(op, a, b, literal: lit)
                    switch r {
                    case .string(let s) where op == .add: try meter.checkString(s)
                    case .array(let arr) where op == .add: try meter.checkCollection(arr.count)
                    default: break
                    }
                    stack.append(r)
                case .unary(let op):
                    stack.append(try ValueOps.unary(op, stack.removeLast()))
                case .forceUnwrap:
                    if case .none = stack[stack.count - 1] {
                        throw VMError.trap("强制解包遇到 nil（Swift: Unexpectedly found nil while unwrapping an Optional value）")
                    }
                case .toDouble:
                    if case .int(let x) = stack[stack.count - 1] { stack[stack.count - 1] = .double(Double(x)) }
                case .describe(let t):
                    let v = stack.removeLast()
                    if case .string(let s) = v, t == .string || t == .unknown {
                        stack.append(.string(s))
                    } else {
                        stack.append(.string(describer.describe(v, type: t)))
                    }
                case .concat(let n):
                    var s = ""
                    for v in stack[(stack.count - n)...] {
                        if case .string(let part) = v { s += part }
                    }
                    stack.removeLast(n)
                    try meter.checkString(s)
                    stack.append(.string(s))
                case .matchEnumCase(let t, let i):
                    let v = stack.removeLast()
                    switch v {
                    case .enumCase(let vt, let vi): stack.append(.bool(vt == t && vi == i))
                    case .symbol(let s): stack.append(.bool(program.types[t].caseNames[i] == s))
                    default: stack.append(.bool(false))
                    }
                case .matchSymbolCase(let name):
                    let v = stack.removeLast()
                    switch v {
                    case .enumCase(let vt, let vi): stack.append(.bool(program.types[vt].caseNames[vi] == name))
                    case .symbol(let s): stack.append(.bool(s == name))
                    default: stack.append(.bool(false))
                    }
                case .rangeContains:
                    let v = stack.removeLast()
                    let r = stack.removeLast()
                    guard case .range(let rv) = r else { throw VMError.typeMismatch("区间模式需要 Range。") }
                    guard case .int(let x) = v else { throw VMError.typeMismatch("区间模式只支持 Int。") }
                    stack.append(.bool(x >= rv.lower && x < rv.endExclusive))

                case .jump(let t): pc = t
                case .jumpIfFalse(let t):
                    if !(try ValueOps.truthy(stack.removeLast())) { pc = t }
                case .jumpIfTrue(let t):
                    if try ValueOps.truthy(stack.removeLast()) { pc = t }
                case .jumpIfNil(let t):
                    if case .none = stack[stack.count - 1] { pc = t }
                case .jumpIfNotNil(let t):
                    if case .none = stack[stack.count - 1] {} else { pc = t }
                case .loop(let t):
                    // 循环回边检查点
                    try meter.checkCancel()
                    try meter.checkSteps()
                    pc = t
                case .iterMake(let slot):
                    let seq = stack.removeLast()
                    stack[base + slot] = .iterator(try makeIterator(seq))
                case .iterNext(let slot, let exit):
                    guard case .iterator(let it) = stack[base + slot] else { throw VMError.internalError("迭代器槽位损坏") }
                    if let v = it.next() { stack.append(v) } else { pc = exit }

                case .call(let fid, let argc):
                    frames[fi].pc = pc
                    try pushFrame(program.functions[fid], argc: argc, closure: nil, dropBelow: 0, onReturn: .push)
                    fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                case .callValue(let argc):
                    let callee = stack[stack.count - argc - 1]
                    frames[fi].pc = pc
                    switch callee {
                    case .closure(let c):
                        try pushFrame(c.function, argc: argc, closure: c, dropBelow: 1, onReturn: .push)
                    case .function(let f):
                        try pushFrame(program.functions[f], argc: argc, closure: nil, dropBelow: 1, onReturn: .push)
                    default:
                        throw VMError.typeMismatch("'\(ValueOps.typeName(callee))' 不能作为函数调用。")
                    }
                    fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                case .callMethod(let name, let argc):
                    frames[fi].pc = pc
                    if try dispatchMethod(name: name, argc: argc) {
                        fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                    }
                case .callBuiltin(let name, let labels):
                    let args = popN(labels.count)
                    frames[fi].pc = pc
                    stack.append(try Stdlib.callFunction(self, name, labels: labels, args: args))
                case .construct(let t, let fields):
                    let args = popN(fields.count)
                    frames[fi].pc = pc
                    var rec = try defaultRecord(t)
                    let info = program.types[t]
                    for (k, f) in fields.enumerated() {
                        rec.fields[f] = coerceField(args[k], info.fieldTypes[f])
                    }
                    stack.append(.record(rec))
                case .callInit(let t, let f, let argc):
                    frames[fi].pc = pc
                    let rec = try defaultRecord(t)
                    stack.insert(.record(rec), at: stack.count - argc)
                    try pushFrame(program.functions[f], argc: argc + 1, closure: nil, dropBelow: 0, onReturn: .push)
                    fi = frames.count - 1; fn = frames[fi].function; pc = 0; base = frames[fi].base
                case .makeClosure(let f, let caps):
                    var values: [Value] = []
                    values.reserveCapacity(caps.count)
                    for c in caps {
                        switch c {
                        case .local(let slot, let byRef):
                            let cur = stack[base + slot]
                            if byRef {
                                if case .box = cur { values.append(cur) } else {
                                    let b = Box(cur)
                                    stack[base + slot] = .box(b)
                                    values.append(.box(b))
                                }
                            } else {
                                switch cur {
                                case .box(let b): values.append(b.value)
                                default: values.append(cur)
                                }
                            }
                        case .capture(let i):
                            guard let cl = frames[fi].closure else { throw VMError.internalError("非闭包帧访问捕获") }
                            values.append(cl.captures[i])
                        }
                    }
                    stack.append(.closure(ClosureObject(function: program.functions[f], captures: values)))
                case .ret:
                    let result = stack.removeLast()
                    let frame = frames.removeLast()
                    var selfValue: Value? = frame.function.isMutating ? stack[frame.base] : nil
                    if case .box(let b)? = selfValue { selfValue = b.value }
                    stack.removeLast(stack.count - (frame.base - frame.dropBelow))
                    switch frame.onReturn {
                    case .push:
                        stack.append(result)
                    case .host:
                        if frames.count == stopDepth { return .returned(result) }
                        throw VMError.internalError("宿主返回帧深度不一致")
                    case .writeBack(let root, let steps):
                        guard let sv = selfValue else { throw VMError.internalError("mutating 写回缺少 self") }
                        fi = frames.count - 1
                        try writePlace(root: root, steps: steps, frameIndex: fi, value: sv)
                        stack.append(result)
                    case .initGlobal(let g):
                        storeGlobal(g, result)
                        stack.append(result)
                    }
                    if frames.count == stopDepth { return .returned(result) }
                    fi = frames.count - 1; fn = frames[fi].function; pc = frames[fi].pc; base = frames[fi].base

                case .makeArray(let n):
                    try meter.checkCollection(n)
                    let elems = popN(n)
                    stack.append(.array(elems))
                case .makeDict(let n):
                    let kv = popN(n * 2)
                    var d = DictValue()
                    for i in 0..<n {
                        let k = kv[2 * i]
                        let h = try hashKey(k)
                        if d.get(h) != nil {
                            throw VMError.trap("字典字面量包含重复的键 \(describer.describe(k, type: nil, debug: true))（Swift: Dictionary literal contains duplicate keys）")
                        }
                        d.set(k, hash: h, kv[2 * i + 1])
                    }
                    stack.append(.dict(d))
                case .makeRecord(let t, let n):
                    let fields = popN(n)
                    stack.append(.record(RecordValue(type: t, fields: fields)))
                case .makeTuple(let labels):
                    let elems = popN(labels.count)
                    stack.append(.tuple(TupleValue(elements: elems, labels: labels)))
                case .makeViewGroup(let n):
                    let views = popN(n)
                    if n == 1 { stack.append(views[0]) } else {
                        stack.append(.view(ViewNode(.group(views))))
                    }
                case .wrapConditional(let branch):
                    let v = stack.removeLast()
                    stack.append(.view(ViewNode(.conditional(branch, v))))
                case .trap(let msg):
                    throw VMError.trap(msg)
                case .unsupported(let msg, let cap):
                    throw VMError.unsupported(msg, capabilityID: cap)
                }
            }
        } catch let e as VMError {
            let range = program.range(function: fn, pc: pc - 1)
            throw VMFailure(error: e, range: range, functionName: fn.name)
        }
    }

    // MARK: - 辅助

    func coerceField(_ v: Value, _ t: SType) -> Value {
        if case .int(let x) = v {
            if t == .double || t == .optional(.double) { return .double(Double(x)) }
        }
        return v
    }

    func defaultRecord(_ t: Int) throws -> RecordValue {
        let info = program.types[t]
        if let f = info.defaultsFunction {
            let v = try invokeFunction(f, [])
            if case .record(let r) = v { return r }
            throw VMError.internalError("默认值函数未返回记录")
        }
        return RecordValue(type: t, fields: Array(repeating: .void, count: info.fieldNames.count))
    }

    /// 取成员值（含计算属性，必要时回调 VM）。
    func memberValue(_ v: Value, _ name: String) throws -> Value {
        if let g = computedGetter(v, name) { return try invokeFunction(g, [v]) }
        return try Stdlib.member(self, v, name)
    }

    func computedGetter(_ v: Value, _ name: String) -> Int? {
        switch v {
        case .record(let r): return program.types[r.type].computed[name]
        case .enumCase(let t, _): return program.types[t].computed[name]
        default: return nil
        }
    }

    func makeIterator(_ seq: Value) throws -> IteratorBox {
        switch seq {
        case .array(let a): return IteratorBox(.array(a))
        case .range(let r): return IteratorBox(.range(lower: r.lower, endExclusive: r.endExclusive))
        case .dict(let d): return IteratorBox(.dict(keys: d.keys, values: d.values))
        case .string(let s): return IteratorBox(.array(s.map { .string(String($0)) }))
        case .iterator(let it): return it
        default: throw VMError.typeMismatch("'\(ValueOps.typeName(seq))' 不是可遍历的序列。")
        }
    }

    /// 动态方法分派。返回 true 表示压入了新帧。
    func dispatchMethod(name: String, argc: Int) throws -> Bool {
        let recvIndex = stack.count - argc - 1
        let recv = stack[recvIndex]
        switch recv {
        case .record(let r):
            if let m = program.types[r.type].methods[name], !m.isStatic {
                try pushFrame(program.functions[m.function], argc: argc + 1, closure: nil, dropBelow: 0, onReturn: .push)
                return true
            }
        case .enumCase(let t, _):
            if let m = program.types[t].methods[name], !m.isStatic {
                try pushFrame(program.functions[m.function], argc: argc + 1, closure: nil, dropBelow: 0, onReturn: .push)
                return true
            }
        case .metatype(let t):
            if let m = program.types[t].methods[name], m.isStatic {
                stack.remove(at: recvIndex)
                try pushFrame(program.functions[m.function], argc: argc, closure: nil, dropBelow: 0, onReturn: .push)
                return true
            }
        default:
            break
        }
        let args = popN(argc)
        let receiver = stack.removeLast()
        stack.append(try Stdlib.callMethod(self, receiver, name, args))
        return false
    }
}

/// 沿"第一个子值"链探测嵌套深度（O(limit)）。
enum NestingProbe {
    static let limit = 1000
    static let error = VMError.budget(.heap, "值的嵌套层数超过 \(limit)（例如反复把数组包进数组），为保护宿主已终止。")

    static func exceeds(_ root: Value) -> Bool {
        var cur = root
        for _ in 0..<limit {
            switch cur {
            case .array(let a): guard let f = a.first else { return false }; cur = f
            case .tuple(let t): guard let f = t.elements.first else { return false }; cur = f
            case .record(let r): guard let f = r.fields.first else { return false }; cur = f
            case .dict(let d): guard let f = d.values.first else { return false }; cur = f
            case .box(let b): cur = b.value
            case .stateCell(let c): cur = c.value
            default: return false
            }
        }
        return true
    }
}

/// 近似堆估计：每个值按固定开销计，大集合只抽样前 16 个元素再外推。
struct HeapEstimator {
    let limit: Int
    var total = 0
    private var seen = Set<ObjectIdentifier>()
    init(limit: Int) { self.limit = limit }

    mutating func add(_ v: Value, depth: Int = 0) {
        if total > limit || depth > 8 { return }
        total += 16
        switch v {
        case .string(let s): total += s.utf8.count
        case .array(let a): addCollection(a, depth: depth)
        case .dict(let d): addCollection(d.keys, depth: depth); addCollection(d.values, depth: depth)
        case .tuple(let t): for e in t.elements { add(e, depth: depth + 1) }
        case .record(let r): for f in r.fields { add(f, depth: depth + 1) }
        case .box(let b):
            if seen.insert(ObjectIdentifier(b)).inserted { add(b.value, depth: depth + 1) }
        case .closure(let c):
            if seen.insert(ObjectIdentifier(c)).inserted { for e in c.captures { add(e, depth: depth + 1) } }
        case .stateCell(let c):
            if seen.insert(ObjectIdentifier(c)).inserted { add(c.value, depth: depth + 1) }
        default: break
        }
    }

    private mutating func addCollection(_ a: [Value], depth: Int) {
        total += 16 * a.count
        let sample = min(a.count, 16)
        guard sample > 0 else { return }
        let before = total
        for i in 0..<sample { add(a[i], depth: depth + 1) }
        let sampled = total - before
        if a.count > sample { total += sampled / sample * (a.count - sample) }
    }
}
