# SwiftRuntime 设计（M0-A，运行时版本 0.1.0）

SwiftRuntime 是 Fairy Studio 的解释器包：把用户在 App 内写的多文件 Swift（受支持子集）编译为槽位化 IR，由栈式 VM 执行，
产出 `RenderTree` 交给 NativeBridge 渲染为真正的 SwiftUI。它只依赖 `RuntimeContracts` 与 swift-syntax 603.0.2，
不依赖 SwiftUI，也不维护第二套 AST 求值语义。

对外入口：`SwiftRuntimeEngine`（实现 `RuntimeEngine`）、`SwiftRunHandle`（实现 `RunHandle`）、
`SwiftRuntimeEngine.catalog`（capability catalog）、`SupportDocGenerator`（生成 docs/SWIFT_SUPPORT.md）。

## 1. 执行链路与源码布局

```
ProgramSource ──► Parse ──► Index ──► Resolve/Compile ──► IRProgram ──► VM ──► ViewEvaluator ──► RenderTree
                  (每文件)   (跨文件)   (名称解析+语义检查)   (无语法树)   (预算/取消)  (StateStore)
```

| 目录 | 内容 |
|---|---|
| `Parse/` | `SourceMap`（UTF-8 偏移 ↔ 行列）、`ProgramParser`（SwiftParser 解析、SwiftParserDiagnostics 语法诊断、SwiftOperators 运算符折叠） |
| `Index/` | 声明模型（`TypeDecl`/`FuncDecl`/`GlobalDecl`/…）、`Indexer`（收集全部文件顶层声明与扩展）、`Signatures`（类型语法 → `SType`、函数编号分配、运行期类型元数据） |
| `Resolve/` | `Compiler`（驱动与诊断）、`FunctionBuilder`（槽位、作用域、捕获）、语句/表达式/调用/左值/闭包/视图/名称编译、`QuickType`（不发射代码的类型推断） |
| `IR/` | `SType`（静态类型）、`Instr`（指令集）、`IRFunction`/`IRProgram`/`RuntimeTypeInfo` |
| `VM/` | `Value`、`VM`（指令循环与调用）、`VMPlaces`（左值）、`ValueOps`（带溢出检测的运算）、`Describe`（print 格式）、`VMError`/`BudgetMeter`/`CancelToken` |
| `Stdlib/` | 标准库运行期实现与编译期签名表 |
| `UI/` | `ViewNode`、`ViewBuiltins`（视图构造与修饰符）、`StateStore`、`ViewEvaluator` |
| `Engine/` | `SwiftRuntimeEngine`、`RunInstance`（actor）、`SwiftRunHandle`、`ThreadExecutor`、`EventEmitter`、`RuntimeLiveCounters` |
| `Catalog/` | capability catalog 数据与 Markdown 生成 |

## 2. 各阶段数据结构

### 2.1 Parse
- 文件先按 `(path, fileID)` 排序，后续所有阶段只看排序后的顺序，因此**输入文件顺序不影响结果**（测试：所有排列 / 随机 20 次）。
- `ParsedFile`：`SourceFile` + `SourceMap` + 折叠后的 `SourceFileSyntax`。任一文件有语法错误时只返回 `parse` 诊断（避免在残缺树上产生噪音）。
- `SourceMap`：保存每行起始 UTF-8 偏移；`location(utf8Offset:)` 二分查找得到 1-based 行、列（列按 UTF-8 字节计，编辑器负责换算 UTF-16）。
  所有 `Diagnostic.range` 都由它生成，`SourceLocation.utf8Offset` 为文件内 UTF-8 偏移。

### 2.2 Index（跨文件模块声明索引）
- 第一遍收集所有文件的顶层声明：`struct`/`enum` → `TypeDecl`，函数 → `FuncDecl`（按基名分组，重载判重键 = 全名 + 形参类型写法），
  全局变量 → `GlobalDecl`；第二遍合并 `extension`（此时全部类型已登记）。
- 成员：存储属性（含 `@State`/`@Binding`、访问级别与 `private(set)`）、计算属性（只读）、方法（static/mutating）、init、静态存储属性（作为惰性全局）、enum case 与原始值。
- 顶层语句规则：单文件程序或 `main.swift` 可以有顶层语句；其他文件出现顶层语句、多个 `@main`、`@main` 与顶层语句并存均报错。
- 不支持的声明（class、protocol、泛型、actor、宏、typealias、嵌套类型…）在此阶段产生 `unsupportedSyntax` 诊断并附 capabilityID。

