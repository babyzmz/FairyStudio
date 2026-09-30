import SwiftUI
import UIKit

/// M0 源码编辑器：UITextView，关闭一切会改写代码的“智能”替换（弯引号、破折号、自动更正、自动大写、拼写检查、智能插入删除）。
/// SwiftUI TextEditor 无法关闭弯引号：在 iOS 上键入 `"` 会得到 `“`，Swift 源码随即无法解析。
/// 输入法组字（marked text）期间不回写绑定，避免打断中文输入。M1 由 TextKit 2 原生编辑器替换。
///
/// W1 多标签：`cursor` 双向同步光标 offset；`restore` 递增即把光标移到 `cursor`（切换标签保留光标）。
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var cursor: Binding<Int>? = nil
    /// 每次递增触发一次光标恢复（父视图在切换标签时 +1）。
    var restore: Int = 0

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        let base = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.accessibilityIdentifier = "editor.text"
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // 组字中不覆盖；内容相同不触碰（保持光标）。
        if view.markedTextRange == nil, view.text != text {
            view.text = text
        }
        // 切换标签时的光标恢复（只在 token 变化时做一次，不干扰正常输入）。
        if restore != context.coordinator.appliedRestore, view.markedTextRange == nil {
            context.coordinator.appliedRestore = restore
            if let cursor {
                let clamped = max(0, min(cursor.wrappedValue, (view.text as NSString).length))
                view.selectedRange = NSRange(location: clamped, length: 0)
                view.scrollRangeToVisible(view.selectedRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        var appliedRestore = 0

        init(parent: CodeTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            parent.text = textView.text
            parent.cursor?.wrappedValue = textView.selectedRange.location
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            parent.cursor?.wrappedValue = textView.selectedRange.location
        }
    }
}
