import RuntimeContracts

/// 视图求值：把视图值（自定义 View 记录 / 内建 ViewNode）展开为 RenderTree。
///
/// 身份路径规则（NodeID 与 @State 键共用）：
/// - 根：`root`
/// - 自定义 View：父路径 + `/类型名`（其 body 的根节点沿用此路径）
/// - 容器内容：`/c`；Button/Toggle 的标签：`/label`
/// - @ViewBuilder 语句序列第 i 个：`.i`；if/else、switch 分支：`?分支号`
/// - ForEach 行：`[稳定 id]`（id 的调试描述，如 `[3]`、`["a"]`）
final class ViewEvaluator {
    let vm: VM
    let store: StateStore
    let runToken: String
    private(set) var actions: [String: Value] = [:]
    private(set) var bindings: [String: BindingValue] = [:]
    /// 带 onAppear / onDisappear / task 的节点（宿主会为它们发送 .appear/.disappear 记账输入）。
    /// 闭包本身只登记在 `actions` 中，由宿主发送对应 `.action(ActionID)` 触发（契约裁决 B-5）。
    private(set) var lifecycleNodes: Set<String> = []
    private(set) var warnings: [String] = []
    private var reportedWarnings = Set<String>()
    // MARK: - W3 导航与呈现状态（跨渲染持久；运行时是唯一权威）
    /// navigationDestination 注册：类型名 → 内容闭包；"link:<destinationID>" → 目标闭包。
    private(set) var navRegistry: [String: Value] = [:]
    /// NavigationLink 渲染时登记：link 的 destinationID → (所属栈路径, 目标键, path 字符串)。
    /// 目标键："String"/"Int"（for: 目标）或 "link"（destination 闭包链接）。
    private(set) var pendingPushes: [String: (stackPath: String, key: String, pathString: String)] = [:]
    /// 无 path 绑定的栈的内部路径：栈路径 → 条目（key + 值）。
    private(set) var navPaths: [String: [NavEntry]] = [:]
    /// 有 path 绑定的栈：栈路径 → path Binding（每次渲染刷新）。
    private(set) var navPathBindings: [String: BindingValue] = [:]
    /// 当前正在求值的栈路径（嵌套栈用栈保存/恢复）。
    private var stackContext: [String] = []
    /// 本次渲染遇到栈的顺序（navigationPop 无栈 id 时默认作用于最后一个）。
    private(set) var stackRenderOrder: [String] = []
    /// sheet 关闭动作：dismiss ActionID → (isPresented 绑定, onDismiss?)。
    private(set) var dismissActions: [String: (binding: BindingValue, onDismiss: Value?)] = [:]
    /// 有 sheet 的绑定（dismissSheet 强制关闭用）。
    private(set) var sheetBindings: [String: BindingValue] = [:]
    /// alert 按钮动作：ActionID → (isPresented 绑定, 按钮的用户动作 ActionID)。
    /// 按钮的用户闭包仍登记在 actions 中；触发时先跑用户动作，再把 isPresented 置 false（B-4）。
    private(set) var alertButtonActions: [String: (binding: BindingValue, action: ActionID)] = [:]
    /// 同一路径上的 sheet/alert 个数（id 去重用，每次渲染清零，顺序确定）。
    private var hostCounters: [String: Int] = [:]

    init(vm: VM, store: StateStore, runToken: String) {
        self.vm = vm; self.store = store; self.runToken = runToken
    }

    func actionID(_ path: String, _ suffix: String) -> ActionID { ActionID("\(runToken)|\(path)|\(suffix)") }
    func bindingID(_ path: String, _ suffix: String) -> BindingID { BindingID("\(runToken)|\(path)|\(suffix)") }

    func render(root: Value) throws -> RenderNode {
        actions = [:]
        bindings = [:]
        lifecycleNodes = []
        warnings = []
        dismissActions = [:]
        sheetBindings = [:]
        alertButtonActions = [:]
        navPathBindings = [:]
        stackRenderOrder = []
        hostCounters = [:]
        store.beginRender()
        let nodes = try evaluate(root, path: "root")
        store.endRender()
        store.dirty = false
        if nodes.count == 1 { return nodes[0] }
        return RenderNode(id: NodeID("root#group"), kind: .group, children: nodes)
    }

    private func warn(_ s: String) {
        if reportedWarnings.insert(s).inserted { warnings.append(s) }
    }