### 2.3 Resolve / 语义检查（`Compiler`）
- **名称解析顺序**：局部变量（由内向外）→ 外层函数变量（登记为捕获）→ 隐式 `self` 成员 → 静态上下文成员 → 全局变量 → 顶层函数 → 类型 → 内建。
  找不到 → `nameResolution`；属于已知但未支持的 Swift/SwiftUI 符号（Slider、Set、Date…）→ `unsupportedAPI`（不会伪装成用户写错）。
- **访问控制**：`private`/`fileprivate` 顶层声明与成员只在声明文件内可见（二者等同处理）；`private(set)` 在其他文件赋值报错。
- **静态类型 `SType`**（尽力推断，`unknown` 走动态分派）：用于
  1. Int/Double 定型：整数字面量（及纯字面量算术）按上下文类型定型（`let x: Double = 1 / 2` → 0.5）；两侧类型都已知且 Int/Double 不一致时报 `typeCheck`；
  2. 隐式成员 `.up`、`.red` 的解析；3. 方法/重载的静态绑定与 mutating 判定；4. `print`/插值时 Optional 的 `Optional(…)` 格式。
- 其他检查：let/非 mutating self 不可变、`guard` 必须退出、switch 穷尽性（enum/Bool）、调用标签与默认参数匹配（Swift 的前向扫描规则，含尾随闭包）。

### 2.4 IR（槽位化，执行期不持有 SwiftSyntax 节点）
- `IRFunction`：`paramCount`（方法/init 的 self 占槽位 0）、`localCount`、`code: [Instr]`、`locIndex`（每条指令 → `ranges` 表中的源范围）、
  `places`（左值描述表）、`paramCoercions`（动态回退：形参为 Double 时把 Int 实参转为 Double）。
- 局部变量是槽位索引；全局/静态存储属性是全局索引；类型成员是字段索引或预解析的函数编号。
- 捕获：闭包创建时按 `CaptureSource` 取值——`var`（及嵌套函数、mutating 方法中的 self）按引用：把外层槽位原地装箱（`Box`）并共享；
  `let` 按值复制。声明语句用 `initLocal` 覆盖槽位，保证循环每次迭代是新绑定。

### 2.5 VM
- `Value`：`int/double/bool/string/date/array/dict/range/partialRange/tuple/record/enumCase/closure/function/metatype/view/box/stateCell/binding/symbol/keyPath/iterator`。
  数组、字典（保持插入顺序的 CoW 存储）、结构体记录借助 Swift 自身写时复制实现值语义。Optional 采用扁平表示（`nil` = `.none`）。
  `partialRange`（单侧区间）只用于构造、数组下标切片、打印与比较；`enumCase` 带关联值 payload（`[]` = 无关联值）；
  `date` 只读（`Date()`/`Date.now`，description 透传宿主格式）。
- 单一值栈：帧的局部槽位 + 操作数都在 `stack` 上；`frames` 保存 `(function, pc, base, closure, onReturn)`。用户函数调用不递归宿主栈。
- `invoke`：stdlib 高阶函数、视图 body 求值等宿主代码回调闭包时的可重入入口（宿主重入层数上限 160，见预算）。
- 左值（`place` 指令）：根（局部/捕获/全局）+ 路径（字段、按名成员、元组下标、下标键、强制解包、可选链）。
  赋值/复合赋值原地修改（持有 inout 访问期间绝不回调 VM）；用户 mutating 方法与需要回调的 mutating 内建（`sort(by:)`、`removeAll(where:)`）
  采用"取出 → 执行 → 写回"，与 Swift 独占访问语义一致。路径中经过 `@State` 单元或 `@Binding` 时写穿到状态存储。
- 计算属性 setter：路径末端是带 setter 的计算属性时，同步 `invoke` getter/setter（setter 返回 mutation 后的 self 再写回）；
  无 setter 的计算属性赋值/复合赋值为类型错误；计算属性上的用户 mutating 方法调用为子集限制错误（请先读到局部变量）。
- didSet：存储属性/全局/static 的 didSet 在 `.place` 赋值/复合赋值与 builtin mutating 调用后触发（由内向外，init 内不触发，
  自体内对同一属性赋值只改值不递归，mutating 方法整体写回与 `$` 绑定写入不触发）；willSet 忽略并警告。
