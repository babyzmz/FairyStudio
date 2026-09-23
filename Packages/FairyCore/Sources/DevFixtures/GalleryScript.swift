import Foundation
import RuntimeContracts

/// 组件总览：覆盖契约中的每一个 RenderKind，含导航推入/返回、sheet、alert。
struct GalleryScript: FixtureScript {
    enum IDs {
        static let secret = BindingID("gallery.secret")
        static let slider = BindingID("gallery.slider")
        static let stepper = BindingID("gallery.stepper")
        static let picker = BindingID("gallery.picker")
        static let showSheet = ActionID("gallery.showSheet")
        static let dismissSheet = ActionID("gallery.dismissSheet")
        static let showAlert = ActionID("gallery.showAlert")
        static let alertOK = ActionID("gallery.alertOK")
        static let alertCancel = ActionID("gallery.alertCancel")
        static let detail = NodeID("gallery.detail")
        static let deeper = NodeID("gallery.deeper")
    }

    let scenario = FixtureScenario.gallery
    private(set) var secret = ""
    private(set) var sliderValue = 3.0
    private(set) var stepperValue = 1
    private(set) var flavor = TransferValue.string("vanilla")
    private(set) var sheetShown = false
    private(set) var alertShown = false
    private(set) var path: [NodeID] = []

