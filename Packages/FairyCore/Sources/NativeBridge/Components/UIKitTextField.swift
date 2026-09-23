#if canImport(UIKit)
import SwiftUI
import UIKit

/// UITextField 与 TextBufferReconciler 的粘合层。独立成类以便在 App 宿主单测中直接驱动 UITextField 验证：
/// revision 更新但文本未变时不改动 text / selectedTextRange，输入法组字（markedTextRange）期间不覆盖。
@MainActor
public final class BridgeTextFieldController {
    public let field: UITextField
    public private(set) var reconciler = TextBufferReconciler()
    var onUserEdit: @MainActor (String) -> Void

    public init(onUserEdit: @escaping @MainActor (String) -> Void) {
        self.onUserEdit = onUserEdit
        let field = UITextField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.field = field
        // 闭包式 UIAction，不使用 selector。
        field.addAction(UIAction { [weak self] _ in self?.userDidEdit() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.userDidEdit() }, for: .editingDidEnd)
    }

    public func configure(placeholder: String, isSecure: Bool, style: BridgeTextFieldStyle) {
        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.isSecureTextEntry != isSecure { field.isSecureTextEntry = isSecure }
        let border: UITextField.BorderStyle = switch style {
        case .roundedBorder: .roundedRect
        case .plain: .none
        }
        if field.borderStyle != border { field.borderStyle = border }
    }

    /// 用户编辑回调（也可由测试直接调用以模拟 editingChanged）。
    public func userDidEdit() {
        let isComposing = field.markedTextRange != nil
        if let outgoing = reconciler.userEdited(field.text ?? "", isComposing: isComposing) {
            onUserEdit(outgoing)
        }
    }

    /// 运行时（新 revision）给出文本。只有在运行时主动改变文本且不在组字时才写入 UITextField。
    public func applyRuntimeText(_ runtimeText: String) {
        let decision = reconciler.runtimeUpdated(runtimeText, localText: field.text ?? "", isComposing: field.markedTextRange != nil)
        guard case let .applyRuntime(value) = decision else { return }
        replaceText(with: value)
    }

    /// 以运行时文本替换内容，尽量保留光标的 UTF-16 偏移（夹在新文本长度内）。
    private func replaceText(with value: String) {
        let caretOffset: Int? = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.end) }
        field.text = value
        guard field.isFirstResponder, let caretOffset else { return }
        let clamped = min(caretOffset, value.utf16.count)
        if let position = field.position(from: field.beginningOfDocument, offset: clamped) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
    }
}

struct BridgeUITextField: UIViewRepresentable {
    let placeholder: String
    let runtimeText: String
    let isSecure: Bool
    let style: BridgeTextFieldStyle
    let onUserEdit: @MainActor (String) -> Void

    func makeCoordinator() -> BridgeTextFieldController {
        BridgeTextFieldController(onUserEdit: onUserEdit)
    }

    func makeUIView(context: Context) -> UITextField {
        let controller = context.coordinator
        controller.configure(placeholder: placeholder, isSecure: isSecure, style: style)
        controller.applyRuntimeText(runtimeText)
        return controller.field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        let controller = context.coordinator
        controller.onUserEdit = onUserEdit
        controller.configure(placeholder: placeholder, isSecure: isSecure, style: style)
        controller.applyRuntimeText(runtimeText)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let width = proposal.width ?? max(intrinsic.width, 120)
        return CGSize(width: width, height: max(intrinsic.height, 34))
    }
}
#endif
