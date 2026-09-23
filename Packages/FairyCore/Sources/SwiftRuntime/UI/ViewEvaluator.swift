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
    /// NodeID → onAppear / task 闭包
    private(set) var appearHandlers: [String: [Value]] = [:]
    private(set) var disappearHandlers: [String: [Value]] = [:]
    private(set) var warnings: [String] = []
    private var reportedWarnings = Set<String>()

    init(vm: VM, store: StateStore, runToken: String) {
        self.vm = vm; self.store = store; self.runToken = runToken
    }

    func actionID(_ path: String, _ suffix: String) -> ActionID { ActionID("\(runToken)|\(path)|\(suffix)") }
    func bindingID(_ path: String, _ suffix: String) -> BindingID { BindingID("\(runToken)|\(path)|\(suffix)") }

    func render(root: Value) throws -> RenderNode {
        actions = [:]
        bindings = [:]
        appearHandlers = [:]
        disappearHandlers = [:]
        warnings = []
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
        case .navigationStack(let content):
            let children = try evaluate(content, path: path + "/c")
            let root = children.count == 1 ? children[0] : node(path + "/c#group", .group, children)
            return [node(path, .navigationStack, [root])]
        case .scrollView(let axes, let content):
            return [node(path, .scrollView(axes), try evaluate(content, path: path + "/c"))]
        case .form(let content):
            return [node(path, .form, try evaluate(content, path: path + "/c"))]
        case .section(let header, let content):
            return [node(path, .section(header: header, footer: nil), try evaluate(content, path: path + "/c"))]
        case .explicitGroup(let content):
            return [node(path, .group, try evaluate(content, path: path + "/c"))]
        case .image(let src):
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
            var nodes = try evaluate(base, path: path)
            for i in nodes.indices {
                let nid = nodes[i].id.rawValue
                switch mod {
                case .render(let m):
                    nodes[i].modifiers.append(m)
                case .onAppear(let f):
                    let aid = actionID(nid, "appear")
                    actions[aid.rawValue] = f
                    appearHandlers[nid, default: []].append(f)
                    nodes[i].modifiers.append(.onAppear(aid))
                case .task(let f):
                    let aid = actionID(nid, "task")
                    actions[aid.rawValue] = f
                    appearHandlers[nid, default: []].append(f)
                    nodes[i].modifiers.append(.task(aid))
                case .onDisappear(let f):
                    let aid = actionID(nid, "disappear")
                    actions[aid.rawValue] = f
                    disappearHandlers[nid, default: []].append(f)
                    nodes[i].modifiers.append(.onDisappear(aid))
                }
            }
            return nodes
        case .unsupported(let symbol, let cap):
            return [node(path, .unsupported(symbol: symbol, capabilityID: cap))]
        }
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
