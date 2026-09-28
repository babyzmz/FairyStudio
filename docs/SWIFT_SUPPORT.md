# Fairy Studio Swift 支持范围（SwiftRuntime 0.1.0）

> 本文件由 capability catalog 生成（`swift run fairy-run catalog --markdown`），请勿手改；
> 测试 `supportDocMatchesCatalog` 保证与 `SwiftRuntimeEngine.catalog` 一致。
>
> 级别：supported = 已实现且有测试覆盖；partial = 已实现但有限制（见备注）；unsupported = 合法 Swift/SwiftUI，但运行时尚不支持，
> 使用时产生 `unsupportedSyntax` / `unsupportedAPI` 诊断并附带对应的 capabilityID。

## 语言语法（supported 56 / partial 13 / unsupported 29）

| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |
|---|---|---|---|---|---|
| `syntax.literal.int` | 整数字面量（十/十六/二进制、下划线） | **supported** | — | `differential/01_int_arithmetic.swift` `differential/30_tuples_ternary_misc.swift` |  |
| `syntax.literal.double` | 浮点字面量 | **supported** | — | `differential/02_double_arithmetic.swift` |  |
| `syntax.literal.string` | 字符串字面量与转义 | **supported** | — | `differential/03_strings.swift` |  |
| `syntax.literal.bool` | 布尔字面量 | **supported** | — | `differential/04_bool_logic.swift` |  |
| `syntax.stringInterpolation` | 字符串插值 \(x) | **supported** | — | `differential/03_strings.swift` `differential/23_print_formatting.swift` | 不支持带参数的插值（如 \(x, format:)） |
| `syntax.multilineString` | 多行字符串字面量 | **supported** | — | `differential/03_strings.swift` |  |
| `syntax.let` | let 常量 | **supported** | — | `differential/05_let_var_scope.swift` |  |
| `syntax.var` | var 变量 | **supported** | — | `differential/05_let_var_scope.swift` |  |
| `syntax.typeAnnotation` | 类型标注 | **supported** | — | `differential/05_let_var_scope.swift` | Int/Double/Bool/String/Character(按 String)/CGFloat(按 Double)/数组/字典/Optional/函数类型/元组/用户类型 |
| `syntax.operator.arithmetic` | 算术运算 + - * / % | **supported** | — | `differential/01_int_arithmetic.swift` `differential/02_double_arithmetic.swift` | Int 溢出、除零为受控 runtimeTrap；Int 与 Double 不隐式转换（字面量按上下文定型） |
| `syntax.operator.comparison` | 比较运算 | **supported** | — | `differential/04_bool_logic.swift` |  |
| `syntax.operator.logical` | 逻辑运算与短路 && \|\| ! | **supported** | — | `differential/04_bool_logic.swift` |  |
| `syntax.operator.compoundAssignment` | 复合赋值 += -= *= /= %= … | **supported** | — | `differential/01_int_arithmetic.swift` |  |
| `syntax.operator.bitwise` | 位运算 & \| ^ << >> ~ | **supported** | — | `differential/01_int_arithmetic.swift` |  |
| `syntax.operator.wrapping` | 溢出运算 &+ &- &* | **supported** | — | `differential/01_int_arithmetic.swift` |  |
| `syntax.operator.ternary` | 三元运算 ?: | **supported** | — | `differential/30_tuples_ternary_misc.swift` |  |
| `syntax.operator.nilCoalescing` | 空合运算 ?? | **supported** | — | `differential/21_optionals.swift` |  |
| `syntax.range` | 区间 ..< 与 ...（双侧）与单侧区间 | **supported** | — | `differential/06_ranges_for.swift` `differential/36_w3_partial_range.swift` | Int 区间；单侧（a[..<n]、a[n...]）支持构造、数组下标切片、打印与比较，for-in 单侧报错；Double 区间尚不支持 |
| `syntax.if` | if / else if / else | **supported** | — | `differential/07_if_guard.swift` |  |
| `syntax.guard` | guard … else | **supported** | — | `differential/07_if_guard.swift` |  |
| `syntax.switch` | switch（字面量、区间、多值、枚举 case、关联值模式、default） | **supported** | — | `differential/08_switch_literals.swift` `differential/09_enums.swift` `differential/32_w3_enum_associated.swift` | 枚举/Bool 做穷尽性检查；不支持 fallthrough、元组模式 |
| `syntax.switch.where` | switch case 的 where 子句 | partial | — | `differential/08_switch_literals.swift` `differential/32_w3_enum_associated.swift` |  |
| `syntax.switch.valueBinding` | case let x / 关联值绑定 | partial | — | `differential/08_switch_literals.swift` `differential/32_w3_enum_associated.swift` | 支持绑定整个值与 .case(let x[, …])（含标签校验、字面量混合、case let 前缀） |
| `syntax.forIn` | for-in（区间、数组、字典、字符串、stride） | **supported** | — | `differential/06_ranges_for.swift` `differential/20_dictionaries.swift` |  |
| `syntax.forIn.where` | for-in where | **supported** | — | `differential/06_ranges_for.swift` |  |
| `syntax.forIn.tuplePattern` | for (i, x) in … 元组解构 | partial | — | `differential/06_ranges_for.swift` `differential/20_dictionaries.swift` | 只在 for-in 中支持一层元组模式 |
| `syntax.while` | while / while let | **supported** | — | `differential/10_while_repeat.swift` |  |
| `syntax.repeatWhile` | repeat-while | **supported** | — | `differential/10_while_repeat.swift` |  |
| `syntax.break` | break | **supported** | — | `differential/10_while_repeat.swift` |  |
| `syntax.continue` | continue | **supported** | — | `differential/10_while_repeat.swift` |  |
| `syntax.function` | 函数声明与返回值 | **supported** | — | `differential/11_functions.swift` |  |
| `syntax.function.argumentLabels` | 参数标签与重载 | **supported** | — | `differential/11_functions.swift` |  |
| `syntax.function.defaultArguments` | 默认参数值 | partial | — | `differential/11_functions.swift` | 静态解析的调用支持；嵌套函数与动态分派调用不支持默认值 |
| `syntax.function.nested` | 嵌套函数 | **supported** | — | `differential/11_functions.swift` `differential/13_closures_capture.swift` |  |
| `syntax.recursion` | 递归 | **supported** | — | `differential/12_recursion.swift` `deepRecursionStopsAtMaxCallDepth` |  |
| `syntax.functionReference` | 函数作为值（square、+、>、action: method） | partial | — | `differential/11_functions.swift` `differential/14_closures_syntax.swift` | 支持顶层函数、运算符、无参实例方法引用；不支持带标签引用 f(x:) |
| `syntax.closure` | 闭包字面量 | **supported** | — | `differential/13_closures_capture.swift` `differential/14_closures_syntax.swift` |  |
| `syntax.closure.trailing` | 尾随闭包 | **supported** | — | `differential/14_closures_syntax.swift` |  |
| `syntax.closure.multipleTrailing` | 多个尾随闭包 | partial | — | — | 用于 Button { } label: { } 等内建视图 |
| `syntax.closure.shorthandArgs` | $0 简写参数 | **supported** | — | `differential/14_closures_syntax.swift` |  |
| `syntax.closure.captureByReference` | 按引用捕获 var / 按值捕获 let | **supported** | — | `counterClosureCapturesVarByReference` `letCaptureIsByValueAndLoopBindingsAreFresh` `differential/13_closures_capture.swift` |  |
| `syntax.struct` | struct | **supported** | — | `differential/15_struct_basics.swift` |  |
| `syntax.struct.memberwiseInit` | 逐一成员构造器 | **supported** | — | `differential/15_struct_basics.swift` |  |
| `syntax.struct.init` | 自定义 init | **supported** | — | `differential/17_struct_init_static.swift` | 不检查确定初始化；不支持 self.init 委托 |
| `syntax.struct.computedProperty` | 计算属性（只读） | **supported** | — | `differential/15_struct_basics.swift` |  |
| `syntax.struct.method` | 实例方法 | **supported** | — | `differential/15_struct_basics.swift` |  |
| `syntax.struct.mutating` | mutating 方法 | **supported** | — | `differential/15_struct_basics.swift` `mutatingMethodThroughStateAndNestedPaths` |  |
| `syntax.struct.static` | static 属性与方法 | **supported** | — | `differential/17_struct_init_static.swift` |  |
| `syntax.struct.valueSemantics` | 值语义复制 | **supported** | — | `structCopyIsIndependent` `arrayCopyIsIndependent` `differential/16_value_semantics.swift` |  |
| `syntax.enum` | enum（无关联值） | **supported** | — | `differential/09_enums.swift` |  |
| `syntax.enum.rawValue` | enum 原始值（Int/String/Double） | **supported** | — | `differential/09_enums.swift` |  |
| `syntax.enum.caseIterable` | CaseIterable.allCases | **supported** | — | `differential/09_enums.swift` |  |
| `syntax.enum.methods` | enum 方法、计算属性、mutating | **supported** | — | `differential/09_enums.swift` |  |
| `syntax.extension` | 同模块 extension（方法、计算属性、init） | **supported** | — | `differential/17_struct_init_static.swift` `allFileOrdersProduceSameScriptOutput` |  |
| `syntax.optional` | Optional | **supported** | — | `differential/21_optionals.swift` | 运行期扁平表示，嵌套可选（Int??）不区分 |
| `syntax.optional.binding` | if let / guard let / while let | **supported** | — | `differential/07_if_guard.swift` `differential/21_optionals.swift` |  |
| `syntax.optional.chaining` | 可选链 ?. | **supported** | — | `differential/21_optionals.swift` `differential/16_value_semantics.swift` |  |
| `syntax.optional.forceUnwrap` | 强制解包 !（nil 时受控 trap） | **supported** | — | `differential/28_trap_force_unwrap_nil.swift` `runtimeTrapsBecomeDiagnostics` |  |
| `syntax.tuple` | 元组值、标签访问与解构声明 | partial | — | `differential/11_functions.swift` `differential/30_tuples_ternary_misc.swift` `differential/31_w3_tuple.swift` | 支持 let/var 解构声明（扁平一层，通配符 _ 可跳过）；不支持解构赋值 |
| `syntax.keyPath` | KeyPath \.self / \.prop | partial | — | `forEachOverIdentifiableAndRange` | 只用于 ForEach/List 的 id: |
| `syntax.topLevelCode` | main.swift 顶层语句（脚本入口） | **supported** | — | `scriptEntryPrintsToConsoleAndCompletes` `topLevelStatementsOutsideMainSwiftIsError` |  |
| `syntax.mainApp` | @main App + WindowGroup | partial | — | `counterViaMainAppEntry` `multipleMainAppsIsError` | 只支持单个 WindowGroup { 根视图 }；App 内不能有存储属性 |
| `syntax.import` | import SwiftUI / Foundation | partial | — | — | 其他模块产生 unsupportedAPI |
| `syntax.accessControl` | private / fileprivate 跨文件可见性 | partial | — | `crossFilePrivateMemberIsNameResolutionError` `crossFilePrivateFunctionIsNameResolutionError` `privateSetterBlocksCrossFileMutation` | private 与 fileprivate 都按"仅本文件可见"处理 |
| `syntax.class` | class 与继承 | unsupported | — | — |  |
| `syntax.protocol` | 自定义协议 / 其他协议遵循 / some·any 类型 | unsupported | — | — | 可遵循：View、App、Identifiable、Hashable、Equatable、CaseIterable、CustomStringConvertible、Sendable |
| `syntax.generics` | 泛型 | unsupported | — | — |  |
| `syntax.actor` | actor | unsupported | — | — |  |
| `syntax.asyncAwait` | async / await | unsupported | — | — |  |
| `syntax.errorHandling` | throws / try / do-catch | unsupported | — | — |  |
| `syntax.macro` | 宏（@Observable、#Preview …） | unsupported | — | — |  |
| `syntax.attribute` | @State/@Binding/@main/@ViewBuilder/@discardableResult 之外的属性 | unsupported | — | — |  |
| `syntax.tuplePattern` | 元组解构声明 | partial | — | `differential/31_w3_tuple.swift` | 支持 let/var 解构声明（扁平一层）；不支持解构赋值、switch/if-case 元组模式 |
| `syntax.typeCasting` | as / as? / is | unsupported | — | — |  |
| `syntax.typealias` | typealias | unsupported | — | — |  |
| `syntax.defer` | defer | unsupported | — | — |  |
| `syntax.fallthrough` | fallthrough | unsupported | — | — |  |
| `syntax.labeledStatement` | 带标签语句 / 带标签 break·continue | unsupported | — | — |  |
| `syntax.operatorDecl` | 自定义运算符 / 运算符函数 | unsupported | — | — |  |
| `syntax.subscriptDecl` | 自定义 subscript | unsupported | — | — |  |
| `syntax.nestedType` | 嵌套类型 / 局部类型 | unsupported | — | — |  |
| `syntax.ifExpression` | if/switch 作为表达式 | unsupported | — | — |  |
| `syntax.ifConfig` | #if 条件编译 | unsupported | — | — |  |
| `syntax.availability` | #available | unsupported | — | — |  |
| `syntax.function.inout` | inout 参数 | **supported** | — | `differential/34_w3_inout.swift` | 具名函数/方法/init 调用（copy-in/copy-out，&实参按地址回写）；函数值与动态分派调用不支持；同一变量多传不做独占检查 |
| `syntax.function.variadic` | 可变参数 | unsupported | — | — |  |
| `syntax.enum.associatedValues` | 带关联值的 enum | **supported** | — | `differential/32_w3_enum_associated.swift` | 构造（显式 R.ok(…)/隐式 .ok(…)，标签校验）+ switch/if-case 模式匹配（含绑定、字面量、where）；带关联值的 case 无 allCases/rawValue |
| `syntax.struct.computedSetter` | 计算属性 setter | **supported** | — | `differential/33_w3_setter_didset.swift` | get/set（set 用 newValue，可自定义参数名）；静态计算属性 setter 不支持；计算属性上的 mutating 方法调用不支持 |
| `syntax.struct.propertyObservers` | didSet 属性观察器 | partial | — | `differential/33_w3_setter_didset.swift` | 存储属性/全局/static 的 didSet（赋值后触发一次，init 内不触发，自体钳制不递归）；mutating 方法整体写回与 $ 绑定写入不触发；willSet 忽略并警告 |
| `syntax.struct.lazy` | lazy 属性 | unsupported | — | — |  |
| `syntax.struct.failableInit` | init? | unsupported | — | — |  |
| `syntax.closure.captureList` | 闭包捕获列表 [x] | unsupported | — | — |  |
| `syntax.extension.stdlibType` | 扩展标准库/系统类型 | unsupported | — | — |  |
| `syntax.globalComputed` | 全局/局部计算变量 | unsupported | — | — |  |
| `syntax.implicitMemberCall` | 隐式成员调用 .foo(…)（如 .system(size:)） | unsupported | — | — |  |
| `syntax.declaration` | 其他声明 | unsupported | — | — |  |
| `syntax.statement` | 其他语句 | unsupported | — | — |  |
| `syntax.expression` | 其他表达式 | unsupported | — | — |  |

