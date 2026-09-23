import SwiftUI
import RuntimeContracts

/// TextField / SecureField 桥接：本地编辑缓冲 + TextBufferReconciler。
/// iOS 使用 UITextField（可读取 markedTextRange，保证中文输入法组字不被 revision 更新打断）；
/// macOS 仅用于包内单测编译与冒烟渲染，使用 SwiftUI TextField + 本地缓冲。
struct BridgeTextInput: View {
    let placeholder: String
    let binding: BindingID
    let runtimeText: String
    let isSecure: Bool
    let send: BridgeSend
    @Environment(\.bridgeTextFieldStyle) private var style

    var body: some View {
        #if canImport(UIKit)
        BridgeUITextField(placeholder: placeholder, runtimeText: runtimeText, isSecure: isSecure, style: style) { text in
            send(.setBinding(binding, .string(text)))
        }
        #else
        SwiftUITextInput(placeholder: placeholder, runtimeText: runtimeText, isSecure: isSecure, style: style) { text in
            send(.setBinding(binding, .string(text)))
        }
        #endif
    }
}

#if !canImport(UIKit)
private struct SwiftUITextInput: View {
    let placeholder: String
    let runtimeText: String
    let isSecure: Bool
    let style: BridgeTextFieldStyle
    let onUserEdit: @MainActor (String) -> Void
    @State private var local: String?
    @State private var reconciler = TextBufferReconciler()

    var body: some View {
        let text = Binding(
            get: { local ?? runtimeText },
            set: { newValue in
                local = newValue
                if let outgoing = reconciler.userEdited(newValue, isComposing: false) {
                    onUserEdit(outgoing)
                }
            }
        )
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .modifier(SwiftUITextFieldStyleModifier(style: style))
        .onAppear {
            _ = reconciler.runtimeUpdated(runtimeText, localText: local ?? runtimeText, isComposing: false)
        }
        .onChange(of: runtimeText) { _, newValue in
            if case let .applyRuntime(value) = reconciler.runtimeUpdated(newValue, localText: local ?? newValue, isComposing: false) {
                local = value
            }
        }
    }
}

private struct SwiftUITextFieldStyleModifier: ViewModifier {
    let style: BridgeTextFieldStyle

    func body(content: Content) -> some View {
        switch style {
        case .roundedBorder: content.textFieldStyle(.roundedBorder)
        case .plain: content.textFieldStyle(.plain)
        }
    }
}
#endif
