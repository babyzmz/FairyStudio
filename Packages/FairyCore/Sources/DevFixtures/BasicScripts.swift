import Foundation
import RuntimeContracts

/// 计数器：Text("Count: N") + Button("+1")。每次 action：数字 +1、revision +1。
struct CounterScript: FixtureScript {
    static let incrementAction = ActionID("counter.increment")
    static let resetAction = ActionID("counter.reset")

    let scenario = FixtureScenario.counter
    private(set) var count = 0

    mutating func start() -> [FixtureOutput] { [] }

    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput] {
        switch input {
        case .action(Self.incrementAction):
            count += 1
            return [.console(.stdout, "count = \(count)"), .rerender]
        case .action(Self.resetAction):
            count = 0
            return [.console(.stdout, "count reset"), .rerender]
        default:
            return [.console(.debug, "计数器夹具忽略输入：\(input)")]
        }
    }

    func render() -> RenderNode {
        RenderNode(id: NodeID("counter.root"), kind: .vstack(alignment: .center, spacing: 16), modifiers: [.padding(.all, nil)], children: [
            RenderNode(id: NodeID("counter.label"), kind: .text("Count: \(count)", style: .largeTitle)),
            RenderNode(id: NodeID("counter.increment"), kind: .button(action: Self.incrementAction, role: nil),
                       modifiers: [.buttonStyle("borderedProminent")],
                       children: [RenderNode(id: NodeID("counter.increment.label"), kind: .text("+1", style: nil))]),
            RenderNode(id: NodeID("counter.reset"), kind: .button(action: Self.resetAction, role: .destructive),
                       modifiers: [.buttonStyle("bordered")],
                       children: [RenderNode(id: NodeID("counter.reset.label"), kind: .text("重置", style: nil))]),
        ])
    }
}

/// 表单：TextField / Toggle / List + ForEach 重排。文本回写只更新 revision，不改变 TextField 已有内容。
struct FormScript: FixtureScript {
    static let nameBinding = BindingID("form.name")
    static let agreeBinding = BindingID("form.agree")
    static let reverseAction = ActionID("form.reverse")

    struct Row: Sendable, Hashable {
        var id: String
        var title: String
    }

    let scenario = FixtureScenario.form
    private(set) var name = ""
    private(set) var agree = false
    private(set) var rows: [Row] = [
        Row(id: "apple", title: "苹果"),
        Row(id: "banana", title: "香蕉"),
        Row(id: "cherry", title: "樱桃"),
        Row(id: "durian", title: "榴莲"),
    ]

    mutating func start() -> [FixtureOutput] { [] }

    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput] {
        switch input {
        case .setBinding(Self.nameBinding, .string(let value)):
            name = value
            return [.rerender]
        case .setBinding(Self.agreeBinding, .bool(let value)):
            agree = value
            return [.console(.stdout, "agree = \(value)"), .rerender]
        case .action(Self.reverseAction):
            rows.reverse()
            return [.console(.stdout, "rows = \(rows.map(\.id).joined(separator: ","))"), .rerender]
        default:
            return [.console(.debug, "表单夹具忽略输入：\(input)")]
        }
    }

    func render() -> RenderNode {
        let listRows = rows.map { row in
            RenderNode(id: NodeID("form.list/\(row.id)"), kind: .text(row.title, style: nil))
        }
        return RenderNode(id: NodeID("form.root"), kind: .vstack(alignment: .leading, spacing: 12), modifiers: [.padding(.all, nil)], children: [
            RenderNode(id: NodeID("form.name"), kind: .textField(placeholder: "名字", binding: Self.nameBinding, text: name),
                       modifiers: [.textFieldStyle("roundedBorder"), .accessibilityLabel("名字输入框")]),
            RenderNode(id: NodeID("form.greeting"), kind: .text("你好，\(name)", style: .headline)),
            RenderNode(id: NodeID("form.agree"), kind: .toggle(binding: Self.agreeBinding, isOn: agree), children: [
                RenderNode(id: NodeID("form.agree.label"), kind: .text("同意条款", style: nil)),
            ]),
            RenderNode(id: NodeID("form.agree.state"), kind: .text(agree ? "状态：已同意" : "状态：未同意", style: .footnote)),
            RenderNode(id: NodeID("form.reverse"), kind: .button(action: Self.reverseAction, role: nil),
                       modifiers: [.buttonStyle("bordered")],
                       children: [RenderNode(id: NodeID("form.reverse.label"), kind: .text("反转顺序", style: nil))]),
            RenderNode(id: NodeID("form.list"), kind: .list, modifiers: [.listStyle("plain"), .frame(width: nil, height: 220, maxWidth: nil, maxHeight: nil, alignment: nil)], children: listRows),
        ])
    }
}

/// 含一个运行时尚不支持的节点，并发出对应诊断。
struct UnsupportedScript: FixtureScript {
    let scenario = FixtureScenario.unsupported

    mutating func start() -> [FixtureOutput] {
        [.diagnostic(Diagnostic(kind: .unsupportedAPI, severity: .warning,
                                message: "Canvas 是合法 SwiftUI，但运行时尚不支持",
                                capabilityID: "view.Canvas"))]
    }

    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput] { [] }

    func render() -> RenderNode {
        RenderNode(id: NodeID("unsupported.root"), kind: .vstack(alignment: .center, spacing: 12), modifiers: [.padding(.all, nil)], children: [
            RenderNode(id: NodeID("unsupported.caption"), kind: .text("下面是一个运行时尚不支持的节点", style: .subheadline)),
            RenderNode(id: NodeID("unsupported.canvas"), kind: .unsupported(symbol: "Canvas", capabilityID: "view.Canvas")),
        ])
    }
}

/// 渲染一次后发出 budgetExceeded 诊断，随后以 interrupted 结束。
struct BudgetScript: FixtureScript {
    let scenario = FixtureScenario.budgetExceeded

    mutating func start() -> [FixtureOutput] {
        [
            .console(.stderr, "执行步数超过预算，已中断"),
            .diagnostic(Diagnostic(kind: .budgetExceeded, severity: .error, message: "超过步数预算 maxSteps（夹具模拟）")),
            .finish(.budgetExceeded("maxSteps"), .interrupted),
        ]
    }

    mutating func handle(_ input: RuntimeInput) -> [FixtureOutput] { [] }

    func render() -> RenderNode {
        RenderNode(id: NodeID("budget.root"), kind: .text("while true { }", style: .body), modifiers: [.padding(.all, nil)])
    }
}