## 标准库（supported 72 / partial 67 / unsupported 66）

| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |
|---|---|---|---|---|---|
| `stdlib.Array.append` | Array.append | **supported** | `append(_:) / append(contentsOf:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.insert` | Array.insert | **supported** | `insert(_:at:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.remove` | Array.remove | **supported** | `remove(at:)` | `differential/18_arrays.swift` | 越界为受控 trap |
| `stdlib.Array.removeLast` | Array.removeLast | **supported** | `removeLast()` | `differential/18_arrays.swift` `runtimeTrapsBecomeDiagnostics` |  |
| `stdlib.Array.removeFirst` | Array.removeFirst | **supported** | `removeFirst()` | `differential/18_arrays.swift` |  |
| `stdlib.Array.removeAll` | Array.removeAll | **supported** | `removeAll() / removeAll(where:)` | `differential/18_arrays.swift` `forEachReorderKeepsRowStateWithItsID` |  |
| `stdlib.Array.popLast` | Array.popLast | **supported** | `popLast()` | `differential/10_while_repeat.swift` |  |
| `stdlib.Array.sort` | Array.sort | **supported** | `sort() / sort(by:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.reverse` | Array.reverse | **supported** | `reverse()` | `differential/18_arrays.swift` |  |
| `stdlib.Array.swapAt` | Array.swapAt | **supported** | `swapAt(_:_:)` | `differential/18_arrays.swift` `differential/24_algorithms.swift` |  |
| `stdlib.Array.contains` | Array.contains | **supported** | `contains(_:) / contains(where:)` | `differential/18_arrays.swift` `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.allSatisfy` | Array.allSatisfy | **supported** | `allSatisfy(_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.map` | Array.map | **supported** | `map(_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.compactMap` | Array.compactMap | **supported** | `compactMap(_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.filter` | Array.filter | **supported** | `filter(_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.forEach` | Array.forEach | **supported** | `forEach(_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.reduce` | Array.reduce | **supported** | `reduce(_:_:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.sorted` | Array.sorted | **supported** | `sorted() / sorted(by:)` | `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.reversed` | Array.reversed | **supported** | `reversed()` | `differential/06_ranges_for.swift` `differential/18_arrays.swift` | 返回数组 |
| `stdlib.Array.enumerated` | Array.enumerated | **supported** | `enumerated()` | `differential/19_array_higher_order.swift` | 返回 (offset:, element:) 数组 |
| `stdlib.Array.first` | Array.first | **supported** | `first / first(where:)` | `differential/18_arrays.swift` `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.last` | Array.last | **supported** | `last` | `differential/18_arrays.swift` |  |
| `stdlib.Array.firstIndex` | Array.firstIndex | **supported** | `firstIndex(of:) / firstIndex(where:)` | `differential/18_arrays.swift` `differential/19_array_higher_order.swift` |  |
| `stdlib.Array.lastIndex` | Array.lastIndex | partial | `lastIndex(of:)` | — |  |
| `stdlib.Array.min` | Array.min | **supported** | `min() / min(by:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.max` | Array.max | **supported** | `max() / max(by:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.count` | Array.count | **supported** | `count / count(where:)` | `differential/18_arrays.swift` |  |
| `stdlib.Array.isEmpty` | Array.isEmpty | **supported** | `isEmpty` | `differential/18_arrays.swift` |  |
| `stdlib.Array.indices` | Array.indices | **supported** | `indices` | `differential/18_arrays.swift` |  |
| `stdlib.Array.startIndex` | Array.startIndex | partial | `startIndex` | — |  |
| `stdlib.Array.endIndex` | Array.endIndex | partial | `endIndex` | — |  |
| `stdlib.Array.joined` | Array.joined | **supported** | `joined(separator:) / joined()` | `differential/03_strings.swift` `differential/24_algorithms.swift` | 仅 [String] |
| `stdlib.Array.prefix` | Array.prefix | partial | `prefix(_:)` | — |  |
| `stdlib.Array.suffix` | Array.suffix | partial | `suffix(_:)` | — |  |
| `stdlib.Array.dropFirst` | Array.dropFirst | partial | `dropFirst() / dropFirst(_:)` | — |  |
| `stdlib.Array.dropLast` | Array.dropLast | partial | `dropLast() / dropLast(_:)` | — |  |
| `stdlib.Array.subscript` | Array.subscript | **supported** | `a[i] / a[range]` | `differential/18_arrays.swift` `differential/27_trap_index_out_of_range.swift` | 越界为受控 trap |
| `stdlib.Array.init` | Array.init | **supported** | `Array(seq) / Array(repeating:count:) / [T]()` | `differential/18_arrays.swift` `differential/06_ranges_for.swift` |  |
| `stdlib.Range.count` | Range.count | **supported** | `count` | `differential/06_ranges_for.swift` |  |
| `stdlib.Range.isEmpty` | Range.isEmpty | partial | `isEmpty` | — |  |
| `stdlib.Range.lowerBound` | Range.lowerBound | **supported** | `lowerBound` | `differential/06_ranges_for.swift` |  |
| `stdlib.Range.upperBound` | Range.upperBound | **supported** | `upperBound` | `differential/06_ranges_for.swift` |  |
| `stdlib.Range.first` | Range.first | partial | `first` | — |  |
| `stdlib.Range.last` | Range.last | partial | `last` | — |  |
| `stdlib.Range.contains` | Range.contains | **supported** | `contains(_:)` | `differential/06_ranges_for.swift` |  |
| `stdlib.Range.map` | Range.map | **supported** | `map(_:)` | `differential/12_recursion.swift` | 序列方法：物化为数组（受 maxCollectionElements 约束） |
| `stdlib.Range.filter` | Range.filter | **supported** | `filter(_:)` | `differential/24_algorithms.swift` |  |
| `stdlib.Range.reversed` | Range.reversed | **supported** | `reversed()` | `differential/06_ranges_for.swift` |  |
| `stdlib.Range.reduce` | Range.reduce | partial | `reduce(_:_:)` | — |  |
| `stdlib.Range.forEach` | Range.forEach | partial | `forEach(_:)` | — |  |
| `stdlib.Range.allSatisfy` | Range.allSatisfy | partial | `allSatisfy(_:)` | — |  |
| `stdlib.Range.compactMap` | Range.compactMap | partial | `compactMap(_:)` | — |  |
| `stdlib.Range.sorted` | Range.sorted | partial | `sorted()` | — |  |
| `stdlib.Range.enumerated` | Range.enumerated | partial | `enumerated()` | — |  |
| `stdlib.Range.firstIndex` | Range.firstIndex | partial | `firstIndex(of:)` | — |  |
| `stdlib.Range.lastIndex` | Range.lastIndex | partial | `lastIndex(of:)` | — |  |
| `stdlib.Range.min` | Range.min | partial | `min()` | — |  |
| `stdlib.Range.max` | Range.max | partial | `max()` | — |  |
| `stdlib.Range.joined` | Range.joined | partial | `joined()` | — |  |
| `stdlib.Range.prefix` | Range.prefix | partial | `prefix(_:)` | — |  |
| `stdlib.Range.suffix` | Range.suffix | partial | `suffix(_:)` | — |  |
| `stdlib.Range.dropFirst` | Range.dropFirst | partial | `dropFirst()` | — |  |
| `stdlib.Range.dropLast` | Range.dropLast | partial | `dropLast()` | — |  |
| `stdlib.String.count` | String.count | **supported** | `count` | `differential/03_strings.swift` | 按字素簇计数 |
| `stdlib.String.isEmpty` | String.isEmpty | **supported** | `isEmpty` | `differential/03_strings.swift` |  |
| `stdlib.String.first` | String.first | partial | `first` | — | Character 以单字符 String 表示 |
| `stdlib.String.last` | String.last | partial | `last` | — |  |
| `stdlib.String.description` | String.description | partial | `description` | — |  |
| `stdlib.String.uppercased` | String.uppercased | **supported** | `uppercased()` | `differential/03_strings.swift` |  |
| `stdlib.String.lowercased` | String.lowercased | **supported** | `lowercased()` | `differential/03_strings.swift` |  |
| `stdlib.String.contains` | String.contains | **supported** | `contains(_:)` | `differential/03_strings.swift` |  |
| `stdlib.String.hasPrefix` | String.hasPrefix | **supported** | `hasPrefix(_:)` | `differential/03_strings.swift` |  |
| `stdlib.String.hasSuffix` | String.hasSuffix | **supported** | `hasSuffix(_:)` | `differential/03_strings.swift` |  |
| `stdlib.String.append` | String.append | **supported** | `append(_:) / +=` | `differential/03_strings.swift` |  |
| `stdlib.String.split` | String.split | **supported** | `split(separator:)` | `differential/03_strings.swift` | 返回 [String] |
| `stdlib.String.components` | String.components | partial | `components(separatedBy:)` | — | Foundation |
| `stdlib.String.replacingOccurrences` | String.replacingOccurrences | **supported** | `replacingOccurrences(of:with:)` | `differential/03_strings.swift` |  |
| `stdlib.String.trimmingCharacters` | String.trimmingCharacters | **supported** | `trimmingCharacters(in:)` | `differential/03_strings.swift` | 只去除空白与换行 |
| `stdlib.String.reversed` | String.reversed | **supported** | `reversed()` | `differential/03_strings.swift` |  |
| `stdlib.String.prefix` | String.prefix | partial | `prefix(_:)` | — |  |
| `stdlib.String.suffix` | String.suffix | partial | `suffix(_:)` | — |  |
| `stdlib.String.dropFirst` | String.dropFirst | partial | `dropFirst()` | — |  |
| `stdlib.String.dropLast` | String.dropLast | partial | `dropLast()` | — |  |
| `stdlib.String.removeAll` | String.removeAll | partial | `removeAll()` | — |  |
| `stdlib.String.removeLast` | String.removeLast | partial | `removeLast()` | — |  |
| `stdlib.String.removeFirst` | String.removeFirst | partial | `removeFirst()` | — |  |
| `stdlib.String.filter` | String.filter | partial | `filter(_:)` | — |  |
| `stdlib.String.map` | String.map | partial | `map(_:)` | — |  |
| `stdlib.String.sorted` | String.sorted | partial | `sorted()` | — |  |
| `stdlib.String.enumerated` | String.enumerated | partial | `enumerated()` | — |  |
| `stdlib.String.init` | String.init | **supported** | `String(x) / String(describing:) / String(repeating:count:)` | `differential/03_strings.swift` `differential/22_conversions.swift` |  |
| `stdlib.String.subscript` | String.subscript | unsupported | `s[i]（String.Index）` | — |  |
| `stdlib.Dictionary.subscript` | Dictionary.subscript | **supported** | `d[k] / d[k, default:]` | `differential/20_dictionaries.swift` `differential/29_trap_missing_dict_key.swift` | 赋 nil 删除键 |
| `stdlib.Dictionary.count` | Dictionary.count | **supported** | `count` | `differential/20_dictionaries.swift` |  |
| `stdlib.Dictionary.isEmpty` | Dictionary.isEmpty | **supported** | `isEmpty` | `differential/20_dictionaries.swift` |  |
| `stdlib.Dictionary.keys` | Dictionary.keys | **supported** | `keys` | `differential/20_dictionaries.swift` | 返回数组；遍历顺序为插入顺序（Swift 原生顺序不确定） |
| `stdlib.Dictionary.values` | Dictionary.values | **supported** | `values` | `differential/20_dictionaries.swift` |  |
| `stdlib.Dictionary.removeValue` | Dictionary.removeValue | **supported** | `removeValue(forKey:)` | `differential/20_dictionaries.swift` |  |
| `stdlib.Dictionary.updateValue` | Dictionary.updateValue | partial | `updateValue(_:forKey:)` | — |  |
| `stdlib.Dictionary.removeAll` | Dictionary.removeAll | partial | `removeAll()` | — |  |
| `stdlib.Dictionary.mapValues` | Dictionary.mapValues | partial | `mapValues(_:)` | — |  |
| `stdlib.Dictionary.filter` | Dictionary.filter | partial | `filter(_:)` | — |  |
| `stdlib.Dictionary.sorted` | Dictionary.sorted | **supported** | `sorted(by:)` | `differential/20_dictionaries.swift` | 元素为 (key:, value:) 元组 |
| `stdlib.Dictionary.map` | Dictionary.map | partial | `map(_:)` | — |  |
| `stdlib.Dictionary.forEach` | Dictionary.forEach | partial | `forEach(_:)` | — |  |
| `stdlib.Dictionary.reduce` | Dictionary.reduce | partial | `reduce(_:_:)` | — |  |
| `stdlib.Dictionary.contains` | Dictionary.contains | partial | `contains(where:)` | — |  |
| `stdlib.Dictionary.first` | Dictionary.first | partial | `first(where:)` | — |  |
| `stdlib.Dictionary.compactMap` | Dictionary.compactMap | partial | `compactMap(_:)` | — |  |
| `stdlib.Dictionary.allSatisfy` | Dictionary.allSatisfy | partial | `allSatisfy(_:)` | — |  |
| `stdlib.Dictionary.min` | Dictionary.min | partial | `min(by:)` | — |  |
| `stdlib.Dictionary.max` | Dictionary.max | partial | `max(by:)` | — |  |
| `stdlib.Int.init` | Int.init | **supported** | `Int(String) → Int? / Int(Double)` | `differential/22_conversions.swift` | Int(Double) 对 NaN/无穷/越界为受控 trap |
| `stdlib.Int.isMultiple` | Int.isMultiple | **supported** | `isMultiple(of:)` | `differential/01_int_arithmetic.swift` |  |
| `stdlib.Int.signum` | Int.signum | partial | `signum()` | — |  |
| `stdlib.Int.description` | Int.description | partial | `description` | — |  |
| `stdlib.Int.magnitude` | Int.magnitude | partial | `magnitude` | — |  |
| `stdlib.Double.init` | Double.init | **supported** | `Double(Int) / Double(String) → Double?` | `differential/22_conversions.swift` `differential/02_double_arithmetic.swift` |  |
| `stdlib.Double.rounded` | Double.rounded | **supported** | `rounded()` | `differential/02_double_arithmetic.swift` |  |
| `stdlib.Double.squareRoot` | Double.squareRoot | **supported** | `squareRoot()` | `differential/02_double_arithmetic.swift` |  |
| `stdlib.Double.truncatingRemainder` | Double.truncatingRemainder | **supported** | `truncatingRemainder(dividingBy:)` | `differential/02_double_arithmetic.swift` |  |
| `stdlib.Double.description` | Double.description | partial | `description` | — |  |
| `stdlib.Double.isNaN` | Double.isNaN | partial | `isNaN` | — |  |
| `stdlib.Double.isInfinite` | Double.isInfinite | partial | `isInfinite` | — |  |
| `stdlib.Double.isFinite` | Double.isFinite | partial | `isFinite` | — |  |
| `stdlib.Bool.toggle` | Bool.toggle | **supported** | `toggle()` | `differential/04_bool_logic.swift` |  |
| `stdlib.Bool.description` | Bool.description | partial | `description` | — |  |
| `stdlib.print` | print | **supported** | `print(_:..., separator:terminator:)` | `differential/23_print_formatting.swift` | 输出为 .console(.stdout, …) 事件；格式与 Swift description/debugDescription 一致 |
| `stdlib.String.format` | String(format:) | **supported** | `String(format:_:...)（仅 %.Nf 与 %%)` | `differential/35_w3_format_date.swift` `stringFormatIntArgActsAsDouble` | Int 实参按 Double 格式化（Swift 原生要求 Double）；其他占位符报 unsupportedAPI |
| `stdlib.Date` | Date | **supported** | `Date() / Date.now（只读）` | `differential/35_w3_format_date.swift` | 只读基础：description/打印/==/</比较；无运算与格式化器；时钟读取是允许的非确定性（随机/网络仍一律拒绝） |
| `stdlib.abs` | abs | **supported** | `abs(_:)` | `differential/01_int_arithmetic.swift` `differential/22_conversions.swift` |  |
| `stdlib.min` | min | **supported** | `min(_:_:...)` | `differential/01_int_arithmetic.swift` |  |
| `stdlib.max` | max | **supported** | `max(_:_:...)` | `differential/22_conversions.swift` |  |
| `stdlib.stride` | stride | **supported** | `stride(from:to:by:) / stride(from:through:by:)` | `differential/06_ranges_for.swift` | 物化为数组 |
| `stdlib.fatalError` | fatalError | partial | `fatalError(_:)` | — | 作为受控 runtimeTrap |
| `stdlib.precondition` | precondition | partial | `precondition(_:_:)` | — |  |
| `stdlib.assert` | assert | partial | `assert(_:_:)` | — |  |
| `stdlib.math` | sqrt/floor/ceil/round/sin/cos/exp/log/pow | partial | — | — | Foundation 函数，仅 Double |
| `stdlib.CGFloat` | CGFloat | partial | — | — | 按 Double 处理 |
| `stdlib.Character` | Character | partial | — | — | 按单字符 String 处理 |
| `stdlib.ActionSheet` | ActionSheet | unsupported | — | — |  |
| `stdlib.Alert` | Alert | unsupported | — | — |  |
| `stdlib.Angle` | Angle | unsupported | — | — |  |
| `stdlib.Animation` | Animation | unsupported | — | — |  |
| `stdlib.AttributedString` | AttributedString | unsupported | — | — |  |
| `stdlib.Bundle` | Bundle | unsupported | — | — |  |
| `stdlib.CGPoint` | CGPoint | unsupported | — | — |  |
| `stdlib.CGRect` | CGRect | unsupported | — | — |  |
| `stdlib.CGSize` | CGSize | unsupported | — | — |  |
| `stdlib.Calendar` | Calendar | unsupported | — | — |  |
| `stdlib.Data` | Data | unsupported | — | — |  |
| `stdlib.DateFormatter` | DateFormatter | unsupported | — | — |  |
| `stdlib.DispatchQueue` | DispatchQueue | unsupported | — | — |  |
| `stdlib.DocumentGroup` | DocumentGroup | unsupported | — | — |  |
| `stdlib.Error` | Error | unsupported | — | — |  |
| `stdlib.FileManager` | FileManager | unsupported | — | — |  |
| `stdlib.Float` | Float | unsupported | — | — |  |
| `stdlib.Float32` | Float32 | unsupported | — | — |  |
| `stdlib.Float64` | Float64 | unsupported | — | — |  |
| `stdlib.GridItem` | GridItem | unsupported | — | — |  |
| `stdlib.Int16` | Int16 | unsupported | — | — |  |
| `stdlib.Int32` | Int32 | unsupported | — | — |  |
| `stdlib.Int64` | Int64 | unsupported | — | — |  |
| `stdlib.Int8` | Int8 | unsupported | — | — |  |
| `stdlib.JSONDecoder` | JSONDecoder | unsupported | — | — |  |
| `stdlib.JSONEncoder` | JSONEncoder | unsupported | — | — |  |
| `stdlib.Locale` | Locale | unsupported | — | — |  |
| `stdlib.NSColor` | NSColor | unsupported | — | — |  |
| `stdlib.NotificationCenter` | NotificationCenter | unsupported | — | — |  |
| `stdlib.NumberFormatter` | NumberFormatter | unsupported | — | — |  |
| `stdlib.ObservableObject` | ObservableObject | unsupported | — | — |  |
| `stdlib.ProcessInfo` | ProcessInfo | unsupported | — | — |  |
| `stdlib.Result` | Result | unsupported | — | — |  |
| `stdlib.Set` | Set | unsupported | — | — |  |
| `stdlib.Settings` | Settings | unsupported | — | — |  |
| `stdlib.Substring` | Substring | unsupported | — | — |  |
| `stdlib.Task` | Task | unsupported | — | — |  |
| `stdlib.Thread` | Thread | unsupported | — | — |  |
| `stdlib.Timer` | Timer | unsupported | — | — |  |
| `stdlib.UIColor` | UIColor | unsupported | — | — |  |
| `stdlib.UInt` | UInt | unsupported | — | — |  |
| `stdlib.UInt16` | UInt16 | unsupported | — | — |  |
| `stdlib.UInt32` | UInt32 | unsupported | — | — |  |
| `stdlib.UInt64` | UInt64 | unsupported | — | — |  |
| `stdlib.UInt8` | UInt8 | unsupported | — | — |  |
| `stdlib.URL` | URL | unsupported | — | — |  |
| `stdlib.UUID` | UUID | unsupported | — | — |  |
| `stdlib.UserDefaults` | UserDefaults | unsupported | — | — |  |
| `stdlib.debugPrint` | debugPrint(…) | unsupported | — | — |  |
| `stdlib.dump` | dump(…) | unsupported | — | — |  |
| `stdlib.exit` | exit(…) | unsupported | — | — |  |
| `stdlib.readLine` | readLine(…) | unsupported | — | — |  |
| `stdlib.repeatElement` | repeatElement(…) | unsupported | — | — |  |
| `stdlib.sequence` | sequence(…) | unsupported | — | — |  |
| `stdlib.swap` | swap(…) | unsupported | — | — |  |
| `stdlib.type` | type(…) | unsupported | — | — |  |
| `stdlib.withAnimation` | withAnimation(…) | unsupported | — | — |  |
| `stdlib.zip` | zip(…) | unsupported | — | — |  |
| `stdlib.Int.random` | Int.random… | unsupported | — | — | 非确定性 API |
| `stdlib.Double.random` | Double.random… | unsupported | — | — | 非确定性 API |
| `stdlib.Bool.random` | Bool.random… | unsupported | — | — | 非确定性 API |
| `stdlib.String.random` | String.random… | unsupported | — | — | 非确定性 API |
| `stdlib.Array.random` | Array.random… | unsupported | — | — | 非确定性 API |
| `stdlib.Bool.init` | Bool(…) | unsupported | — | — |  |
| `stdlib.Character.init` | Character(…) | unsupported | — | — |  |

