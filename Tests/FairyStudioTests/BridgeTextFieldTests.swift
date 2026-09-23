import Testing
import UIKit
import NativeBridge

/// 直接驱动 NativeBridge 的 UITextField 控制器，验证：revision 更新但文本未变时不动光标；
/// 输入法组字（marked text）期间既不回传也不被运行时覆盖；迟到回声不覆盖新输入。
@MainActor
@Suite("TextField 本地编辑缓冲（UIKit）", .serialized)
struct BridgeTextFieldTests {
    final class Sent {
        var values: [String] = []
    }

    private func makeController() -> (BridgeTextFieldController, Sent) {
        let sent = Sent()
        let controller = BridgeTextFieldController { sent.values.append($0) }
        controller.configure(placeholder: "名字", isSecure: false, style: .roundedBorder)
        return (controller, sent)
    }

    /// 把输入框放进宿主 App 的 key window 并成为第一响应者（marked text 需要）。
    private func mount(_ field: UITextField) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try #require(scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)
        field.frame = CGRect(x: 20, y: 120, width: 280, height: 40)
        window.addSubview(field)
        field.becomeFirstResponder()
        return window
    }

    private func caretOffset(_ field: UITextField) -> Int? {
        field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) }
    }

    @Test("revision 更新但文本未变：text 与光标位置都不变")
    func unchangedTextKeepsCaret() throws {
        let (controller, sent) = makeController()
        let field = controller.field
        controller.applyRuntimeText("hello")
        #expect(field.text == "hello")
        _ = try mount(field)
        defer { field.removeFromSuperview() }
        let position = try #require(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: position, to: position)
        #expect(caretOffset(field) == 2)

        for _ in 0..<5 { controller.applyRuntimeText("hello") }
        #expect(field.text == "hello")
        #expect(caretOffset(field) == 2)
        #expect(sent.values.isEmpty)
    }

    @Test("迟到回声不覆盖更新的本地输入")
    func staleEchoKeepsLocal() {
        let (controller, sent) = makeController()
        let field = controller.field
        controller.applyRuntimeText("")
        field.text = "a"; controller.userDidEdit()
        field.text = "ab"; controller.userDidEdit()
        field.text = "abc"; controller.userDidEdit()
        #expect(sent.values == ["a", "ab", "abc"])
        controller.applyRuntimeText("a")
        controller.applyRuntimeText("ab")
        #expect(field.text == "abc")
        controller.applyRuntimeText("abc")
        #expect(field.text == "abc")
    }

    @Test("运行时主动改文本时写入，光标夹在新长度内")
    func runtimeChangeApplies() throws {
        let (controller, _) = makeController()
        let field = controller.field
        controller.applyRuntimeText("hello world")
        _ = try mount(field)
        defer { field.removeFromSuperview() }
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        controller.applyRuntimeText("hi")
        #expect(field.text == "hi")
        #expect(caretOffset(field) == 2)
    }

    @Test("中文输入法组字期间：不回传、不被 revision 更新或运行时改写打断")
    func markedTextIsNotInterrupted() throws {
        let (controller, sent) = makeController()
        let field = controller.field
        controller.applyRuntimeText("你")
        _ = try mount(field)
        defer { field.removeFromSuperview() }
        #expect(field.isFirstResponder)

        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0))
        let marked = try #require(field.markedTextRange, "模拟器上 setMarkedText 未生效")
        #expect(field.text == "你hao")
        #expect(field.offset(from: marked.start, to: marked.end) == 3)

        controller.userDidEdit()
        #expect(sent.values.isEmpty, "组字中不应回传")

        // 其他节点变化导致 revision + 1，文本未变。
        controller.applyRuntimeText("你")
        #expect(field.markedTextRange != nil)
        #expect(field.text == "你hao")
        // 运行时即使主动改写，组字期间也不覆盖。
        controller.applyRuntimeText("被改写")
        #expect(field.markedTextRange != nil)
        #expect(field.text == "你hao")

        // 用户选定候选词：输入法先把 marked text 替换为「好」，再结束组字（UIKit 此时发出 editingChanged）。
        field.setMarkedText("好", selectedRange: NSRange(location: 1, length: 0))
        #expect(sent.values.isEmpty, "替换候选时仍在组字，不应回传")
        field.unmarkText()
        #expect(field.markedTextRange == nil)
        controller.userDidEdit()   // 重复通知不会重复回传
        #expect(field.text == "你好")
        #expect(sent.values == ["你好"])
    }
}
