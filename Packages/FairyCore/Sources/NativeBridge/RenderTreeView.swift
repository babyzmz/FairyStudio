import SwiftUI
import RuntimeContracts

/// 宿主向运行时回传输入的闭包。只在 MainActor 上调用；由 RunCoordinator 负责补 runID 与 sequence。
public typealias BridgeSend = @MainActor (RuntimeInput) -> Void

/// RenderTree → 预编译 SwiftUI 组件的唯一入口。
///
/// - 每个 RenderKind / RenderModifier 都映射到固定的 SwiftUI 组件（见 `RenderKindTag` / `RenderModifierTag`），
///   不做任何动态 selector 或 Any 转发。
/// - 节点身份使用 `NodeID`：列表行、ForEach 子节点都以 NodeID 作为 SwiftUI 身份。
/// - 新的运行实例（RunID 变化）会整体重建视图，清空上一次运行的本地编辑缓冲与导航状态。
public struct RenderTreeView: View {
    public let tree: RenderTree
    private let send: BridgeSend

    public init(tree: RenderTree, send: @escaping BridgeSend) {
        self.tree = tree
        self.send = send
    }

    public var body: some View {
        RenderNodeView(node: tree.root, send: send)
            .environment(\.bridgeRevision, tree.revision)
            .id(tree.runID)
    }
}

extension EnvironmentValues {
    /// 当前应用的 RenderTree revision；交互控件据此在运行时回写后丢弃本地先行值。
    @Entry var bridgeRevision: UInt64 = 0
}

/// 按 NodeID 身份渲染一组子节点。
struct ChildNodes: View {
    let children: [RenderNode]
    let send: BridgeSend

    var body: some View {
        ForEach(children, id: \.id) { child in
            RenderNodeView(node: child, send: send)
        }
    }
}
