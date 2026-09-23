import Testing
import SwiftUI
import RuntimeContracts
@testable import NativeBridge
#if canImport(AppKit)
import AppKit
#endif

/// 契约裁决 B-5 / CR-2：带 onAppear / onDisappear / task 的节点，宿主在发送 `.action(id)` 之外另发 `.appear/.disappear(NodeID)`。
@MainActor
@Suite("生命周期输入（B-5）")
struct LifecycleInputsTests {
    let appearAction = ActionID("a.appear")
    let appearAction2 = ActionID("a.appear2")
    let disappearAction = ActionID("a.disappear")
    let taskAction = ActionID("a.task")

    @Test("onAppear：先 .appear(NodeID) 记账，再按顺序发送每个 onAppear 的 .action")
    func appearPlan() {
        let node = Samples.node("n", .text("x", style: nil), modifiers: [.onAppear(appearAction), .padding(.all, nil), .onAppear(appearAction2)])
        #expect(LifecycleInputs.onAppear(node) == [.appear(NodeID("n")), .action(appearAction), .action(appearAction2)])
        #expect(LifecycleInputs.onDisappear(node) == [.disappear(NodeID("n"))])
        #expect(LifecycleInputs.onTask(node).isEmpty)
    }

    @Test("onDisappear：先发送 onDisappear 的 .action，最后 .disappear(NodeID)")
    func disappearPlan() {
        let node = Samples.node("n", .text("x", style: nil), modifiers: [.onDisappear(disappearAction)])
        #expect(LifecycleInputs.onAppear(node) == [.appear(NodeID("n"))])
        #expect(LifecycleInputs.onDisappear(node) == [.action(disappearAction), .disappear(NodeID("n"))])
    }

    @Test("task：出现时 .appear(NodeID) 记账 + task 启动时 .action；消失时 .disappear(NodeID)")
    func taskPlan() {
        let node = Samples.node("n", .text("x", style: nil), modifiers: [.task(taskAction)])
        #expect(LifecycleInputs.onAppear(node) == [.appear(NodeID("n"))])
        #expect(LifecycleInputs.onTask(node) == [.action(taskAction)])
        #expect(LifecycleInputs.onDisappear(node) == [.disappear(NodeID("n"))])
    }

    @Test("无生命周期 modifier 的节点不发送任何生命周期输入")
    func noLifecycle() {
        let node = Samples.node("n", .text("x", style: nil), modifiers: [.padding(.all, 4), .bold])
        #expect(!LifecycleInputs.hasLifecycle(node))
        #expect(LifecycleInputs.onAppear(node).isEmpty)
        #expect(LifecycleInputs.onDisappear(node).isEmpty)
    }

    #if canImport(AppKit)
    @Test("真实 SwiftUI 挂载：出现时收到 .appear(NodeID) 与 .action(onAppear)，各一次")
    func realHostingSendsAppear() async {
        final class Sink { var inputs: [RuntimeInput] = [] }
        let sink = Sink()
        let node = Samples.node("root", .vstack(alignment: .center, spacing: nil), children: [
            Samples.node("child", .text("x", style: nil), modifiers: [.onAppear(appearAction), .task(taskAction)]),
        ])
        let tree = RenderTree(runID: RunID(), revision: 1, root: node)
        let hosting = NSHostingView(rootView: RenderTreeView(tree: tree) { sink.inputs.append($0) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline, !(sink.inputs.contains(.action(appearAction)) && sink.inputs.contains(.action(taskAction))) {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sink.inputs.filter { $0 == .appear(NodeID("child")) }.count == 1, "\(sink.inputs)")
        #expect(sink.inputs.filter { $0 == .action(appearAction) }.count == 1, "\(sink.inputs)")
        #expect(sink.inputs.filter { $0 == .action(taskAction) }.count == 1, "\(sink.inputs)")
    }
    #endif
}
