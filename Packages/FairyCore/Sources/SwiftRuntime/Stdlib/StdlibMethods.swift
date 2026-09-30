import Foundation
import RuntimeContracts

extension Stdlib {
    // MARK: - 非 mutating 方法分派

    static func callMethod(_ vm: VM, _ recv: Value, _ name: String, _ args: [Value]) throws -> Value {
        switch recv {
        case .string(let s):
            if let r = try stringMethod(vm, s, name, args) { return r }
        case .int(let i):
            switch name {
            case "isMultiple(of:)":
                guard case .int(let d) = args[0] else { break }
                if d == 0 { return .bool(i == 0) }
                if d == -1 { return .bool(true) }
                return .bool(i % d == 0)
            case "signum()": return .int(i.signum())
            default: break
            }
        case .double(let d):
            switch name {
            case "rounded()": return .double(d.rounded())
            case "rounded(_:)":
                guard case .symbol(let rule) = args[0] else { break }
                switch rule {
                case "up": return .double(d.rounded(.up))
                case "down": return .double(d.rounded(.down))
                case "toNearestOrAwayFromZero": return .double(d.rounded(.toNearestOrAwayFromZero))
                case "toNearestOrEven": return .double(d.rounded(.toNearestOrEven))
                default:
                    throw VMError.unsupported("rounded 不支持舍入规则 '\(rule)'", capabilityID: "stdlib.Double.rounded")
                }
            case "squareRoot()": return .double(d.squareRoot())
            case "truncatingRemainder(dividingBy:)":
                guard case .double(let y) = args[0] else { break }
                return .double(d.truncatingRemainder(dividingBy: y))
            default: break
            }
        case .view, .record:
            if let r = try ViewBuiltins.modifier(vm, recv, name, args) { return r }
        case .dict(let d):
            if let r = try dictMethod(vm, d, name, args) { return r }
        default:
            break
        }
        if let elems = try elements(vm, recv) {
            if let r = try sequenceMethod(vm, elems, name, args, receiver: recv) { return r }
        }
        if case .record(let r) = recv {
            throw VMError.typeMismatch("'\(vm.program.types[r.type].name)' 没有方法 '\(name)'。")
        }
        throw VMError.typeMismatch("'\(ValueOps.typeName(recv))' 没有方法 '\(name)'（或运行时尚不支持）。")
    }

    static func stringMethod(_ vm: VM, _ s: String, _ name: String, _ args: [Value]) throws -> Value? {        func str(_ i: Int) throws -> String {
            guard case .string(let t) = args[i] else { throw VMError.typeMismatch("\(name) 需要 String 参数。") }
            return t
        }
        switch name {
        case "uppercased()": return .string(s.uppercased())
        case "lowercased()": return .string(s.lowercased())
        case "contains(_:)": return .bool(s.contains(try str(0)))
        case "hasPrefix(_:)": return .bool(s.hasPrefix(try str(0)))
        case "hasSuffix(_:)": return .bool(s.hasSuffix(try str(0)))
        case "reversed()": return .array(s.reversed().map { .string(String($0)) })
        case "split(separator:)":
            let sep = try str(0)
            guard sep.count == 1, let c = sep.first else { throw VMError.typeMismatch("split(separator:) 需要单个字符。") }
            return .array(s.split(separator: c).map { .string(String($0)) })
        case "components(separatedBy:)":
            return .array(s.components(separatedBy: try str(0)).map { .string($0) })
        case "replacingOccurrences(of:with:)":
            let r = s.replacingOccurrences(of: try str(0), with: try str(1))
            try vm.meter.checkString(r)
            return .string(r)
        case "trimmingCharacters(in:)":
            return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case "prefix(_:)":
            guard case .int(let n) = args[0] else { break }
            guard n >= 0 else { throw VMError.trap("prefix 的长度不能为负（Swift: Can't take a prefix of negative length）") }
            return .string(String(s.prefix(n)))
        case "suffix(_:)":
            guard case .int(let n) = args[0] else { break }
            guard n >= 0 else { throw VMError.trap("suffix 的长度不能为负（Swift: Can't take a suffix of negative length）") }
            return .string(String(s.suffix(n)))
        case "dropFirst()": return .string(String(s.dropFirst()))
        case "dropLast()": return .string(String(s.dropLast()))
        case "dropFirst(_:)":
            guard case .int(let n) = args[0], n >= 0 else { break }
            return .string(String(s.dropFirst(n)))
        case "dropLast(_:)":
            guard case .int(let n) = args[0], n >= 0 else { break }
            return .string(String(s.dropLast(n)))
        case "filter(_:)":
            var out = ""
            for ch in s where try ValueOps.truthy(try vm.invoke(args[0], [.string(String(ch))])) { out.append(ch) }
            return .string(out)
        default:
            return nil
        }
        return nil
    }

