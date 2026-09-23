import RuntimeContracts

/// 值运算：算术（带溢出检测）、比较、相等。全部用 reportingOverflow 系列实现，不触发原生 trap。
enum ValueOps {
    static func typeName(_ v: Value) -> String {
        switch v {
        case .void: return "Void"
        case .none: return "nil"
        case .bool: return "Bool"
        case .int: return "Int"
        case .double: return "Double"
        case .string: return "String"
        case .array: return "Array"
        case .dict: return "Dictionary"
        case .range: return "Range"
        case .tuple: return "Tuple"
        case .record: return "struct"
        case .enumCase: return "enum"
        case .closure, .function: return "函数"
        case .metatype: return "类型"
        case .view: return "View"
        case .box, .stateCell, .binding: return "引用"
        case .symbol(let s): return ".\(s)"
        case .keyPath: return "KeyPath"
        case .iterator: return "迭代器"
        }
    }

    static func binary(_ op: BinOp, _ a: Value, _ b: Value, literal: LiteralSide) throws -> Value {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            return try intBinary(op, x, y)
        case (.double(let x), .double(let y)):
            return try doubleBinary(op, x, y)
        case (.int(let x), .double(let y)) where literal == .lhs:
            return try doubleBinary(op, Double(x), y)
        case (.double(let x), .int(let y)) where literal == .rhs:
            return try doubleBinary(op, x, Double(y))
        case (.int, .double), (.double, .int):
            throw VMError.typeMismatch("二元运算符 '\(op.rawValue)' 不能用于 '\(typeName(a))' 和 '\(typeName(b))'：Swift 不做 Int 与 Double 的隐式转换，请使用 Double(x) 或 Int(x)。")
        case (.string(let x), .string(let y)):
            switch op {
            case .add: return .string(x + y)
            case .eq: return .bool(x == y)
            case .ne: return .bool(x != y)
            case .lt: return .bool(x < y)
            case .le: return .bool(x <= y)
            case .gt: return .bool(x > y)
            case .ge: return .bool(x >= y)
            default: break
            }
        case (.array(let x), .array(let y)) where op == .add:
            return .array(x + y)
        default:
            break
        }
        switch op {
        case .eq: return .bool(try equals(a, b))
        case .ne: return .bool(!(try equals(a, b)))
        case .lt: return .bool(try less(a, b))
        case .gt: return .bool(try less(b, a))
        case .le: return .bool(!(try less(b, a)))
        case .ge: return .bool(!(try less(a, b)))
        default:
            throw VMError.typeMismatch("二元运算符 '\(op.rawValue)' 不能用于 '\(typeName(a))' 和 '\(typeName(b))'。")
        }
    }

    static func intBinary(_ op: BinOp, _ x: Int, _ y: Int) throws -> Value {
        switch op {
        case .add:
            let (r, o) = x.addingReportingOverflow(y)
            if o { throw VMError.trap("整数溢出：\(x) + \(y) 超出 Int 范围（Swift: arithmetic overflow）") }
            return .int(r)
        case .sub:
            let (r, o) = x.subtractingReportingOverflow(y)
            if o { throw VMError.trap("整数溢出：\(x) - \(y) 超出 Int 范围（Swift: arithmetic overflow）") }
            return .int(r)
        case .mul:
            let (r, o) = x.multipliedReportingOverflow(by: y)
            if o { throw VMError.trap("整数溢出：\(x) * \(y) 超出 Int 范围（Swift: arithmetic overflow）") }
            return .int(r)
        case .div:
            if y == 0 { throw VMError.trap("除以零：\(x) / 0（Swift: Division by zero）") }
            let (r, o) = x.dividedReportingOverflow(by: y)
            if o { throw VMError.trap("整数溢出：\(x) / \(y)（Swift: arithmetic overflow）") }
            return .int(r)
        case .rem:
            if y == 0 { throw VMError.trap("除以零：\(x) % 0（Swift: Division by zero in remainder operation）") }
            let (r, o) = x.remainderReportingOverflow(dividingBy: y)
            if o { throw VMError.trap("整数溢出：\(x) % \(y)（Swift: arithmetic overflow）") }
            return .int(r)
        case .wrapAdd: return .int(x &+ y)
        case .wrapSub: return .int(x &- y)
        case .wrapMul: return .int(x &* y)
        case .bitAnd: return .int(x & y)
        case .bitOr: return .int(x | y)
        case .bitXor: return .int(x ^ y)
        case .shl: return .int(smartShiftLeft(x, y))
        case .shr: return .int(smartShiftLeft(x, y == Int.min ? Int.max : -y))
        case .eq: return .bool(x == y)
        case .ne: return .bool(x != y)
        case .lt: return .bool(x < y)
        case .le: return .bool(x <= y)
        case .gt: return .bool(x > y)
        case .ge: return .bool(x >= y)
        case .halfOpenRange:
            if x > y { throw VMError.trap("区间下界大于上界：\(x)..<\(y)（Swift: Range requires lowerBound <= upperBound）") }
            return .range(RangeValue(lower: x, upper: y, closed: false))
        case .closedRange:
            if x > y { throw VMError.trap("区间下界大于上界：\(x)...\(y)（Swift: Range requires lowerBound <= upperBound）") }
            if y == Int.max { throw VMError.unsupported("上界为 Int.max 的闭区间", capabilityID: "syntax.range") }
            return .range(RangeValue(lower: x, upper: y, closed: true))
        }
    }

    /// Swift 的"智能移位"：移位量超出位宽得 0（或符号扩展），负移位量反向。
    static func smartShiftLeft(_ x: Int, _ n: Int) -> Int {
        if n >= 0 {
            return n >= Int.bitWidth ? 0 : x << n
        } else {
            let m = n == Int.min ? Int.max : -n
            return m >= Int.bitWidth ? (x < 0 ? -1 : 0) : x >> m
        }
    }

    static func doubleBinary(_ op: BinOp, _ x: Double, _ y: Double) throws -> Value {
        switch op {
        case .add: return .double(x + y)
        case .sub: return .double(x - y)
        case .mul: return .double(x * y)
        case .div: return .double(x / y)
        case .eq: return .bool(x == y)
        case .ne: return .bool(x != y)
        case .lt: return .bool(x < y)
        case .le: return .bool(x <= y)
        case .gt: return .bool(x > y)
        case .ge: return .bool(x >= y)
        case .rem:
            throw VMError.typeMismatch("'%' 不能用于 Double，请使用 truncatingRemainder(dividingBy:)。")
        case .halfOpenRange, .closedRange:
            throw VMError.unsupported("Double 区间（\(op.rawValue)）", capabilityID: "syntax.range")
        default:
            throw VMError.typeMismatch("二元运算符 '\(op.rawValue)' 不能用于 Double。")
        }
    }

    static func unary(_ op: UnOp, _ v: Value) throws -> Value {
        switch (op, v) {
        case (.neg, .int(let x)):
            let (r, o) = (0).subtractingReportingOverflow(x)
            if o { throw VMError.trap("整数溢出：-(\(x))（Swift: arithmetic overflow）") }
            return .int(r)
        case (.neg, .double(let x)): return .double(-x)
        case (.plus, .int), (.plus, .double): return v
        case (.not, .bool(let b)): return .bool(!b)
        case (.bitNot, .int(let x)): return .int(~x)
        default:
            throw VMError.typeMismatch("一元运算符 '\(op.rawValue)' 不能用于 '\(typeName(v))'。")
        }
    }

    static func equals(_ a: Value, _ b: Value) throws -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.none, _), (_, .none): return false
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.enumCase(let t1, let i1), .enumCase(let t2, let i2)): return t1 == t2 && i1 == i2
        case (.symbol(let s), .symbol(let t)): return s == t
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            for i in 0..<x.count where !(try equals(x[i], y[i])) { return false }
            return true
        case (.tuple(let x), .tuple(let y)):
            guard x.elements.count == y.elements.count else { return false }
            for i in 0..<x.elements.count where !(try equals(x.elements[i], y.elements[i])) { return false }
            return true
        case (.record(let x), .record(let y)):
            guard x.type == y.type, x.fields.count == y.fields.count else { return false }
            for i in 0..<x.fields.count where !(try equals(try deref(x.fields[i]), try deref(y.fields[i]))) { return false }
            return true
        case (.dict(let x), .dict(let y)):
            guard x.count == y.count else { return false }
            for (i, k) in x.keys.enumerated() {
                guard let other = y.get(try hashKey(k)), try equals(x.values[i], other) else { return false }
            }
            return true
        case (.range(let x), .range(let y)): return x == y
        case (.int, .double), (.double, .int):
            throw VMError.typeMismatch("'==' 不能比较 Int 与 Double。")
        default:
            throw VMError.typeMismatch("'==' 不能用于 '\(typeName(a))' 和 '\(typeName(b))'（需要 Equatable）。")
        }
    }

    static func less(_ a: Value, _ b: Value) throws -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x < y
        case (.double(let x), .double(let y)): return x < y
        case (.string(let x), .string(let y)): return x < y
        case (.tuple(let x), .tuple(let y)) where x.elements.count == y.elements.count:
            for i in 0..<x.elements.count {
                if try less(x.elements[i], y.elements[i]) { return true }
                if try less(y.elements[i], x.elements[i]) { return false }
            }
            return false
        default:
            throw VMError.typeMismatch("'<' 不能用于 '\(typeName(a))' 和 '\(typeName(b))'（需要 Comparable）。")
        }
    }

    static func truthy(_ v: Value) throws -> Bool {
        if case .bool(let b) = v { return b }
        throw VMError.typeMismatch("条件必须是 Bool，实际是 '\(typeName(v))'。")
    }
}
