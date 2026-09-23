import RuntimeContracts

/// 契约中每一个 RenderKind / RenderModifier 的样例。新增 case 时：NativeBridge 的穷举 switch 先编译失败，
/// 补上映射后，这里的集合相等断言会继续失败，直到样例也补齐。
enum Samples {
    static let action = ActionID("sample.action")
    static let binding = BindingID("sample.binding")

    static func node(_ id: String, _ kind: RenderKind, modifiers: [RenderModifier] = [], children: [RenderNode] = []) -> RenderNode {
        RenderNode(id: NodeID(id), kind: kind, modifiers: modifiers, children: children)
    }

    static var label: [RenderNode] { [node("label", .text("标签", style: nil))] }

    static let allKinds: [RenderKind] = [
        .text("文本", style: .headline),
        .image(.systemName("star")),
        .button(action: action, role: .destructive),
        .textField(placeholder: "占位", binding: binding, text: "你好"),
        .secureField(placeholder: "密码", binding: binding, text: "secret"),
        .toggle(binding: binding, isOn: true),
        .slider(binding: binding, value: 2, lower: 0, upper: 10, step: 1),
        .stepper(binding: binding, value: 1, lower: 0, upper: 3),
        .picker(binding: binding, selected: .int(1), options: [PickerOption(tag: .int(1), label: "一"), PickerOption(tag: .int(2), label: "二")]),
        .vstack(alignment: .leading, spacing: 4),
        .hstack(alignment: .top, spacing: nil),
        .zstack(alignment: .center),
        .spacer(minLength: 8),
        .divider,
        .scrollView(.both),
        .list,
        .section(header: "头", footer: "尾"),
        .form,
        .group,
        .navigationStack,
        .navigationLink(destinationID: NodeID("dest")),
        .navigationDestination(NodeID("dest")),
        .sheetHost(isPresented: false, dismiss: action),
        .alertHost(title: "标题", message: "消息", isPresented: false, buttons: [AlertButton(title: "好", action: action)]),
        .progressView(label: "进度", value: 0.5),
        .emptyView,
        .unsupported(symbol: "Canvas", capabilityID: "view.Canvas"),
    ]

    static let allModifiers: [RenderModifier] = [
        .padding(.horizontal, 8),
        .font(.title),
        .fontWeight(.semibold),
        .bold,
        .italic,
        .foregroundColor(ColorValue(named: .red)),
        .background(ColorValue(r: 0.1, g: 0.2, b: 0.3)),
        .frame(width: 100, height: nil, maxWidth: .infinity, maxHeight: nil, alignment: .leading),
        .cornerRadius(6),
        .opacity(0.5),
        .disabled(true),
        .hidden(false),
        .navigationTitle("标题"),
        .buttonStyle("bordered"),
        .textFieldStyle("plain"),
        .listStyle("plain"),
        .multilineTextAlignment(.center),
        .lineLimit(2),
        .onAppear(action),
        .onDisappear(action),
        .task(action),
        .accessibilityLabel("无障碍"),
        .animation(.spring, valueKey: "k"),
        .tag(.string("t")),
    ]

    /// 一个节点：给容器类节点配上子节点，给 navigationStack 配上根页面与一个目标页。
    static func renderable(_ kind: RenderKind, index: Int) -> RenderNode {
        let id = "node\(index)"
        switch RenderKindTagName.name(of: kind) {
        case "navigationStack":
            return node(id, kind, children: [
                node("\(id).root", .vstack(alignment: .center, spacing: nil), children: label),
                node("\(id).dest", .navigationDestination(NodeID("dest")), children: label),
            ])
        case "button", "toggle", "stepper", "picker", "vstack", "hstack", "zstack", "scrollView", "list", "section",
             "form", "group", "navigationLink", "navigationDestination", "sheetHost":
            return node(id, kind, children: label)
        default:
            return node(id, kind)
        }
    }
}

/// 契约 case 名：有载荷的 case 取 Mirror 标签，无载荷的 case 取 String(describing:)。
enum RenderKindTagName {
    static func name(of value: Any) -> String {
        Mirror(reflecting: value).children.first?.label ?? String(describing: value)
    }
}