## 属性包装器（supported 3 / partial 0 / unsupported 13）

| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |
|---|---|---|---|---|---|
| `propertyWrapper.State` | @State | **supported** | — | `counterRootViewRendersAndIncrementsOnAction` `forEachReorderKeepsRowStateWithItsID` `bindingPassedToChildWritesParentState` | 键 = 视图身份路径 + 字段名；视图重建不重新初始化；视图离开层级后丢弃 |
| `propertyWrapper.Binding` | @Binding | **supported** | — | `bindingPassedToChildWritesParentState` |  |
| `propertyWrapper.Binding.projection` | $state / $state.field / $array[i] | **supported** | — | `textFieldSetBindingWritesBack` `bindingPassedToChildWritesParentState` |  |
| `propertyWrapper.AppStorage` | @AppStorage | unsupported | — | — |  |
| `propertyWrapper.Bindable` | @Bindable | unsupported | — | — |  |
| `propertyWrapper.Environment` | @Environment | unsupported | — | — |  |
| `propertyWrapper.EnvironmentObject` | @EnvironmentObject | unsupported | — | — |  |
| `propertyWrapper.FocusState` | @FocusState | unsupported | — | — |  |
| `propertyWrapper.GestureState` | @GestureState | unsupported | — | — |  |
| `propertyWrapper.Namespace` | @Namespace | unsupported | — | — |  |
| `propertyWrapper.Observable` | @Observable | unsupported | — | — |  |
| `propertyWrapper.ObservedObject` | @ObservedObject | unsupported | — | — |  |
| `propertyWrapper.Published` | @Published | unsupported | — | — |  |
| `propertyWrapper.Query` | @Query | unsupported | — | — |  |
| `propertyWrapper.SceneStorage` | @SceneStorage | unsupported | — | — |  |
| `propertyWrapper.StateObject` | @StateObject | unsupported | — | — |  |

