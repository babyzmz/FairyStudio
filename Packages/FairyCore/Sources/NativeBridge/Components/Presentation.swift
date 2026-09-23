import SwiftUI
import RuntimeContracts

// 导航与呈现。运行时是导航路径与呈现状态的唯一权威：
// - navigationStack 的 children[0] 是根页面，其后的 `.navigationDestination(id)` 子节点按顺序构成路径；
// - navigationLink 点击只回传 navigationPush，由运行时决定是否推入（推入后树里出现对应 destination）；
// - 用户手势返回时回传 navigationPop(count:)；
// - sheet 被用户关闭时回传 sheetHost 的 dismiss action；alert 按钮回传各自的 action。
// 该约定已写入 docs/CONTRACT_REQUESTS.md 请主代理确认。

struct BridgeNavigationStack: View {
    let node: RenderNode
    let send: BridgeSend
    @State private var path: [NodeID] = []

    private var root: RenderNode? { node.children.first }

    private var destinations: [NodeID: RenderNode] {
        var map: [NodeID: RenderNode] = [:]
        for child in node.children.dropFirst() {
            if case let .navigationDestination(id) = child.kind { map[id] = child }
        }
        return map
    }

    private var runtimePath: [NodeID] {
        node.children.dropFirst().compactMap { child in
            if case let .navigationDestination(id) = child.kind { return id }
            return nil
        }
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { path },
            set: { newPath in
                let popped = path.count - newPath.count
                path = newPath
                if popped > 0 {
                    send(.navigationPop(count: popped))
                }
            }
        )) {
            Group {
                if let root {
                    RenderNodeView(node: root, send: send)
                } else {
                    UnsupportedNodeView(symbol: "NavigationStack（缺少根页面）", capabilityID: "view.NavigationStack")
                }
            }
            .navigationDestination(for: NodeID.self) { id in
                if let destination = destinations[id] {
                    RenderNodeView(node: destination, send: send)
                } else {
                    ProgressView {
                        Text("等待运行时渲染目标页面 \(id.rawValue)")
                    }
                }
            }
        }
        .onAppear { path = runtimePath }
        .onChange(of: runtimePath) { _, newValue in
            if path != newValue { path = newValue }
        }
    }
}

struct BridgeNavigationLink: View {
    let destinationID: NodeID
    let label: [RenderNode]
    let send: BridgeSend

    var body: some View {
        Button {
            send(.navigationPush(destinationID: destinationID))
        } label: {
            HStack {
                ChildNodes(children: label, send: send)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isLink)
    }
}

struct BridgeSheetHost: View {
    let isPresented: Bool
    let dismiss: ActionID
    let content: [RenderNode]
    let send: BridgeSend

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .sheet(isPresented: Binding(
                get: { isPresented },
                set: { presented in
                    if !presented { send(.action(dismiss)) }
                }
            )) {
                VStack(spacing: 0) {
                    ChildNodes(children: content, send: send)
                }
            }
    }
}

struct BridgeAlertHost: View {
    let title: String
    let message: String?
    let isPresented: Bool
    let buttons: [AlertButton]
    let send: BridgeSend
    /// 本地呈现状态：没有 action 的按钮关闭 alert 后，运行时无从得知，避免因运行时仍为 true 而反复弹出。
    @State private var presented = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .alert(Text(verbatim: title), isPresented: $presented) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button(role: BridgeValues.role(button.role)) {
                        if let action = button.action { send(.action(action)) }
                    } label: {
                        Text(verbatim: button.title)
                    }
                }
            } message: {
                if let message { Text(verbatim: message) }
            }
            .onAppear { presented = isPresented }
            .onChange(of: isPresented) { _, newValue in presented = newValue }
    }
}