- inout：`&place` 实参求值一次（键表达式存隐藏槽）→ 装箱（`boxTop`）传入，函数体内读写穿箱，返回后按隐藏槽写回
  （copy-in/copy-out；同一变量多传不做独占检查；函数值与动态分派调用不支持）。
- 运行错误全部是受控的 `VMError`：整数运算使用 `addingReportingOverflow` 等，越界/解包 nil/除零都显式检查，**绝不触发宿主原生 trap**。

### 2.6 UI（`ViewEvaluator` + `StateStore`）
- 内建视图是 `ViewNode` 值（Text/Button/Stack/ForEach/Slider/Stepper/Picker/…）；自定义 View 是 `record`，渲染时挂载状态并调用 `body` getter。
- @ViewBuilder 为专门支持：语句序列 → `makeViewGroup`；`if/else`、`switch` → `wrapConditional(分支号)`；ForEach 内容是真正的闭包，按元素调用。
- 修饰符在调用处校验并转换为 `RenderModifier`（`foregroundStyle` → `foregroundColor`）；`onAppear/onDisappear/task` 注册为 ActionID；
  `navigationDestination` 注册类型→内容闭包（视图透传）；`sheet`/`alert` 求值内容闭包并附加宿主节点；`pickerStyle` 透传（视图不变）。
- 导航（B-2）：栈内维护路径——有 `[String]` path 绑定则以绑定为权威（推入写绑定，Int 记为 `i:<数字>`），否则走内部路径；
  `NavigationLink(value:)`（String/Int）与 `destination:` 形式按稳定 id 注册，`navigationPush` 解析后渲染 `navigationDestination` 子节点，
  `navigationPop(count:)` 钳制到根；`for:` 只支持 String/Int，修饰符须写在栈内容内部。
- 呈现（B-3/B-4）：`sheet`/`alert` 内容闭包每轮渲染重新求值（捕获的 state 读写直达存储）；
  sheet 手势关闭回传 `.action(dismiss)`（写 false + 跑 onDismiss），`.dismissSheet` 强制关闭不触发 onDismiss；
  alert 每个按钮保证 action，点击后先跑用户动作再自动关闭。
- `.task` 同步子集：与 onAppear 同机制（宿主触发），体内 `await` 按同步执行（声明侧无 async）。
- 每次输入处理后若状态变脏则从根重新求值，`revision + 1`。

## 3. IR 指令集

| 类别 | 指令 | 说明 |
|---|---|---|
| 常量 | `pushInt/pushDouble/pushBool/pushString/pushNil/pushVoid/pushSymbol/pushKeyPath/pushFunction/pushMetatype/pushEnum/makeEnum`、`enumPayload(i)` | `makeEnum` 由关联值构造带 payload 的 case；`enumPayload` 取关联值（模式匹配绑定用，case 不符压 nil） |
| 栈 | `pop/dup/swap`、`boxTop` | `boxTop` 把栈顶装箱（inout 实参传址） |
| 变量 | `loadLocal/initLocal/storeLocal`、`loadCapture/storeCapture`、`loadGlobal/storeGlobal` | load 自动解引用箱/状态单元/绑定；store 写穿箱；全局惰性初始化 |
| 成员 | `getField(i)`、`getMember(name)`、`getComputed(fn)`、`tupleElement`、`destructure(n)`、`subscriptGet`、`makePartialRange(fromLower, closed)` | `destructure` 供解构声明与 for 元组模式；`makePartialRange` 由前后缀 `...`/`..<` 构造单侧区间 |
| 左值 | `place(idx, op)`，op ∈ `assign/compound/callMutating/callMethod/load/projectBinding` | `projectBinding` 实现 `$x`、`$x.a`、`$xs[i]` |
| 运算 | `binary(op, literalSide)`、`unary`、`forceUnwrap`、`toDouble`、`describe(SType)`、`concat(n)`、`matchEnumCase`、`matchSymbolCase`、`rangeContains` | `literalSide` 标记可做 Int→Double 动态回退的一侧 |
| 控制流 | `jump/jumpIfFalse/jumpIfTrue/jumpIfNil/jumpIfNotNil`、`loop(target)`（回边检查点）、`iterMake/iterNext` | 短路逻辑、`??`、可选链都由跳转实现 |
| 调用 | `call(fn, argc)`、`callValue`、`callMethod(name, argc)`（动态分派）、`callBuiltin(name, labels)`、`construct(type, fields)`（逐一成员）、`callInit`、`makeClosure(fn, captures)`、`ret` | |
| 集合 | `makeArray/makeDict/makeTuple/makeRecord` | |
| 视图 | `makeViewGroup(n)`、`wrapConditional(branch)` | @ViewBuilder 专门支持 |
| 诊断 | `trap(msg)`、`unsupported(msg, cap)` | |

