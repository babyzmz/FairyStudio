import SwiftUI
import RuntimeContracts

/// 生命周期输入规划（契约裁决 B-5 / CR-2）：
/// - 宿主在 SwiftUI onAppear / onDisappear / task 回调中发送 `.action(对应 ActionID)`，运行时只在 `.action` 上执行用户闭包；
/// - 对带有这些 modifier 的节点，宿主**另外**发送 `.appear(NodeID)` / `.disappear(NodeID)`，供运行时做生命周期记账与任务取消；
/// - 每个节点只发一次 `.appear` / `.disappear`（即使同时带有多个生命周期 modifier）。
///
/// 纯函数，平台无关，macOS 单测直接覆盖；RenderNodeView 按它挂接 SwiftUI 回调。
public enum LifecycleInputs {
    /// 节点是否带有任何生命周期 modifier。
    public static func hasLifecycle(_ node: RenderNode) -> Bool {
        node.modifiers.contains { modifier in
            switch modifier {
            case .onAppear, .onDisappear, .task: true
            default: false
            }
        }
    }

    /// SwiftUI onAppear 时要发送的输入：先 `.appear(NodeID)` 记账，再按 modifier 顺序发送各 onAppear 的 `.action`。
    public static func onAppear(_ node: RenderNode) -> [RuntimeInput] {
        guard hasLifecycle(node) else { return [] }
        var inputs: [RuntimeInput] = [.appear(node.id)]
        for case let .onAppear(action) in node.modifiers { inputs.append(.action(action)) }
        return inputs
    }

    /// SwiftUI task 启动时要发送的输入（M0 为同步子集：只发 `.action`；取消语义由 `.disappear` 记账承担）。
    public static func onTask(_ node: RenderNode) -> [RuntimeInput] {
        var inputs: [RuntimeInput] = []
        for case let .task(action) in node.modifiers { inputs.append(.action(action)) }
        return inputs
    }

    /// SwiftUI onDisappear 时要发送的输入：先按 modifier 顺序发送各 onDisappear 的 `.action`，最后 `.disappear(NodeID)` 记账。
    public static func onDisappear(_ node: RenderNode) -> [RuntimeInput] {
        guard hasLifecycle(node) else { return [] }
        var inputs: [RuntimeInput] = []
        for case let .onDisappear(action) in node.modifiers { inputs.append(.action(action)) }
        inputs.append(.disappear(node.id))
        return inputs
    }
}

/// 把 LifecycleInputs 挂到 SwiftUI 回调上（只挂一次，放在 modifier 链最外层）。
struct LifecycleHooks: ViewModifier {
    let node: RenderNode
    let send: BridgeSend

    func body(content: Content) -> some View {
        let taskInputs = LifecycleInputs.onTask(node)
        content
            .onAppear {
                for input in LifecycleInputs.onAppear(node) { send(input) }
            }
            .onDisappear {
                for input in LifecycleInputs.onDisappear(node) { send(input) }
            }
            .task(id: node.id) {
                for input in taskInputs { send(input) }
            }
    }
}