## SwiftUI 视图（supported 24 / partial 5 / unsupported 38）

| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |
|---|---|---|---|---|---|
| `view.Text` | Text | **supported** | `Text(_: String)` | `counterRootViewRendersAndIncrementsOnAction` |  |
| `view.Button` | Button | **supported** | `Button(_:action:) / Button(action:label:) / Button(_:role:action:)` | `counterRootViewRendersAndIncrementsOnAction` `closureEscapesIntoButtonAndMutatesState` |  |
| `view.VStack` | VStack | **supported** | `VStack(alignment:spacing:content:)` | `counterRootViewRendersAndIncrementsOnAction` |  |
| `view.HStack` | HStack | **supported** | `HStack(alignment:spacing:content:)` | `counterRootViewRendersAndIncrementsOnAction` |  |
| `view.ZStack` | ZStack | **supported** | `ZStack(alignment:content:)` | `modifiersMapToRenderModifiers` |  |
| `view.Spacer` | Spacer | **supported** | `Spacer(minLength:)` | `modifiersMapToRenderModifiers` |  |
| `view.Divider` | Divider | **supported** | — | `forEachReorderKeepsRowStateWithItsID` |  |
| `view.TextField` | TextField | **supported** | `TextField(_:text:)` | `textFieldSetBindingWritesBack` |  |
| `view.SecureField` | SecureField | partial | `SecureField(_:text:)` | — |  |
| `view.Toggle` | Toggle | **supported** | `Toggle(_:isOn:) / Toggle(isOn:label:)` | `textFieldSetBindingWritesBack` |  |
| `view.ForEach` | ForEach | **supported** | `ForEach(data, id: \.self \| \.prop) { … } / ForEach(identifiable) / ForEach(range)` | `forEachReorderKeepsRowStateWithItsID` `forEachOverIdentifiableAndRange` | 行身份 = 稳定 id |
| `view.List` | List | **supported** | `List { … } / List(data, id:) { … }` | `conditionalBranchesAndOnAppear` |  |
| `view.NavigationStack` | NavigationStack | **supported** | `NavigationStack { … } / NavigationStack(path: $path) { … }` | `conditionalBranchesAndOnAppear` `navigationPushPopUnbound` `navigationPathBinding` `navigationDestinationLinkForm` | path 绑定支持 [String] 子集；目标 for: 只支持 String/Int；navigationDestination 须写在栈内容内部 |
| `view.ScrollView` | ScrollView | **supported** | `ScrollView([.vertical\|.horizontal]) { … }` | `w3ContainersRender` | 轴向透传；showsIndicators: 形式尚不支持 |
| `view.Group` | Group | **supported** | — | `w3ContainersRender` |  |
| `view.Form` | Form | **supported** | — | `w3ControlsRender` |  |
| `view.Section` | Section | **supported** | `Section([header][footer:]) { … }（字符串）` | `w3ControlsRender` | header/footer 只支持字符串 |
| `view.Image` | Image(systemName:) | **supported** | `Image(systemName:) / Image(_:)` | `w3ControlsRender` | SF Symbols 名称透传；Image("resource") 显示占位（M1 接入项目资源） |
| `view.Slider` | Slider | **supported** | `Slider(value:in:[step:])` | `sliderBindingWritesBack` | value 需 Binding<Double>（VM 双向绑定）；in: 为 Int 闭区间；标签暂不显示 |
| `view.Stepper` | Stepper | **supported** | `Stepper(_:value:[in:])` | `stepperRendersLabelAndBounds` | value 需 Binding<Int>；step:/onIncrement 形式尚不支持 |
| `view.Picker` | Picker | **supported** | `Picker(_:selection:content:)` | `pickerOptionsAndSelection` | selection 需 Binding（String/Int 等可传输类型）；内容为 ForEach/静态 Text 行（每行需 .tag）；样式见 modifier.pickerStyle |
| `view.NavigationLink` | NavigationLink | **supported** | `NavigationLink(_:value:)/NavigationLink(value:label:)/NavigationLink(_:destination:)` | `navigationPushPopUnbound` `navigationPathBinding` `navigationDestinationLinkForm` | value 只支持 String/Int；destination 形式按稳定链接 id 注册 |
| `view.ProgressView` | ProgressView | partial | — | — |  |
| `view.EmptyView` | EmptyView | partial | — | — |  |
| `view.Color` | Color.red / Color(red:green:blue:) | partial | — | `modifiersMapToRenderModifiers` | 只作为修饰符参数使用，不能作为视图 |
| `view.customView` | 自定义 View（struct X: View） | **supported** | — | `counterRootViewRendersAndIncrementsOnAction` `shuffledFileOrderProducesSameRenderTree` |  |
| `view.ViewBuilder` | @ViewBuilder 语句序列与局部 let | **supported** | — | `closureEscapesIntoButtonAndMutatesState` | 专门支持，不是通用 result builder；不支持 for 循环（请用 ForEach） |
| `view.ViewBuilder.if` | @ViewBuilder 中的 if / else / if let | **supported** | — | `conditionalBranchesAndOnAppear` `textFieldSetBindingWritesBack` |  |
| `view.ViewBuilder.switch` | @ViewBuilder 中的 switch | partial | — | — |  |
| `view.AngularGradient` | AngularGradient | unsupported | — | — |  |
| `view.AnyView` | AnyView | unsupported | — | — |  |
| `view.AsyncImage` | AsyncImage | unsupported | — | — |  |
| `view.Canvas` | Canvas | unsupported | — | — |  |
| `view.Capsule` | Capsule | unsupported | — | — |  |
| `view.Circle` | Circle | unsupported | — | — |  |
| `view.ColorPicker` | ColorPicker | unsupported | — | — |  |
| `view.ContentUnavailableView` | ContentUnavailableView | unsupported | — | — |  |
| `view.ControlGroup` | ControlGroup | unsupported | — | — |  |
| `view.DatePicker` | DatePicker | unsupported | — | — |  |
| `view.DisclosureGroup` | DisclosureGroup | unsupported | — | — |  |
| `view.EditButton` | EditButton | unsupported | — | — |  |
| `view.Ellipse` | Ellipse | unsupported | — | — |  |
| `view.Gauge` | Gauge | unsupported | — | — |  |
| `view.GeometryReader` | GeometryReader | unsupported | — | — |  |
| `view.Grid` | Grid | unsupported | — | — |  |
| `view.GridRow` | GridRow | unsupported | — | — |  |
| `view.Label` | Label | unsupported | — | — |  |
| `view.LazyHGrid` | LazyHGrid | unsupported | — | — |  |
| `view.LazyHStack` | LazyHStack | unsupported | — | — |  |
| `view.LazyVGrid` | LazyVGrid | unsupported | — | — |  |
| `view.LazyVStack` | LazyVStack | unsupported | — | — |  |
| `view.LinearGradient` | LinearGradient | unsupported | — | — |  |
| `view.Link` | Link | unsupported | — | — |  |
| `view.Menu` | Menu | unsupported | — | — |  |
| `view.NavigationSplitView` | NavigationSplitView | unsupported | — | — |  |
| `view.OutlineGroup` | OutlineGroup | unsupported | — | — |  |
| `view.Path` | Path | unsupported | — | — |  |
| `view.RadialGradient` | RadialGradient | unsupported | — | — |  |
| `view.Rectangle` | Rectangle | unsupported | — | — |  |
| `view.RoundedRectangle` | RoundedRectangle | unsupported | — | — |  |
| `view.ShareLink` | ShareLink | unsupported | — | — |  |
| `view.TabView` | TabView | unsupported | — | — |  |
| `view.Table` | Table | unsupported | — | — |  |
| `view.TextEditor` | TextEditor | unsupported | — | — |  |
| `view.TimelineView` | TimelineView | unsupported | — | — |  |
| `view.ToolbarItem` | ToolbarItem | unsupported | — | — |  |
| `view.ViewThatFits` | ViewThatFits | unsupported | — | — |  |

