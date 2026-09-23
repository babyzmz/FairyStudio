import RuntimeContracts

/// 二元运算符。短路逻辑（&&、||）与 `??` 由跳转指令实现，不在这里。
enum BinOp: String, Sendable, Hashable {
    case add = "+", sub = "-", mul = "*", div = "/", rem = "%"
    case wrapAdd = "&+", wrapSub = "&-", wrapMul = "&*"
    case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">="
    case bitAnd = "&", bitOr = "|", bitXor = "^", shl = "<<", shr = ">>"
    case halfOpenRange = "..<", closedRange = "..."

    var isComparison: Bool {
        switch self {
        case .eq, .ne, .lt, .le, .gt, .ge: return true
        default: return false
        }
    }
    var isArithmetic: Bool {
        switch self {
        case .add, .sub, .mul, .div, .rem, .wrapAdd, .wrapSub, .wrapMul, .bitAnd, .bitOr, .bitXor, .shl, .shr: return true
        default: return false
        }
    }
}

enum UnOp: String, Sendable, Hashable { case neg = "-", not = "!", bitNot = "~", plus = "+" }

/// 二元运算中哪一侧是"整数字面量"。静态类型未知时，VM 允许把这一侧提升为 Double（动态回退）。
enum LiteralSide: UInt8, Sendable, Hashable { case none, lhs, rhs }

/// 闭包捕获来源。
enum CaptureSource: Sendable, Hashable {
    /// 外层函数的局部槽位；byRef 为 true 时（var）在创建闭包时把槽位原地装箱并共享该箱。
    case local(slot: Int, byRef: Bool)
    /// 外层闭包自己的第 n 个捕获（原样传递，可能是箱）。
    case capture(Int)
}

/// 左值根。
enum PlaceRoot: Sendable, Hashable {
    case local(Int)
    case capture(Int)
    case global(Int)
}

/// 左值路径的一步。下标键在运行时从操作数栈弹出。
enum PlaceStep: Sendable, Hashable {
    case field(Int)            // 已知类型的存储属性
    case member(String)        // 按名称（未知类型或元组标签）
    case tupleIndex(Int)
    case subscriptKey(argc: Int, label: String?)   // label == "default" 表示 dict[k, default: v]
    case unwrap                // 强制解包作为左值中间步（nil → trap）
    case optionalChain         // 可选链作为左值中间步（nil → 整个操作跳过，结果为 nil）
}

struct PlaceDesc: Sendable, Hashable {
    var root: PlaceRoot
    var steps: [PlaceStep]
    var keyCount: Int { steps.reduce(0) { if case .subscriptKey(let n, _) = $1 { return $0 + n }; return $0 } }
}

/// 对左值执行的操作。
enum PlaceOp: Sendable, Hashable {
    /// 栈：[keys…, newValue] → []
    case assign
    /// 栈：[keys…, rhs] → []
    case compound(BinOp, LiteralSide)
    /// 已静态解析的 mutating 用户方法：栈 [keys…, args…] → [result]
    case callMutating(function: Int, argc: Int)
    /// 动态分派（接收者类型未知或内建 mutating 方法）：栈 [keys…, args…] → [result]
    case callMethod(name: String, argc: Int)
    /// 读取左值当前值：栈 [keys…] → [value]
    case load
    /// `$x` / `$x.a[i]`：生成 Binding。栈 [keys…] → [binding]
    case projectBinding
}

/// 槽位化 IR 指令（栈式）。执行期不再持有任何 SwiftSyntax 节点。
enum Instr: Sendable, Hashable {
    // 常量
    case pushInt(Int)
    case pushDouble(Double)
    case pushBool(Bool)
    case pushString(String)
    case pushNil
    case pushVoid
    case pushSymbol(String)
    case pushKeyPath([String])
    case pushFunction(Int)
    case pushMetatype(Int)
    case pushEnum(type: Int, caseIndex: Int)

    // 栈操作
    case pop
    case dup
    case swap

    // 变量
    case loadLocal(Int)
    /// 声明绑定：覆盖槽位（即使之前被装箱，也换成新值），保证循环每次迭代都是新绑定。
    case initLocal(Int)
    /// 赋值：若槽位已装箱则写穿箱子。
    case storeLocal(Int)
    case loadCapture(Int)
    case storeCapture(Int)
    case loadGlobal(Int)
    case storeGlobal(Int)

    // 成员访问
    case getField(Int)
    case getMember(String)
    case getComputed(function: Int)
    case tupleElement(Int)
    case destructure(Int)
    case subscriptGet(argc: Int, label: String?)

    // 左值
    case place(Int, PlaceOp)

    // 运算
    case binary(BinOp, LiteralSide)
    case unary(UnOp)
    case forceUnwrap
    case toDouble            // 编译期确定的字面量/整数 → Double（仅用于字面量定型）
    case describe(SType)     // 栈顶 → String（插值与 print 的描述，按静态类型格式化 Optional）
    case concat(Int)         // 连接 n 个字符串
    case matchEnumCase(type: Int, caseIndex: Int)  // pop → Bool
    case matchSymbolCase(String)                   // pop → Bool（未知枚举类型时按 case 名匹配）
    case rangeContains       // [range, value] → Bool（switch 区间模式）

    // 控制流
    case jump(Int)
    case jumpIfFalse(Int)
    case jumpIfTrue(Int)
    case jumpIfNil(Int)      // 不弹出
    case jumpIfNotNil(Int)   // 不弹出
    case loop(Int)           // 循环回边：预算与取消检查点
    case iterMake(Int)
    case iterNext(slot: Int, exit: Int)

    // 调用
    case call(function: Int, argc: Int)
    case callValue(argc: Int)
    case callMethod(name: String, argc: Int)
    case callBuiltin(name: String, labels: [String?])
    case construct(type: Int, fields: [Int])
    case callInit(type: Int, function: Int, argc: Int)
    case makeClosure(function: Int, captures: [CaptureSource])
    case ret

    // 集合
    case makeArray(Int)
    case makeDict(Int)
    case makeTuple([String?])
    /// 由 n 个字段值直接构造记录（默认值函数使用）
    case makeRecord(type: Int, count: Int)

    // 视图构建（@ViewBuilder 专门支持）
    case makeViewGroup(Int)
    case wrapConditional(Int)

    // 诊断
    case trap(String)
    case unsupported(message: String, capabilityID: String)
}