    func evaluate(_ v: Value, path: String) throws -> [RenderNode] {
        switch v {
        case .record(let rec):
            return try evaluateCustomView(rec, path: path)
        case .view(let node):
            return try evaluateNode(node, path: path)
        case .none:
            return []
        default:
            throw VMError.typeMismatch("期望一个 View，实际是 '\(ValueOps.typeName(v))'。")
        }
    }

    private func evaluateCustomView(_ rec: RecordValue, path: String) throws -> [RenderNode] {
        let info = vm.program.types[rec.type]
        guard info.isView else {
            throw VMError.typeMismatch("'\(info.name)' 不是 View（缺少 `: View` 遵循）。")
        }
        guard let getter = info.bodyGetter else {
            throw VMError.typeMismatch("View '\(info.name)' 缺少 `var body: some View`。")
        }
        let viewPath = path + "/" + info.name
        var mounted = rec
        for (i, w) in info.fieldWrappers.enumerated() where w == .state && i < mounted.fields.count {
            if case .stateCell = mounted.fields[i] { continue }
            let cell = store.cell(viewPath: viewPath, field: info.fieldNames[i], initial: mounted.fields[i])
            mounted.fields[i] = .stateCell(cell)
        }
        let body = try vm.invokeFunction(getter, [.record(mounted)])
        return try evaluate(body, path: viewPath)
    }

    private func node(_ path: String, _ kind: RenderKind, _ children: [RenderNode] = []) -> RenderNode {
        RenderNode(id: NodeID(path), kind: kind, children: children)
    }