## 4. 预算检查点（`ExecutionBudget`）

| 预算 | 检查位置 | 结果 |
|---|---|---|
| 取消（stop） | 每 1024 条指令、每个循环回边、每次函数调用 | 抛 `cancelled`，由 `stop()` 发出 stopping/stopped/finished(.stoppedByUser)，返回前 finish 事件流 |
| `maxSteps` | 每 1024 条指令、循环回边、函数调用 | `budgetExceeded`。按"执行单元"计：脚本入口为整个脚本；UI 入口为每次初次渲染或每次输入处理（含重新渲染） |
| `maxCallDepth` | 函数调用（`pushFrame`） | `budgetExceeded`；另有宿主重入上限 160 层（闭包回调嵌套） |
| `maxHeapBytesApprox` | 每 64×1024 条指令做一次近似堆扫描（栈、全局、捕获；大集合抽样前 16 个元素外推） | `budgetExceeded` |
| 值嵌套深度 | 每 8×1024 条指令沿"第一个子值"探测，超过 1000 层 | `budgetExceeded`（防止释放/比较/打印极深嵌套值时耗尽宿主栈） |
| `maxCollectionElements` | 数组/字典创建、追加、插入、拼接、`Array(repeating:)`、区间物化、`stride` | `budgetExceeded` |
| `maxStringLength` | 字符串拼接、插值、`+=`、`String(repeating:)`、`joined`、`print` | `budgetExceeded` |
| `sliceWallClock` | 每 1024 条指令 | 脚本入口：**让出**执行线程（`Task.yield`）后从同一指令继续；UI 事件/渲染：超过即 `budgetExceeded` |
| `asyncWaitLimit` | — | M0 没有异步等待，未使用 |

## 5. 状态存储键与身份路径

- `@State` 键 = `视图身份路径 + "#" + 字段名`。身份路径同时用作 `NodeID`：
  - 根 `root`；自定义 View 追加 `/类型名`（其 body 根节点沿用该路径）；
  - 容器内容 `/c`；Button/Toggle 标签 `/label`；@ViewBuilder 序列第 i 项 `.i`；if/else、switch 分支 `?分支号`；
  - ForEach 行 `[稳定 id]`（id 的调试描述，如 `[3]`、`["a"]`；重复 id 追加 `#n` 并给出警告）。
- 挂载：渲染自定义 View 时，对每个 `@State` 字段取（或以当前字段值为初值创建）`StateCell` 并替换字段；已存在的单元忽略新初值，
  因此**视图重建不重新初始化 @State**；ForEach 重排后状态跟随稳定 id；本轮渲染未触及的单元删除（视图离开层级即丢弃状态，与 SwiftUI 一致）。
- `@Binding` 字段保存 `BindingValue(cell, path)`；`$x`/`$x.a`/`$xs[i]` 在左值路径上找到第一个状态单元或绑定，剩余路径成为绑定路径。宿主 `setBinding` 按当前值形态校验后写入。
- `ActionID` = `runToken|NodeID|action|appear|task|disappear`，`BindingID` = `runToken|NodeID|text|isOn`，`runToken` 为 runID 前 8 位；
  同一节点跨渲染稳定，其它运行实例的 ID 在本实例中找不到而被忽略；另外输入信封的 runID 不符或 sequence 不递增时直接丢弃。

## 6. 线程模型

- 每个运行实例是一个 `actor RunInstance`，其 `unownedExecutor` 是专用的 `ThreadExecutor`：一个 32 MB 栈的 `Thread` 上的串行任务队列。
  VM、StateStore、ViewEvaluator 都只在这个线程上被访问（actor 隔离保证），不占用 MainActor，也不长期阻塞协作线程池。
