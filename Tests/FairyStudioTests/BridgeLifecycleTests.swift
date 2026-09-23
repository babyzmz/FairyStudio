import Testing
import SwiftUI
import UIKit
import RuntimeContracts
import NativeBridge

/// 契约裁决 B-5：在 iOS 真实 SwiftUI 挂载中，带 onAppear 的节点出现时宿主发送 .appear(NodeID) 与 .action(onAppear)，
/// 消失时发送 .disappear(NodeID)。
@MainActor
@Suite("NativeBridge 生命周期输入（iOS 挂载）", .serialized)
struct BridgeLifecycleTests {
    final class Sink { var inputs: [RuntimeInput] = [] }

    @Test("出现：.appear(NodeID) + .action(onAppear)；移除：.action(onDisappear) + .disappear(NodeID)")
    func appearAndDisappear() async throws {
        let appear = ActionID("t.appear")
        let disappear = ActionID("t.disappear")
        let sink = Sink()
        let child = RenderNode(id: NodeID("child"), kind: .text("x", style: nil), modifiers: [.onAppear(appear), .onDisappear(disappear)])
        let root = RenderNode(id: NodeID("root"), kind: .vstack(alignment: .center, spacing: nil), children: [child])
        let runID = RunID()
        let controller = UIHostingController(rootView: RenderTreeView(tree: RenderTree(runID: runID, revision: 1, root: root)) { sink.inputs.append($0) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }

        #expect(await waitUntil { sink.inputs.contains(.action(appear)) })
        #expect(sink.inputs.filter { $0 == .appear(NodeID("child")) }.count == 1, "\(sink.inputs)")
        #expect(sink.inputs.filter { $0 == .action(appear) }.count == 1, "\(sink.inputs)")

        // 新 revision 中移除该节点 → 消失回调。
        let emptyRoot = RenderNode(id: NodeID("root"), kind: .vstack(alignment: .center, spacing: nil), children: [])
        controller.rootView = RenderTreeView(tree: RenderTree(runID: runID, revision: 2, root: emptyRoot)) { sink.inputs.append($0) }
        #expect(await waitUntil { sink.inputs.contains(.disappear(NodeID("child"))) }, "\(sink.inputs)")
        #expect(sink.inputs.filter { $0 == .action(disappear) }.count == 1, "\(sink.inputs)")
    }
}