    private func evaluateNode(_ n: ViewNode, path: String) throws -> [RenderNode] {
        switch n.kind {
        case .text(let s):
            return [node(path, .text(s, style: nil))]
        case .button(let label, let action, let role):
            let aid = actionID(path, "action")
            actions[aid.rawValue] = action
            return [node(path, .button(action: aid, role: role), try evaluate(label, path: path + "/label"))]
        case .stack(let kind, let alignment, let spacing, let content):
            let children = try evaluate(content, path: path + "/c")
            let k: RenderKind
            switch kind {
            case .v: k = .vstack(alignment: alignment, spacing: spacing)
            case .h: k = .hstack(alignment: alignment, spacing: spacing)
            case .z: k = .zstack(alignment: alignment)
            }
            return [node(path, k, children)]
        case .spacer(let m):
            return [node(path, .spacer(minLength: m))]
        case .divider:
            return [node(path, .divider)]
        case .empty:
            return [node(path, .emptyView)]
        case .textField(let placeholder, let binding, let secure):
            guard case .binding(let b) = binding else { throw VMError.typeMismatch("TextField 需要 Binding。") }
            let bid = bindingID(path, "text")
            bindings[bid.rawValue] = b
            let current = try b.get()
            guard case .string(let text) = current else {
                throw VMError.typeMismatch("TextField 的绑定必须是 String，实际是 '\(ValueOps.typeName(current))'。")
            }
            return [node(path, secure ? .secureField(placeholder: placeholder, binding: bid, text: text)
                                      : .textField(placeholder: placeholder, binding: bid, text: text))]
        case .toggle(let label, let binding):
            guard case .binding(let b) = binding else { throw VMError.typeMismatch("Toggle 需要 Binding。") }
            let bid = bindingID(path, "isOn")
            bindings[bid.rawValue] = b
            let current = try b.get()
            guard case .bool(let isOn) = current else {
                throw VMError.typeMismatch("Toggle 的绑定必须是 Bool，实际是 '\(ValueOps.typeName(current))'。")
            }
            return [node(path, .toggle(binding: bid, isOn: isOn), try evaluate(label, path: path + "/label"))]
        case .slider(let binding, let lower, let upper, let step):
            guard case .binding(let b) = binding else { throw VMError.typeMismatch("Slider 需要 Binding。") }
            let bid = bindingID(path, "value")
            bindings[bid.rawValue] = b
            let current = try b.get()
            guard case .double(let value) = current else {
                throw VMError.typeMismatch("Slider 的绑定必须是 Double，实际是 '\(ValueOps.typeName(current))'（请使用 @State Double 变量）。")
            }
            return [node(path, .slider(binding: bid, value: value, lower: lower, upper: upper, step: step))]
        case .stepper(let label, let binding, let lower, let upper):
            guard case .binding(let b) = binding else { throw VMError.typeMismatch("Stepper 需要 Binding。") }
            let bid = bindingID(path, "value")
            bindings[bid.rawValue] = b
            let current = try b.get()
            guard case .int(let value) = current else {
                throw VMError.typeMismatch("Stepper 的绑定必须是 Int，实际是 '\(ValueOps.typeName(current))'。")
            }
            return [node(path, .stepper(binding: bid, value: value, lower: lower, upper: upper),
                          try evaluate(label, path: path + "/label"))]
        case .picker(let label, let binding, let content):
            guard case .binding(let b) = binding else { throw VMError.typeMismatch("Picker 需要 Binding。") }
            let bid = bindingID(path, "selection")
            bindings[bid.rawValue] = b
            let selected = try TransferConvert.toTransfer(vm, try b.get())
            let options = try pickerOptions(content, path: path)
            return [node(path, .picker(binding: bid, selected: selected, options: options),
                          try evaluate(label, path: path + "/label"))]
        case .forEach(let data, let idPath, let content):
            var out: [RenderNode] = []
            var seen: [String: Int] = [:]
            for element in data {
                let idValue = try extractID(element, idPath)
                var key = vm.describer.describe(idValue, type: nil, debug: true)
                if let c = seen[key] {
                    seen[key] = c + 1
                    warn("ForEach 中出现重复的 id \(key)：行状态可能错乱（SwiftUI 同样要求 id 唯一）。")
                    key += "#\(c + 1)"
                } else {
                    seen[key] = 1
                }
                let row = try vm.invoke(content, [element])
                out += try evaluate(row, path: path + "[\(key)]")
            }
            return out
        case .list(let content):
            return [node(path, .list, try evaluate(content, path: path + "/c"))]
        case .navigationStack(let content, let pathBinding):
            stackRenderOrder.append(path)
            stackContext.append(path)
            defer { stackContext.removeLast() }
            let children = try evaluate(content, path: path + "/c")
            let root = children.count == 1 ? children[0] : node(path + "/c#group", .group, children)
            var out = [root]
            if let pb = pathBinding {
                guard case .binding(let b) = pb else { throw VMError.typeMismatch("NavigationStack 的 path: 需要 Binding。") }
                navPathBindings[path] = b
                let cur = try b.get()
                guard case .array(let elems) = cur, elems.allSatisfy({ if case .string = $0 { return true }; return false }) else {
                    throw VMError.typeMismatch("NavigationStack 的 path 绑定需要 [String]，实际是 '\(ValueOps.typeName(cur))'。")
                }
                for (i, e) in elems.enumerated() {
                    guard case .string(let s) = e else { continue }
                    out.append(try destinationNode(stackPath: path, index: i, pathString: s))
                }
            } else {
                for (i, e) in (navPaths[path] ?? []).enumerated() {
                    out.append(try destinationNode(stackPath: path, index: i, entry: e))
                }
            }
            return [node(path, .navigationStack, out)]
        case .navigationLink(let key, let value, let label):
            // destinationID 稳定（链接路径）：宿主回传 navigationPush 时再解析为目标。
            let did = NodeID(path + "|nav")
            let pathString: String
            if key == "link" {
                guard let dest = value else { throw VMError.internalError("NavigationLink 缺少目标") }
                navRegistry["link:" + did.rawValue] = dest
                pathString = did.rawValue
            } else {
                guard let v = value else { throw VMError.internalError("NavigationLink 缺少 value") }
                switch (key, v) {
                case ("String", .string(let s)): pathString = s
                case ("Int", .int(let i)): pathString = String(i)
                default:
                    throw VMError.typeMismatch("NavigationLink 的 value: 只支持 String/Int。")
                }
            }
            if let stack = stackContext.last {
                pendingPushes[did.rawValue] = (stackPath: stack, key: key, pathString: pathString)
            }
            return [node(path, .navigationLink(destinationID: did), try evaluate(label, path: path + "/label"))]
        case .scrollView(let axes, let content):
            return [node(path, .scrollView(axes), try evaluate(content, path: path + "/c"))]
        case .form(let content):
            return [node(path, .form, try evaluate(content, path: path + "/c"))]
        case .section(let header, let footer, let content):
            return [node(path, .section(header: header, footer: footer), try evaluate(content, path: path + "/c"))]
        case .explicitGroup(let content):
            return [node(path, .group, try evaluate(content, path: path + "/c"))]
        case .image(let src):
            if case .resource(let name) = src {
                warn("Image(\"\(name)\")：项目图片资源尚未接入（M1），显示占位。")
            }
            return [node(path, .image(src))]
        case .progress(let label, let value):
            return [node(path, .progressView(label: label, value: value))]
        case .group(let views):
            var out: [RenderNode] = []
            for (i, v) in views.enumerated() { out += try evaluate(v, path: path + ".\(i)") }
            return out
        case .conditional(let branch, let content):
            return try evaluate(content, path: path + "?\(branch)")
        case .modified(let base, let mod):
            // 单次生效的修饰符（注册/宿主）：只附加一次，不按基视图节点数重复
            switch mod {
            case .navigationDestination(let t, let b):
                // 注册目标（B-2），视图本身透传
                navRegistry[t] = b
                return try evaluate(base, path: path)
            case .sheet(let presented, let content, let onDismiss):
                let nodes = try evaluate(base, path: path)
                return nodes + (try sheetHost(path: path, presented: presented, content: content, onDismiss: onDismiss))
            case .alert(let title, let presented, let actionsV, let message):
                let nodes = try evaluate(base, path: path)
                return nodes + (try alertHost(path: path, title: title, presented: presented, actionsV: actionsV,
                                              message: message))
            default:
                break
            }
            var nodes = try evaluate(base, path: path)
            for i in nodes.indices {
                let nid = nodes[i].id.rawValue
                switch mod {
                case .render(let m):
                    nodes[i].modifiers.append(m)
                case .onAppear(let f):
                    let aid = actionID(nid, "appear")
                    actions[aid.rawValue] = f
                    lifecycleNodes.insert(nid)
                    nodes[i].modifiers.append(.onAppear(aid))
                case .task(let f):
                    let aid = actionID(nid, "task")
                    actions[aid.rawValue] = f
                    lifecycleNodes.insert(nid)
                    nodes[i].modifiers.append(.task(aid))
                case .onDisappear(let f):
                    let aid = actionID(nid, "disappear")
                    actions[aid.rawValue] = f
                    lifecycleNodes.insert(nid)
                    nodes[i].modifiers.append(.onDisappear(aid))
                case .navigationDestination, .sheet, .alert:
                    break   // 上方已处理
                }
            }
            return nodes
        case .unsupported(let symbol, let cap):
            return [node(path, .unsupported(symbol: symbol, capabilityID: cap))]
        }
    }