    mutating func start() -> [FixtureOutput] { [] }

    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput] {
        switch input {
        case .setBinding(IDs.secret, .string(let value)):
            secret = value
        case .setBinding(IDs.slider, .double(let value)):
            sliderValue = value
        case .setBinding(IDs.stepper, .int(let value)):
            stepperValue = value
        case .setBinding(IDs.picker, let value):
            flavor = value
        case .action(IDs.showSheet):
            sheetShown = true
        case .action(IDs.dismissSheet), .dismissSheet:
            sheetShown = false
        case .action(IDs.showAlert):
            alertShown = true
        case .action(IDs.alertOK), .action(IDs.alertCancel):
            alertShown = false
        case .navigationPush(let destination) where destination == IDs.detail || destination == IDs.deeper:
            path.append(destination)
        case .navigationPop(let count):
            path.removeLast(min(max(count, 0), path.count))
        default:
            return [.console(.debug, "组件总览夹具忽略输入：\(input)")]
        }
        return [.console(.debug, "输入：\(input)"), .rerender]
    }

    func render() -> RenderNode {
        var stackChildren = [node("gallery.home", .zstack(alignment: .center), children: [homeForm(), sheetHost(), alertHost()])]
        stackChildren += path.map(destination)
        return node("gallery.nav", .navigationStack, children: stackChildren)
    }

    private func homeForm() -> RenderNode {
        node("gallery.form", .form, modifiers: [.navigationTitle("组件总览")], children: [
            node("gallery.basic", .section(header: "基础", footer: nil), children: [
                node("gallery.text", .text("文本 Text", style: .body), modifiers: [.bold]),
                node("gallery.hstack", .hstack(alignment: .center, spacing: 8), children: [
                    node("gallery.image", .image(.systemName("star.fill")), modifiers: [.foregroundColor(ColorValue(named: .yellow))]),
                    node("gallery.hstack.text", .text("HStack + Spacer", style: nil)),
                    node("gallery.spacer", .spacer(minLength: nil)),
                    node("gallery.resource", .image(.resource("logo"))),
                ]),
                node("gallery.zstack", .zstack(alignment: .center), children: [
                    node("gallery.zstack.bg", .text("ZStack 背景", style: .caption), modifiers: [.opacity(0.4)]),
                    node("gallery.zstack.fg", .text("前景", style: .headline)),
                ]),
                node("gallery.divider", .divider),
                node("gallery.progress.indeterminate", .progressView(label: "加载中", value: nil)),
                node("gallery.progress.value", .progressView(label: "进度", value: 0.4)),
                node("gallery.group", .group, children: [
                    node("gallery.group.text", .text("Group 内文本", style: .footnote), modifiers: [.italic]),
                    node("gallery.empty", .emptyView),
                ]),
            ]),
            node("gallery.inputs", .section(header: "输入", footer: "每次输入都会回写运行时并 revision+1"), children: [
                node("gallery.secure", .secureField(placeholder: "密码", binding: IDs.secret, text: secret)),
                node("gallery.secret.count", .text("密码长度：\(secret.count)", style: .caption)),
                node("gallery.slider", .slider(binding: IDs.slider, value: sliderValue, lower: 0, upper: 10, step: 1)),
                node("gallery.slider.value", .text("滑块：\(Int(sliderValue))", style: .caption)),
                node("gallery.stepper", .stepper(binding: IDs.stepper, value: stepperValue, lower: 0, upper: 5), children: [
                    node("gallery.stepper.label", .text("步进：\(stepperValue)", style: nil)),
                ]),
                node("gallery.picker", .picker(binding: IDs.picker, selected: flavor, options: [
                    PickerOption(tag: .string("vanilla"), label: "香草"),
                    PickerOption(tag: .string("chocolate"), label: "巧克力"),
                    PickerOption(tag: .string("matcha"), label: "抹茶"),
                ]), children: [node("gallery.picker.label", .text("口味", style: nil))]),
            ]),
            node("gallery.present", .section(header: "呈现与导航", footer: nil), children: [
                button("gallery.sheet.button", IDs.showSheet, "显示 Sheet"),
                button("gallery.alert.button", IDs.showAlert, "显示 Alert"),
                node("gallery.link", .navigationLink(destinationID: IDs.detail), children: [
                    node("gallery.link.label", .text("打开详情", style: nil)),
                ]),
            ]),
            node("gallery.scroll.section", .section(header: "滚动与列表", footer: nil), children: [
                node("gallery.scroll", .scrollView(.horizontal), children: [
                    node("gallery.scroll.row", .hstack(alignment: .center, spacing: 12), children: (1...8).map { index in
                        node("gallery.scroll.item\(index)", .text("项目 \(index)", style: nil),
                             modifiers: [.padding(.all, 8), .background(ColorValue(named: .teal)), .cornerRadius(8)])
                    }),
                ]),
                node("gallery.list", .list, modifiers: [.frame(width: nil, height: 120, maxWidth: nil, maxHeight: nil, alignment: nil)], children: [
                    node("gallery.list/a", .text("列表行 A", style: nil)),
                    node("gallery.list/b", .text("列表行 B", style: nil)),
                ]),
                node("gallery.vstack", .vstack(alignment: .leading, spacing: 4), children: [
                    node("gallery.vstack.1", .text("VStack 第一行", style: nil)),
                    node("gallery.vstack.2", .text("VStack 第二行", style: .caption2), modifiers: [.foregroundColor(ColorValue(named: .secondary))]),
                ]),
            ]),
            node("gallery.unsupported.section", .section(header: "未支持", footer: nil), children: [
                node("gallery.unsupported", .unsupported(symbol: "Chart", capabilityID: "view.Chart")),
            ]),
        ])
    }

    private func sheetHost() -> RenderNode {
        node("gallery.sheet", .sheetHost(isPresented: sheetShown, dismiss: IDs.dismissSheet), children: [
            node("gallery.sheet.body", .vstack(alignment: .center, spacing: 16), modifiers: [.padding(.all, nil)], children: [
                node("gallery.sheet.title", .text("这是 Sheet", style: .title2)),
                button("gallery.sheet.close", IDs.dismissSheet, "关闭"),
            ]),
        ])
    }

    private func alertHost() -> RenderNode {
        node("gallery.alert", .alertHost(title: "提示", message: "来自夹具的 Alert", isPresented: alertShown, buttons: [
            AlertButton(title: "好", action: IDs.alertOK),
            AlertButton(title: "取消", role: .cancel, action: IDs.alertCancel),
        ]))
    }

    private func destination(_ id: NodeID) -> RenderNode {
        let isDeeper = id == IDs.deeper
        var content: [RenderNode] = [
            node("\(id.rawValue).title", .text(isDeeper ? "更深一层" : "详情页", style: .title)),
            node("\(id.rawValue).note", .text("该页面由运行时推入（path 深度 \(path.count)）", style: .footnote)),
        ]
        if !isDeeper {
            content.append(node("gallery.detail.link", .navigationLink(destinationID: IDs.deeper), children: [
                node("gallery.detail.link.label", .text("继续推入", style: nil)),
            ]))
        }
        return RenderNode(id: id, kind: .navigationDestination(id), modifiers: [], children: [
            node("\(id.rawValue).body", .vstack(alignment: .leading, spacing: 12), modifiers: [
                .padding(.all, nil), .navigationTitle(isDeeper ? "更深" : "详情"),
            ], children: content),
        ])
    }

    private func button(_ id: String, _ action: ActionID, _ title: String) -> RenderNode {
        node(id, .button(action: action, role: nil), children: [node("\(id).label", .text(title, style: nil))])
    }

    private func node(_ id: String, _ kind: RenderKind, modifiers: [RenderModifier] = [], children: [RenderNode] = []) -> RenderNode {
        RenderNode(id: NodeID(id), kind: kind, modifiers: modifiers, children: children)
    }
}