## SwiftUI 修饰符（supported 16 / partial 13 / unsupported 37）

| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |
|---|---|---|---|---|---|
| `modifier.padding` | padding | **supported** | `padding() / padding(_: CGFloat) / padding(_: Edge.Set, _: CGFloat?)` | `counterRootViewRendersAndIncrementsOnAction` `modifiersMapToRenderModifiers` |  |
| `modifier.font` | font | **supported** | `font(_: Font.TextStyle)` | `counterRootViewRendersAndIncrementsOnAction` | 只支持文本样式（.title/.body…） |
| `modifier.fontWeight` | fontWeight | partial | `fontWeight(_:)` | — |  |
| `modifier.bold` | bold | **supported** | `bold()` | `modifiersMapToRenderModifiers` |  |
| `modifier.italic` | italic | partial | `italic()` | — |  |
| `modifier.foregroundColor` | foregroundColor | **supported** | `foregroundColor(_: Color)` | `modifiersMapToRenderModifiers` |  |
| `modifier.foregroundStyle` | foregroundStyle | **supported** | `foregroundStyle(_: Color)` | `modifiersMapToRenderModifiers` | 映射为 RenderModifier.foregroundColor；只支持颜色 |
| `modifier.tint` | tint | partial | — | — | 映射为 foregroundColor |
| `modifier.background` | background | **supported** | `background(_: Color)` | `modifiersMapToRenderModifiers` | 只支持颜色 |
| `modifier.frame` | frame | **supported** | `frame(width:height:maxWidth:maxHeight:alignment:)（有序子集）` | `modifiersMapToRenderModifiers` |  |
| `modifier.cornerRadius` | cornerRadius | **supported** | — | `modifiersMapToRenderModifiers` |  |
| `modifier.opacity` | opacity | **supported** | — | `modifiersMapToRenderModifiers` |  |
| `modifier.disabled` | disabled | **supported** | — | `counterRootViewRendersAndIncrementsOnAction` |  |
| `modifier.hidden` | hidden | partial | — | — |  |
| `modifier.navigationTitle` | navigationTitle | **supported** | `navigationTitle(_: String)` | `conditionalBranchesAndOnAppear` |  |
| `modifier.buttonStyle` | buttonStyle | **supported** | `buttonStyle(.bordered \| .borderedProminent \| .plain \| .borderless)` | `counterRootViewRendersAndIncrementsOnAction` |  |
| `modifier.textFieldStyle` | textFieldStyle | partial | — | — |  |
| `modifier.listStyle` | listStyle | partial | — | — |  |
| `modifier.multilineTextAlignment` | multilineTextAlignment | partial | — | — |  |
| `modifier.lineLimit` | lineLimit | partial | — | — |  |
| `modifier.accessibilityLabel` | accessibilityLabel | partial | — | — |  |
| `modifier.tag` | tag | partial | — | — |  |
| `modifier.onAppear` | onAppear | partial | `onAppear(perform:)` | `conditionalBranchesAndOnAppear` | 映射为 ActionID；由宿主发送 .appear(NodeID) 或 .action(ActionID) 触发，运行时不自动触发 |
| `modifier.onDisappear` | onDisappear | partial | — | — | 同 onAppear |
| `modifier.task` | task | partial | — | `taskRunsSyncBodyOnce` | 同步子集：与 onAppear 同机制（宿主触发，不自动执行）；体内 await 按同步执行，不支持取消 |
| `modifier.navigationDestination` | navigationDestination | **supported** | `.navigationDestination(for: String.self/Int.self) { value in … }` | `navigationPathBinding` | B-2：for: 仅 String/Int；须写在栈内容内部（先于目标解析完成注册） |
| `modifier.sheet` | sheet | **supported** | `.sheet(isPresented:onDismiss:content:)` | `sheetPresentDismiss` | B-3：isPresented Binding<Bool> + 内容闭包（捕获 state 读写直达）；手势关闭回传 .action(dismiss) 写 false 并跑 onDismiss；.dismissSheet 强制关闭不触发 onDismiss |
| `modifier.alert` | alert | **supported** | `.alert(_:isPresented:actions:message:)` | `alertButtonsAndAutoDismiss` | B-4：标题 + Binding<Bool> + 一到两个 Button + 可选消息；每个按钮保证 action，点击后自动关闭 |
| `modifier.pickerStyle` | pickerStyle | **supported** | `.pickerStyle(.segmented/.menu/.automatic)` | `pickerOptionsAndSelection` | 样式透传（接受并通过，桥接按默认样式渲染） |
| `modifier.shadow` | shadow | unsupported | — | — |  |
| `modifier.overlay` | overlay | unsupported | — | — |  |
| `modifier.border` | border | unsupported | — | — |  |
| `modifier.clipShape` | clipShape | unsupported | — | — |  |
| `modifier.onTapGesture` | onTapGesture | unsupported | — | — |  |
| `modifier.gesture` | gesture | unsupported | — | — |  |
| `modifier.animation` | animation | unsupported | — | — |  |
| `modifier.transition` | transition | unsupported | — | — |  |
| `modifier.offset` | offset | unsupported | — | — |  |
| `modifier.scaleEffect` | scaleEffect | unsupported | — | — |  |
| `modifier.rotationEffect` | rotationEffect | unsupported | — | — |  |
| `modifier.toolbar` | toolbar | unsupported | — | — |  |
| `modifier.onChange` | onChange | unsupported | — | — |  |
| `modifier.onSubmit` | onSubmit | unsupported | — | — |  |
| `modifier.searchable` | searchable | unsupported | — | — |  |
| `modifier.refreshable` | refreshable | unsupported | — | — |  |
| `modifier.swipeActions` | swipeActions | unsupported | — | — |  |
| `modifier.contextMenu` | contextMenu | unsupported | — | — |  |
| `modifier.environment` | environment | unsupported | — | — |  |
| `modifier.environmentObject` | environmentObject | unsupported | — | — |  |
| `modifier.ignoresSafeArea` | ignoresSafeArea | unsupported | — | — |  |
| `modifier.fixedSize` | fixedSize | unsupported | — | — |  |
| `modifier.layoutPriority` | layoutPriority | unsupported | — | — |  |
| `modifier.zIndex` | zIndex | unsupported | — | — |  |
| `modifier.fill` | fill | unsupported | — | — |  |
| `modifier.stroke` | stroke | unsupported | — | — |  |
| `modifier.resizable` | resizable | unsupported | — | — |  |
| `modifier.scaledToFit` | scaledToFit | unsupported | — | — |  |
| `modifier.aspectRatio` | aspectRatio | unsupported | — | — |  |
| `modifier.keyboardType` | keyboardType | unsupported | — | — |  |
| `modifier.focused` | focused | unsupported | — | — |  |
| `modifier.fullScreenCover` | fullScreenCover | unsupported | — | — |  |
| `modifier.confirmationDialog` | confirmationDialog | unsupported | — | — |  |
| `modifier.labelStyle` | labelStyle | unsupported | — | — |  |
| `modifier.toggleStyle` | toggleStyle | unsupported | — | — |  |
| `modifier.tabItem` | tabItem | unsupported | — | — |  |
| `modifier.navigationBarTitleDisplayMode` | navigationBarTitleDisplayMode | unsupported | — | — |  |