    // MARK: - Picker 选项提取

    /// Picker 内容（ForEach 或静态行）→ 选项列表。行必须是 `Text(...).tag(...)`。
    private func pickerOptions(_ content: Value, path: String) throws -> [PickerOption] {
        guard case .view(let n) = content else {
            throw VMError.typeMismatch("Picker 的内容需要 ForEach 或选项行，实际是 '\(ValueOps.typeName(content))'。")
        }
        switch n.kind {
        case .forEach(let data, _, let rowContent):
            var out: [PickerOption] = []
            for (i, element) in data.enumerated() {
                let row = try vm.invoke(rowContent, [element])
                out.append(try pickerRow(row, path: path + "/row.\(i)"))
            }
            return try checkedOptions(out)
        case .group(let views):
            return try checkedOptions(views.enumerated().map { try pickerRow($1, path: path + "/row.\($0)") })
        default:
            // 单行
            return try checkedOptions([pickerRow(content, path: path + "/row")])
        }
    }

    private func pickerRow(_ row: Value, path: String) throws -> PickerOption {
        // 行求值为 RenderNode：取 .text 标签 + .tag 修饰符
        let nodes = try evaluate(row, path: path)
        guard let textNode = nodes.first(where: { if case .text = $0.kind { return true }; return false }),
              case .text(let label, _) = textNode.kind else {
            throw VMError.typeMismatch("Picker 的每一行都需要是 Text，例如 `Text(t).tag(t)`。")
        }
        let tags = textNode.modifiers.compactMap { m -> TransferValue? in
            if case .tag(let t) = m { return t }
            return nil
        }
        guard let tag = tags.last else {
            throw VMError.typeMismatch("Picker 的每一行都需要 .tag(…)，例如 `Text(t).tag(t)`。")
        }
        return PickerOption(tag: tag, label: label)
    }

    private func checkedOptions(_ options: [PickerOption]) throws -> [PickerOption] {
        var seen = Set<PickerOption>()
        for o in options {
            if !seen.insert(o).inserted {
                warn("Picker 选项的 tag 重复（桥接以 tag 作行身份，重复会导致错乱）。")
                break
            }
        }
        return options
    }