- `stop()`：先在任意线程设置原子取消标志（`CancelToken`，`Synchronization.Atomic`）→ 等待启动任务结束（VM 在下一个检查点抛出 `cancelled`）→
  `instance.shutdown()` 发出事件 → 请求执行线程退出并 `join`。**返回时启动任务与执行线程均已结束**（`RuntimeLiveCounters` 可验证）。
- 脚本自然结束或失败时实例也会请求执行线程退出；之后若有迟到的任务入队，执行器按需重新启动线程处理（不会挂起调用方）。
- `EventEmitter` 用 `Mutex` 分配单调递增的 sequence 并写入 `AsyncStream`（unbounded）。
- `validate()` 的编译也在临时大栈线程上执行（`BigStack`）。
- `@unchecked Sendable` 只用于 `ThreadExecutor`：其全部可变状态只在 `NSCondition` 锁内访问（源码注释说明）。

## 7. 事件协议（状态机）

| 情形 | 事件序列 |
|---|---|
| 脚本正常结束 | `validating → preparing → running → console… → stopping → stopped → finished(.completed)` |
| 用户停止 | `… running → [render/console…] → stopping → stopped → finished(.stoppedByUser)` |
| 运行错误 | `… running → … → diagnostic(runtimeTrap / typeCheck / unsupportedAPI / internalError) → failed → finished(.trap / .internalError)` |
| 预算超限 | `… running → … → diagnostic(budgetExceeded) → interrupted → finished(.budgetExceeded)`（M0-C 起由 failed 改为 interrupted，与契约映射一致） |
| 校验失败（含入口无效） | `validating → diagnostic… → failed → finished(.validationFailed)`（CR-1 裁决，M0-C 实现） |

每个终止都先发 `stateChanged`（固定映射：completed / stoppedByUser → stopped，budgetExceeded → interrupted，
trap / internalError / validationFailed → failed），再发 `finished`；`finished` 总是最后一个事件，随后事件流结束。
`stop()` 返回前事件流一定已 finish（`SwiftRunHandle.isEventStreamFinished`；`ContractAlignmentTests` 覆盖三种情形）。
所有事件带 runID 与从 1 开始连续递增的 sequence。

生命周期输入（B-5 / CR-2 裁决）：`onAppear / onDisappear / task` 的闭包只在宿主发送对应 `.action(ActionID)` 时执行；
宿主另发的 `.appear(NodeID)` / `.disappear(NodeID)` 只记账（`RunInstance.appearedNodes`，只接受带生命周期 modifier 的节点），
不执行用户代码、不触发重新渲染。M0 的 `.task` 为同步子集，`.disappear` 时没有可取消的任务。

## 8. 动态回退

静态类型未知时（例如无类型上下文的闭包参数），VM 按运行期值分派：方法按全名在类型表查找、内建成员按值种类实现、
整数字面量一侧标记 `LiteralSide` 允许与 Double 运算、Double 形参接受 Int 实参。这些回退只会接受部分 Swift 本应拒绝的程序，
不会改变合法程序的语义。静态类型确定时一律按 Swift 规则报错。

## 9. 已知限制（M0）

- 语言：无 class/protocol/泛型/async/throws/inout/元组解构/关联值 enum/计算属性 setter/属性观察器/自定义下标/单侧区间/Double 区间；
  Optional 为扁平表示（`Int??` 不区分）；`Character` 以单字符 String 表示；字典遍历为插入顺序（Swift 原生为不确定顺序）。
- 默认参数只在静态解析的调用中生效；嵌套函数不支持默认参数与标签。
- 计算属性为只读；init 不做确定初始化检查。
- print 对嵌套超过 256 层的值输出 `…`。
- SwiftUI：NavigationStack 只渲染根内容；`onAppear`/`task` 由宿主发送对应 ActionID 触发（`.appear(NodeID)` 只记账），运行时不自动触发；
  `.task` 为同步子集；Color 只能作为修饰符参数；修饰符参数只接受文本样式/命名颜色等常量。
- 性能（debug 构建、本机 macOS 实测）：`for i in 0..<1_000_000 { total &+= i % 7 }` 约 1.4 s（user），
  每次迭代约 10 条指令，即约 7 百万条指令/秒；默认 `maxSteps = 5_000_000` 约对应 50 万次这样的迭代（超出即 budgetExceeded）。
  release 构建与指令融合优化尚未进行。
- `RunOptions.isCandidate` / `enableTracing` 暂未使用。
