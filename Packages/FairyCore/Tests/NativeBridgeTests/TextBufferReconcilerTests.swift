import Testing
@testable import NativeBridge

@Suite("TextField 本地编辑缓冲")
struct TextBufferReconcilerTests {
    @Test("首次出现时写入运行时文本")
    func initialRuntimeTextIsApplied() {
        var reconciler = TextBufferReconciler()
        #expect(reconciler.runtimeUpdated("初始", localText: "", isComposing: false) == .applyRuntime("初始"))
    }

    @Test("输入法组字期间不回传，组字结束后回传最终文本")
    func composingIsNotSent() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("", localText: "", isComposing: false)
        #expect(reconciler.userEdited("ni", isComposing: true) == nil)
        #expect(reconciler.userEdited("nih", isComposing: true) == nil)
        #expect(reconciler.userEdited("你好", isComposing: false) == "你好")
    }

    @Test("revision 更新但文本未变：不改动本地（光标不跳）")
    func unchangedRuntimeTextKeepsLocal() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("abc", localText: "", isComposing: false)
        // 同一运行时文本被多次下发（其他节点变化导致 revision + 1）。
        #expect(reconciler.runtimeUpdated("abc", localText: "abc", isComposing: false) == .keepLocal)
        #expect(reconciler.runtimeUpdated("abc", localText: "abc", isComposing: false) == .keepLocal)
    }

    @Test("组字中收到任何运行时更新都不覆盖 marked text")
    func composingIsNeverInterrupted() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("你", localText: "", isComposing: false)
        // 本地是 "你hao"（hao 为 marked text），运行时 revision 更新但文本仍为 "你"。
        #expect(reconciler.runtimeUpdated("你", localText: "你hao", isComposing: true) == .keepLocal)
        // 即使运行时主动改了文本，组字期间也不覆盖。
        #expect(reconciler.runtimeUpdated("清空", localText: "你hao", isComposing: true) == .keepLocal)
    }

    @Test("迟到的回声不覆盖更新的本地输入")
    func staleEchoDoesNotOverwrite() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("", localText: "", isComposing: false)
        #expect(reconciler.userEdited("a", isComposing: false) == "a")
        #expect(reconciler.userEdited("ab", isComposing: false) == "ab")
        #expect(reconciler.userEdited("abc", isComposing: false) == "abc")
        #expect(reconciler.runtimeUpdated("a", localText: "abc", isComposing: false) == .keepLocal)
        #expect(reconciler.inFlight == ["ab", "abc"])
        #expect(reconciler.runtimeUpdated("ab", localText: "abc", isComposing: false) == .keepLocal)
        // 同一回声被重复下发（revision 变化）仍不覆盖。
        #expect(reconciler.runtimeUpdated("ab", localText: "abc", isComposing: false) == .keepLocal)
        #expect(reconciler.runtimeUpdated("abc", localText: "abc", isComposing: false) == .keepLocal)
        #expect(reconciler.inFlight.isEmpty)
    }

    @Test("运行时主动修改文本（非回声）时以运行时为准")
    func runtimeProgrammaticChangeWins() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("", localText: "", isComposing: false)
        #expect(reconciler.userEdited("hello", isComposing: false) == "hello")
        #expect(reconciler.runtimeUpdated("hello", localText: "hello", isComposing: false) == .keepLocal)
        #expect(reconciler.runtimeUpdated("", localText: "hello", isComposing: false) == .applyRuntime(""))
        // 运行时变换了输入（如转大写）也以运行时为准。
        #expect(reconciler.userEdited("abc", isComposing: false) == "abc")
        #expect(reconciler.runtimeUpdated("ABC", localText: "abc", isComposing: false) == .applyRuntime("ABC"))
        #expect(reconciler.inFlight.isEmpty)
    }

    @Test("未变化的编辑不重复回传；在途队列有上限")
    func deduplicateAndBound() {
        var reconciler = TextBufferReconciler()
        _ = reconciler.runtimeUpdated("x", localText: "", isComposing: false)
        #expect(reconciler.userEdited("x", isComposing: false) == nil)
        #expect(reconciler.userEdited("xy", isComposing: false) == "xy")
        #expect(reconciler.userEdited("xy", isComposing: false) == nil)
        for index in 0..<(TextBufferReconciler.inFlightLimit * 2) {
            _ = reconciler.userEdited("v\(index)", isComposing: false)
        }
        #expect(reconciler.inFlight.count == TextBufferReconciler.inFlightLimit)
    }
}