    // MARK: - 导航目标解析（B-2）

    /// 把 path 字符串解析为目标节点（link 目标优先；"i:<数字>" 走 Int for: 目标，其余走 String）。
    private func destinationNode(stackPath: String, index i: Int, pathString s: String) throws -> RenderNode {
        let id = NodeID(stackPath + "/path.\(i)")
        if let builder = navRegistry["link:" + s] {
            let content = try vm.invoke(builder, [])
            return RenderNode(id: id, kind: .navigationDestination(id),
                              children: try evaluate(content, path: id.rawValue + "/c"))
        }
        if s.hasPrefix("i:"), let iv = Int(s.dropFirst(2)), let builder = navRegistry["Int"] {
            let content = try vm.invoke(builder, [.int(iv)])
            return RenderNode(id: id, kind: .navigationDestination(id),
                              children: try evaluate(content, path: id.rawValue + "/c"))
        }
        if let builder = navRegistry["String"] {
            let content = try vm.invoke(builder, [.string(s)])
            return RenderNode(id: id, kind: .navigationDestination(id),
                              children: try evaluate(content, path: id.rawValue + "/c"))
        }
        warn("导航路径 '\(s)' 没有匹配的 navigationDestination（for: String.self/Int.self 或对应链接）。")
        return RenderNode(id: id, kind: .unsupported(symbol: "navigationDestination", capabilityID: "view.NavigationLink"))
    }

    private func destinationNode(stackPath: String, index i: Int, entry e: NavEntry) throws -> RenderNode {
        let id = NodeID(stackPath + "/path.\(i)")
        if e.key == "link" {
            guard case .string(let s) = e.value, let builder = navRegistry["link:" + s] else {
                throw VMError.internalError("导航目标链接丢失。")
            }
            let content = try vm.invoke(builder, [])
            return RenderNode(id: id, kind: .navigationDestination(id),
                              children: try evaluate(content, path: id.rawValue + "/c"))
        }
        guard let builder = navRegistry[e.key] else {
            warn("导航目标类型 '\(e.key)' 没有匹配的 navigationDestination。")
            return RenderNode(id: id, kind: .unsupported(symbol: "navigationDestination", capabilityID: "view.NavigationLink"))
        }
        let content = try vm.invoke(builder, [e.value])
        return RenderNode(id: id, kind: .navigationDestination(id),
                          children: try evaluate(content, path: id.rawValue + "/c"))
    }

    // MARK: - 导航输入（RunInstance 调用）

    /// navigationPush：把链接目标推入路径（有 path 绑定则写绑定，否则走内部路径）。未知 id 返回 false。
    /// path 绑定是 [String]：Int 目标记为 "i:<数字>" 以便与 String 区分（B-2 子集编码）。
    func pushNav(_ destinationID: NodeID) throws -> Bool {
        guard let p = pendingPushes[destinationID.rawValue] else { return false }
        if let b = navPathBindings[p.stackPath] {
            let cur = try b.get()
            guard case .array(let elems) = cur else {
                throw VMError.typeMismatch("NavigationStack 的 path 绑定需要 [String]。")
            }
            let s = p.key == "Int" ? "i:" + p.pathString : p.pathString
            try b.set(.array(elems + [.string(s)]))
        } else {
            var entries = navPaths[p.stackPath] ?? []
            switch p.key {
            case "link":
                guard navRegistry["link:" + p.pathString] != nil else { return false }
                entries.append(NavEntry(key: "link", value: .string(p.pathString)))
            case "String":
                guard navRegistry["String"] != nil else { return false }
                entries.append(NavEntry(key: "String", value: .string(p.pathString)))
            case "Int":
                guard let iv = Int(p.pathString), navRegistry["Int"] != nil else { return false }
                entries.append(NavEntry(key: "Int", value: .int(iv)))
            default:
                return false
            }
            navPaths[p.stackPath] = entries
            store.dirty = true
        }
        return true
    }