    /// String(format:) 子集：只支持 `%.Nf`（N 位小数）与 `%%`；参数为 Int/Double（转 Double 格式化）。
    /// 与宿主 `String(format:)` 逐字节一致（含 nan/inf/舍入）；其他占位符报 unsupported。
    static func stringFormat(_ vm: VM, format: String, args: [Value]) throws -> Value {
        func unsupported(_ what: String) -> Error {
            VMError.unsupported("String(format:) 仅支持 %.Nf 与 %%，不支持 \(what)（格式：\(format.debugDescription)）",
                                capabilityID: "stdlib.String.format")
        }
        var out = ""
        var ai = args.startIndex
        var i = format.startIndex
        while i < format.endIndex {
            guard format[i] == "%" else {
                out.append(format[i])
                i = format.index(after: i)
                continue
            }
            i = format.index(after: i)
            guard i < format.endIndex else { throw unsupported("末尾的 %") }
            if format[i] == "%" {
                out.append("%")
                i = format.index(after: i)
                continue
            }
            guard format[i] == "." else { throw unsupported("'%\(format[i])'") }
            i = format.index(after: i)
            var digits = ""
            while i < format.endIndex, format[i].isNumber {
                digits.append(format[i])
                i = format.index(after: i)
            }
            guard !digits.isEmpty, Int(digits) != nil, i < format.endIndex, format[i] == "f" else {
                throw unsupported("'%.' 后非 <位数>f")
            }
            i = format.index(after: i)
            guard ai < args.endIndex else {
                throw VMError.trap("String(format:) 的实参数量少于格式占位符（格式：\(format.debugDescription)）。")
            }
            let v: Double
            switch args[ai] {
            case .int(let x): v = Double(x)
            case .double(let d): v = d
            default:
                throw VMError.typeMismatch("String(format:) 的 %.Nf 参数必须是 Int 或 Double，实际是 '\(ValueOps.typeName(args[ai]))'。")
            }
            ai += 1
            out += String(format: "%.\(digits)f", v)
        }
        try vm.meter.checkString(out)
        return .string(out)
    }

    static func dictMethod(_ vm: VM, _ d: DictValue, _ name: String, _ args: [Value]) throws -> Value? {
        switch name {
        case "mapValues(_:)":
            var out = DictValue()
            for (i, k) in d.keys.enumerated() {
                out.set(k, hash: try hashKey(k), try vm.invoke(args[0], [d.values[i]]))
            }
            return .dict(out)
        case "filter(_:)":
            var out = DictValue()
            for (i, k) in d.keys.enumerated() {
                let pair = Value.tuple(TupleValue(elements: [k, d.values[i]], labels: ["key", "value"]))
                if try ValueOps.truthy(try callElement(vm, args[0], pair)) { out.set(k, hash: try hashKey(k), d.values[i]) }
            }
            return .dict(out)
        case "contains(where:)", "map(_:)", "forEach(_:)", "sorted(by:)", "reduce(_:_:)", "first(where:)", "compactMap(_:)", "allSatisfy(_:)", "min(by:)", "max(by:)":
            return nil   // 走序列通用实现（元素为 (key:, value:) 元组）
        default:
            return nil
        }
    }

