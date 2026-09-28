import RuntimeContracts

/// 值的文本描述，与 Swift 标准库 `print` / 字符串插值 / `String(describing:)` 的输出保持一致（差分测试逐字节比较）。
///
/// - 顶层：String 原样，结构体 `Name(a: 1)`，枚举 `caseName`。
/// - 嵌套（集合元素、结构体字段、Optional 内部）：debugDescription 风格——字符串带引号，
///   结构体/枚举带模块前缀 `main.Name(...)`、`main.Enum.case`。
/// - Optional 采用扁平表示，依据静态类型补上 `Optional(...)`。
struct Describer {
    let program: IRProgram
    /// CustomStringConvertible：用户类型的 description（由 VM 回调计算属性）
    var custom: ((Value) -> String?)? = nil

    func describe(_ v: Value, type: SType?, debug: Bool = false) -> String {
        describe(v, type: type, debug: debug, depth: 0)
    }

    private func describe(_ v: Value, type: SType?, debug: Bool, depth: Int) -> String {
        if depth > 256 { return "…" }
        func describe(_ v: Value, type: SType?, debug: Bool) -> String {
            self.describe(v, type: type, debug: debug, depth: depth + 1)
        }
        let t = type ?? .unknown
        if case .optional(let wrapped) = t {
            if case .none = v { return "nil" }
            return "Optional(" + describe(v, type: wrapped, debug: true) + ")"
        }
        if let custom, let s = custom(v) { return s }
        switch v {
        case .void: return "()"
        case .none: return "nil"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d.description
        case .date(let d): return String(describing: d)
        case .string(let s): return debug ? s.debugDescription : s
        case .array(let a):
            let et = t.elementTypeForDescribe
            return "[" + a.map { describe($0, type: et, debug: true) }.joined(separator: ", ") + "]"
        case .dict(let d):
            if d.count == 0 { return "[:]" }
            var kt: SType = .unknown, vt: SType = .unknown
            if case .dict(let k, let vv) = t { kt = k; vt = vv }
            var parts: [String] = []
            for (i, k) in d.keys.enumerated() {
                parts.append(describe(k, type: kt, debug: true) + ": " + describe(d.values[i], type: vt, debug: true))
            }
            return "[" + parts.joined(separator: ", ") + "]"
        case .range(let r):
            return "\(r.lower)\(r.closed ? "..." : "..<")\(r.upper)"
        case .partialRange(let lo, let hi, let closed):
            // 与 Swift print 输出逐字节一致（差分测试校验）。
            if let lo, hi == nil { return "PartialRangeFrom<Int>(lowerBound: \(lo))" }
            if let hi, lo == nil {
                return closed ? "PartialRangeThrough<Int>(upperBound: \(hi))" : "PartialRangeUpTo<Int>(upperBound: \(hi))"
            }
            return "\(lo.map(String.init) ?? "")\(closed ? "..." : "..<")\(hi.map(String.init) ?? "")"
        case .tuple(let tv):
            var ets: [SType] = []
            if case .tuple(let ts, _) = t { ets = ts }
            var parts: [String] = []
            for (i, e) in tv.elements.enumerated() {
                let et = i < ets.count ? ets[i] : SType.unknown
                let s = describe(e, type: et, debug: true)
                if i < tv.labels.count, let l = tv.labels[i] { parts.append("\(l): \(s)") } else { parts.append(s) }
            }
            return "(" + parts.joined(separator: ", ") + ")"
        case .record(let r):
            let info = program.types[r.type]
            var parts: [String] = []
            for (i, name) in info.fieldNames.enumerated() where i < r.fields.count {
                let fv = (try? deref(r.fields[i])) ?? .none
                let wrapper = i < info.fieldWrappers.count ? info.fieldWrappers[i] : .none
                let label = wrapper == .none ? name : "_" + name
                parts.append("\(label): " + describe(fv, type: info.fieldTypes[i], debug: true))
            }
            let prefix = debug ? "\(program.moduleName).\(info.name)" : info.name
            return prefix + "(" + parts.joined(separator: ", ") + ")"
        case .enumCase(let tid, let idx, let payload):
            let info = program.types[tid]
            let name = idx < info.caseNames.count ? info.caseNames[idx] : "?"
            if payload.isEmpty { return debug ? "\(program.moduleName).\(info.name).\(name)" : name }
            let labels = idx < info.casePayloadLabels.count ? info.casePayloadLabels[idx] : []
            var parts: [String] = []
            for (i, v) in payload.enumerated() {
                let s = describe(v, type: nil, debug: true)
                if i < labels.count, let l = labels[i] { parts.append("\(l): \(s)") } else { parts.append(s) }
            }
            let inner = "\(name)(" + parts.joined(separator: ", ") + ")"
            return debug ? "\(program.moduleName).\(info.name).\(inner)" : inner
        case .closure, .function: return "(Function)"
        case .metatype(let tid): return program.types[tid].name
        case .view: return "View"
        case .box(let b): return describe(b.value, type: type, debug: debug)
        case .stateCell(let c): return describe(c.value, type: type, debug: debug)
        case .binding(let b): return "Binding(" + describe((try? b.get()) ?? .none, type: nil, debug: true) + ")"
        case .symbol(let s): return s
        case .keyPath(let p): return "\\." + (p.isEmpty ? "self" : p.joined(separator: "."))
        case .iterator: return "IndexingIterator"
        }
    }
}

extension SType {
    fileprivate var elementTypeForDescribe: SType {
        if case .array(let e) = self { return e }
        return .unknown
    }
}