    /// navigationPop：弹出 count 层（钳制到根）。返回实际弹出的层数。
    func popNav(count: Int) throws -> Int {
        guard let stack = stackRenderOrder.last else { return 0 }
        if let b = navPathBindings[stack] {
            let cur = try b.get()
            guard case .array(let elems) = cur else { return 0 }
            let n = min(max(count, 0), elems.count)
            if n > 0 { try b.set(.array(Array(elems.dropLast(n)))) }
            return n
        }
        var entries = navPaths[stack] ?? []
        let n = min(max(count, 0), entries.count)
        if n > 0 {
            entries.removeLast(n)
            navPaths[stack] = entries
            store.dirty = true
        }
        return n
    }

    // MARK: - sheet / alert（B-3/B-4）

    private func hostID(path: String, kind: String) -> String {
        let key = path + "|" + kind
        let n = hostCounters[key, default: 0]
        hostCounters[key] = n + 1
        return n == 0 ? key : key + ".\(n)"
    }

    /// sheet 宿主节点（内容闭包每轮渲染重新求值，捕获的 state 读写直达存储）。
    private func sheetHost(path: String, presented: Value, content: Value, onDismiss: Value?) throws -> [RenderNode] {
        guard case .binding(let b) = presented else { throw VMError.typeMismatch(".sheet 需要 Binding。") }
        let current = try b.get()
        guard case .bool(let isPresented) = current else {
            throw VMError.typeMismatch(".sheet 的 isPresented: 必须是 Bool，实际是 '\(ValueOps.typeName(current))'。")
        }
        let hid = hostID(path: path, kind: "sheet")
        let aid = actionID(hid, "dismiss")
        dismissActions[aid.rawValue] = (binding: b, onDismiss: onDismiss)
        sheetBindings[hid] = b
        let children = try evaluate(try vm.invoke(content, []), path: hid + "/c")
        return [RenderNode(id: NodeID(hid), kind: .sheetHost(isPresented: isPresented, dismiss: ActionID(aid.rawValue)),
                           children: children)]
    }

    /// alert 宿主节点。每个按钮都保证有 action（B-4）：用户动作执行后自动把 isPresented 置 false。
    private func alertHost(path: String, title: String, presented: Value, actionsV: Value, message: Value?) throws -> [RenderNode] {
        guard case .binding(let b) = presented else { throw VMError.typeMismatch(".alert 需要 Binding。") }
        let current = try b.get()
        guard case .bool(let isPresented) = current else {
            throw VMError.typeMismatch(".alert 的 isPresented: 必须是 Bool，实际是 '\(ValueOps.typeName(current))'。")
        }
        let hid = hostID(path: path, kind: "alert")
        let buttonNodes = try evaluate(try vm.invoke(actionsV, []), path: hid + "/actions")
        var buttons: [AlertButton] = []
        for (i, bn) in buttonNodes.enumerated() {
            guard case .button(let userAction, let role) = bn.kind else {
                throw VMError.typeMismatch(".alert 的按钮闭包需要一到两个 Button（实际含非按钮视图）。")
            }
            let label = renderTexts(bn).joined()
            let aid = actionID(hid, "button.\(i)")
            alertButtonActions[aid.rawValue] = (binding: b, action: userAction)
            buttons.append(AlertButton(title: label, role: role, action: aid))
        }
        if buttons.isEmpty {
            throw VMError.typeMismatch(".alert 的按钮闭包至少需要一个 Button。")
        }
        var messageText: String?
        if let message {
            let mNodes = try evaluate(try vm.invoke(message, []), path: hid + "/message")
            messageText = mNodes.flatMap(renderTexts).joined()
        }
        return [RenderNode(id: NodeID(hid), kind: .alertHost(title: title, message: messageText, isPresented: isPresented,
                                                             buttons: buttons))]
    }

    /// 强制关闭所有 sheet（.dismissSheet：只写 false，不触发 onDismiss）。
    func dismissAllSheets() throws {
        for (_, b) in sheetBindings {
            let cur = try b.get()
            if case .bool(true) = cur { try b.set(.bool(false)) }
        }
    }

    /// RenderNode 子树中的全部文本（alert 按钮标题 / 消息提取用）。
    private func renderTexts(_ n: RenderNode) -> [String] {
        var out: [String] = []
        if case .text(let s, _) = n.kind { out.append(s) }
        for c in n.children { out += renderTexts(c) }
        return out
    }

    private func extractID(_ element: Value, _ idPath: [String]?) throws -> Value {
        guard let idPath else {
            // Identifiable：取 id 属性
            return try vm.memberValue(element, "id")
        }
        var cur = element
        for name in idPath { cur = try vm.memberValue(cur, name) }
        return cur
    }
}