    static func sequenceMethod(_ vm: VM, _ a: [Value], _ name: String, _ args: [Value], receiver: Value) throws -> Value? {
        switch name {
        case "contains(_:)":
            if case .range(let r) = receiver, case .int(let x) = args[0] { return .bool(x >= r.lower && x < r.endExclusive) }
            for e in a where try ValueOps.equals(e, args[0]) { return .bool(true) }
            return .bool(false)
        case "contains(where:)":
            for e in a where try ValueOps.truthy(try callElement(vm, args[0], e)) { return .bool(true) }
            return .bool(false)
        case "allSatisfy(_:)":
            for e in a where !(try ValueOps.truthy(try callElement(vm, args[0], e))) { return .bool(false) }
            return .bool(true)
        case "map(_:)":
            var out: [Value] = []
            out.reserveCapacity(a.count)
            for e in a { out.append(try callElement(vm, args[0], e)) }
            return .array(out)
        case "compactMap(_:)":
            var out: [Value] = []
            for e in a { let r = try callElement(vm, args[0], e); if !r.isNil { out.append(r) } }
            return .array(out)
        case "filter(_:)":
            var out: [Value] = []
            for e in a where try ValueOps.truthy(try callElement(vm, args[0], e)) { out.append(e) }
            return .array(out)
        case "forEach(_:)":
            for e in a { _ = try callElement(vm, args[0], e) }
            return .void
        case "reduce(_:_:)":
            var acc = args[0]
            for e in a { acc = try vm.invoke(args[1], [acc, e]) }
            return acc
        case "sorted()": return .array(try sortValues(a, by: nil, vm: vm))
        case "sorted(by:)": return .array(try sortValues(a, by: args[0], vm: vm))
        case "reversed()": return .array(a.reversed())
        case "enumerated()":
            return .array(a.enumerated().map { .tuple(TupleValue(elements: [.int($0.offset), $0.element], labels: ["offset", "element"])) })
        case "first(where:)":
            for e in a where try ValueOps.truthy(try callElement(vm, args[0], e)) { return e }
            return Value.none
        case "firstIndex(of:)":
            // Range 的索引即元素值本身：firstIndex(of:) 返回区间索引而非偏移
            //（(1..<6).firstIndex(of: 3) == 3，宿主差分验证）。
            if case .range(let r) = receiver, case .int(let x) = args[0], x >= r.lower, x < r.endExclusive {
                return .int(x)
            }
            for (i, e) in a.enumerated() where try ValueOps.equals(e, args[0]) { return .int(i) }
            return Value.none
        case "firstIndex(where:)":
            // Range 同上：闭包命中元素的索引是元素值。
            if case .range(let r) = receiver, case .int(let x) = args[0],
               x >= r.lower, x < r.endExclusive,
               try ValueOps.truthy(try callElement(vm, args[0], .int(x))) {
                return .int(x)
            }
            for (i, e) in a.enumerated() where try ValueOps.truthy(try callElement(vm, args[0], e)) { return .int(i) }
            return Value.none
        case "lastIndex(of:)":
            if case .range(let r) = receiver, case .int(let x) = args[0], x >= r.lower, x < r.endExclusive {
                return .int(x)
            }
            for (i, e) in a.enumerated().reversed() where try ValueOps.equals(e, args[0]) { return .int(i) }
            return Value.none
        case "min()":
            guard var m = a.first else { return Value.none }
            for e in a.dropFirst() where try ValueOps.less(e, m) { m = e }
            return m
        case "max()":
            guard var m = a.first else { return Value.none }
            for e in a.dropFirst() where try ValueOps.less(m, e) { m = e }
            return m
        case "min(by:)":
            guard var m = a.first else { return Value.none }
            for e in a.dropFirst() where try ValueOps.truthy(try vm.invoke(args[0], [e, m])) { m = e }
            return m
        case "max(by:)":
            guard var m = a.first else { return Value.none }
            for e in a.dropFirst() where try ValueOps.truthy(try vm.invoke(args[0], [m, e])) { m = e }
            return m
        case "count(where:)":
            var n = 0
            for e in a where try ValueOps.truthy(try callElement(vm, args[0], e)) { n += 1 }
            return .int(n)
        case "joined(separator:)", "joined()":
            let sep: String
            if args.isEmpty { sep = "" } else if case .string(let s) = args[0] { sep = s } else { throw VMError.typeMismatch("joined 需要 String 分隔符。") }
            var parts: [String] = []
            for e in a {
                guard case .string(let s) = e else { throw VMError.typeMismatch("joined 只能用于 [String]。") }
                parts.append(s)
            }
            let r = parts.joined(separator: sep)
            try vm.meter.checkString(r)
            return .string(r)
        case "prefix(_:)":
            guard case .int(let n) = args[0], n >= 0 else { throw VMError.trap("prefix 的长度不能为负") }
            return .array(Array(a.prefix(n)))
        case "suffix(_:)":
            guard case .int(let n) = args[0], n >= 0 else { throw VMError.trap("suffix 的长度不能为负") }
            return .array(Array(a.suffix(n)))
        case "dropFirst()": return .array(Array(a.dropFirst()))
        case "dropLast()": return .array(Array(a.dropLast()))
        case "dropFirst(_:)":
            guard case .int(let n) = args[0], n >= 0 else { throw VMError.trap("dropFirst 的数量不能为负") }
            return .array(Array(a.dropFirst(n)))
        case "dropLast(_:)":
            guard case .int(let n) = args[0], n >= 0 else { throw VMError.trap("dropLast 的数量不能为负") }
            return .array(Array(a.dropLast(n)))
        default:
            return nil
        }
    }

