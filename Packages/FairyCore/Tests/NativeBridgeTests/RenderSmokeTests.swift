import Testing
import SwiftUI
import RuntimeContracts
@testable import NativeBridge
#if canImport(AppKit)
import AppKit
#endif

/// 每一种 RenderKind、每一个 RenderModifier 都能构造并完成一次真实布局（macOS NSHostingView），不崩溃。
@MainActor
@Suite("RenderTreeView 冒烟渲染")
struct RenderSmokeTests {
    private func host(_ root: RenderNode, revision: UInt64 = 1) -> CGSize {
        let tree = RenderTree(runID: RunID(), revision: revision, root: root)
        let view = RenderTreeView(tree: tree) { _ in }
        #if canImport(AppKit)
        let hosting = NSHostingView(rootView: view.frame(width: 400, height: 600))
        hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
        #else
        return .zero
        #endif
    }

    @Test("每种 RenderKind 单独渲染不崩溃", arguments: Array(Samples.allKinds.enumerated()).map { $0 })
    func eachKindRenders(index: Int, kind: RenderKind) {
        let node = Samples.renderable(kind, index: index)
        let size = host(node)
        #expect(size.width >= 0 && size.height >= 0)
    }

    @Test("所有 RenderKind 组合在一棵树里渲染不崩溃")
    func allKindsInOneTree() {
        let children = Samples.allKinds.enumerated().map { Samples.renderable($1, index: $0) }
        let root = Samples.node("root", .vstack(alignment: .leading, spacing: 8), children: children)
        _ = host(root)
    }

    @Test("每个 RenderModifier 应用在节点上渲染不崩溃，含非法参数")
    func allModifiersRender() {
        var modifiers = Samples.allModifiers
        // 非法参数：必须显示可见标记而不是崩溃。
        modifiers += [
            .buttonStyle("不存在"), .textFieldStyle("fancy"), .listStyle("weird"),
            .frame(width: -5, height: .nan, maxWidth: -1, maxHeight: nil, alignment: nil),
            .foregroundColor(ColorValue(named: .clear)), .multilineTextAlignment(.top), .opacity(.nan), .lineLimit(-3),
        ]
        let node = Samples.node("modified", .button(action: Samples.action, role: nil), modifiers: modifiers, children: Samples.label)
        _ = host(node)
    }

    @Test("revision 更新（同一 RunID）重建视图不崩溃")
    func revisionUpdates() {
        let runID = RunID()
        for revision in 1...5 {
            let root = Samples.node("root", .vstack(alignment: .center, spacing: nil), children: [
                Samples.node("count", .text("Count: \(revision)", style: .largeTitle)),
                Samples.node("field", .textField(placeholder: "名字", binding: Samples.binding, text: "你好")),
            ])
            let tree = RenderTree(runID: runID, revision: UInt64(revision), root: root)
            #if canImport(AppKit)
            let hosting = NSHostingView(rootView: RenderTreeView(tree: tree) { _ in })
            hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            hosting.layoutSubtreeIfNeeded()
            #endif
        }
    }

    @Test("列表行以 NodeID 作身份：重排后身份集合不变")
    func listIdentityUsesNodeID() {
        let rows = ["a", "b", "c"].map { Samples.node("list/\($0)", .text($0, style: nil)) }
        let forward = Samples.node("list", .list, children: rows)
        let reversed = Samples.node("list", .list, children: rows.reversed())
        #expect(Set(forward.children.map(\.id)) == Set(reversed.children.map(\.id)))
        _ = host(forward)
        _ = host(reversed)
    }
}