    // MARK: - 自由函数与类型构造

    static func callFunction(_ vm: VM, _ name: String, labels: [String?], args: [Value]) throws -> Value {
        switch name {
        case "print":
            var sep = " ", term = "\n"
            var parts: [String] = []
            for (i, l) in labels.enumerated() {
                guard case .string(let s) = args[i] else { continue }
                switch l {
                case "separator": sep = s
                case "terminator": term = s
                default: parts.append(s)
                }
            }
            let text = parts.joined(separator: sep) + term
            try vm.meter.checkString(text)
            vm.console(.stdout, text)
            return .void
        case "abs":
            switch args[0] {
            case .int(let x):
                if x == Int.min { throw VMError.trap("整数溢出：abs(Int.min)（Swift: arithmetic overflow）") }
                return .int(Swift.abs(x))
            case .double(let x): return .double(Swift.abs(x))
            default: break
            }
        case "min", "max":
            guard var best = args.first else { break }
            for x in args.dropFirst() {
                let less = try ValueOps.less(x, best)
                let greater = try ValueOps.less(best, x)
                if name == "min" ? less : greater { best = x }
            }
            return best
        case "Int":
            if labels == [nil] {
                switch args[0] {
                case .int: return args[0]
                case .double(let d):
                    guard d.isFinite else { throw VMError.trap("Double 值无法转换为 Int：它是无穷大或 NaN（Swift: Double value cannot be converted to Int because it is either infinite or NaN）") }
                    guard d > -9223372036854775809.0 && d < 9223372036854775808.0 else {
                        throw VMError.trap("Double 值 \(d) 超出 Int 范围（Swift: Double value cannot be converted to Int because the result would be greater than Int.max）")
                    }
                    return .int(Int(d))
                case .string(let s): return Int(s).map { .int($0) } ?? .none
                default: break
                }
            }
        case "Double":
            if labels == [nil] {
                switch args[0] {
                case .int(let i): return .double(Double(i))
                case .double: return args[0]
                case .string(let s): return Double(s).map { .double($0) } ?? .none
                default: break
                }
            }
        case "String":
            if labels == [nil] {
                switch args[0] {
                case .string: return args[0]
                case .array(let a):
                    // String(chars)：[Character] 以单字符 String 表示
                    var s = ""
                    for e in a { if case .string(let c) = e { s += c } else { return .string(vm.describer.describe(args[0], type: nil)) } }
                    return .string(s)
                case .date(let d):
                    return .string(String(describing: d))
                default: return .string(vm.describer.describe(args[0], type: nil))
                }
            }
            if labels == ["describing"] { return .string(vm.describer.describe(args[0], type: nil)) }
            if labels.first == "format" {
                guard case .string(let fmt) = args[0] else { throw VMError.typeMismatch("String(format:) 需要格式字符串。") }
                return try stringFormat(vm, format: fmt, args: Array(args.dropFirst()))
            }
            if labels == ["repeating", "count"] {
                guard case .string(let s) = args[0], case .int(let n) = args[1] else { break }
                guard n >= 0 else { throw VMError.trap("String(repeating:count:) 的次数不能为负（Swift: Negative count not allowed）") }
                let (total, overflow) = s.utf8.count.multipliedReportingOverflow(by: n)
                if overflow || total > vm.meter.budget.maxStringLength {
                    throw VMError.budget(.stringLength, "字符串长度超过预算（maxStringLength = \(vm.meter.budget.maxStringLength) 字节）。")
                }
                return .string(String(repeating: s, count: n))
            }
        case "Date":
            if labels.isEmpty || labels == ["now"] { return .date(Date()) }
        case "zip":
            guard args.count == 2,
                  let a = try elements(vm, args[0]), let b = try elements(vm, args[1]) else { break }
            let n = min(a.count, b.count)
            var out: [Value] = []
            for i in 0..<n {
                out.append(.tuple(TupleValue(elements: [a[i], b[i]], labels: [nil, nil])))
            }
            try vm.meter.checkCollection(out.count)
            return .array(out)
        case "repeatElement":
            guard case .int(let n) = args[1] else { break }
            guard n >= 0 else {
                throw VMError.trap("repeatElement 的次数不能为负（Swift: Requirement failed: count >= 0）")
            }
            try vm.meter.checkCollection(n)
            return .array(Array(repeating: args[0], count: n))
        case "Array":
            if labels == [nil], let e = try elements(vm, args[0]) { return .array(e) }
            if labels == ["repeating", "count"] {
                guard case .int(let n) = args[1] else { break }
                guard n >= 0 else { throw VMError.trap("Array(repeating:count:) 的数量不能为负（Swift: Can't construct Array with count < 0）") }
                try vm.meter.checkCollection(n)
                return .array(Array(repeating: args[0], count: n))
            }
            if labels.isEmpty { return .array([]) }
        case "Dictionary":
            if labels.isEmpty { return .dict(DictValue()) }
        case "stride":
            if labels == ["from", "to", "by"] || labels == ["from", "through", "by"] {
                let inclusive = labels[1] == "through"
                switch (args[0], args[1], args[2]) {
                case (.int(let f), .int(let t), .int(let b)):
                    guard b != 0 else { throw VMError.trap("stride 的步长不能为 0（Swift: Stride size must not be zero）") }
                    var out: [Value] = []
                    var x = f
                    while b > 0 ? (inclusive ? x <= t : x < t) : (inclusive ? x >= t : x > t) {
                        out.append(.int(x))
                        try vm.meter.checkCollection(out.count)
                        let (n, o) = x.addingReportingOverflow(b)
                        if o { break }
                        x = n
                    }
                    return .array(out)
                case (.double(let f), .double(let t), .double(let b)):
                    guard b != 0 else { throw VMError.trap("stride 的步长不能为 0（Swift: Stride size must not be zero）") }
                    var out: [Value] = []
                    var i = 0
                    while true {
                        let x = f + Double(i) * b
                        let ok = b > 0 ? (inclusive ? x <= t : x < t) : (inclusive ? x >= t : x > t)
                        if !ok { break }
                        out.append(.double(x))
                        try vm.meter.checkCollection(out.count)
                        i += 1
                    }
                    return .array(out)
                default: break
                }
            }
        case "fatalError":
            var msg = ""
            if case .string(let s)? = args.first { msg = s }
            throw VMError.trap("fatalError：\(msg)")
        case "precondition", "assert":
            if case .bool(let ok) = args[0], !ok {
                var msg = ""
                if args.count > 1, case .string(let s) = args[1] { msg = s }
                throw VMError.trap("\(name) 失败：\(msg)")
            }
            return .void
        case "sqrt", "floor", "ceil", "round", "sin", "cos", "exp", "log":
            guard case .double(let x) = args[0] else { break }
            switch name {
            case "sqrt": return .double(x.squareRoot())
            case "floor": return .double(x.rounded(.down))
            case "ceil": return .double(x.rounded(.up))
            case "round": return .double(x.rounded())
            case "sin": return .double(Foundation.sin(x))
            case "cos": return .double(Foundation.cos(x))
            case "exp": return .double(Foundation.exp(x))
            default: return .double(Foundation.log(x))
            }
        case "pow":
            if case .double(let x) = args[0], case .double(let y) = args[1] { return .double(Foundation.pow(x, y)) }
        case "__enumFromRaw":
            guard case .metatype(let t) = args[0], let raws = vm.program.types[t].rawValues else { break }
            for (i, r) in raws.enumerated() {
                switch (r, args[1]) {
                case (.int(let a), .int(let b)) where a == b: return .enumCase(type: t, index: i, payload: [])
                case (.string(let a), .string(let b)) where a == b: return .enumCase(type: t, index: i, payload: [])
                case (.double(let a), .double(let b)) where a == b: return .enumCase(type: t, index: i, payload: [])
                default: continue
                }
            }
            return .none
        default:
            if let v = try ViewBuiltins.construct(vm, name, labels: labels, args: args) { return v }
        }
        throw VMError.typeMismatch("'\(name)(\(labels.map { ($0 ?? "_") + ":" }.joined()))' 的参数类型不受支持：\(args.map { ValueOps.typeName($0) }.joined(separator: ", "))。")
    }
}
