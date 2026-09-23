import RuntimeContracts

// 桥接映射表。`tag(of:)` 使用无 default 的穷举 switch：契约新增 RenderKind / RenderModifier 时，
// NativeBridge 编译即失败，必须补上映射与测试。测试再用 Mirror 校验标签名与契约 case 名一致。

/// RenderKind 的无载荷标签，rawValue 与契约 case 名一致。
public enum RenderKindTag: String, CaseIterable, Sendable {
    case text, image, button, textField, secureField, toggle, slider, stepper, picker
    case vstack, hstack, zstack, spacer, divider, scrollView, list, section, form, group
    case navigationStack, navigationLink, navigationDestination, sheetHost, alertHost
    case progressView, emptyView, unsupported

    public static func tag(of kind: RenderKind) -> RenderKindTag {
        switch kind {
        case .text: .text
        case .image: .image
        case .button: .button
        case .textField: .textField
        case .secureField: .secureField
        case .toggle: .toggle
        case .slider: .slider
        case .stepper: .stepper
        case .picker: .picker
        case .vstack: .vstack
        case .hstack: .hstack
        case .zstack: .zstack
        case .spacer: .spacer
        case .divider: .divider
        case .scrollView: .scrollView
        case .list: .list
        case .section: .section
        case .form: .form
        case .group: .group
        case .navigationStack: .navigationStack
        case .navigationLink: .navigationLink
        case .navigationDestination: .navigationDestination
        case .sheetHost: .sheetHost
        case .alertHost: .alertHost
        case .progressView: .progressView
        case .emptyView: .emptyView
        case .unsupported: .unsupported
        }
    }

    /// 预编译的 SwiftUI 目标组件（文档与诊断用）。
    public var swiftUIComponent: String {
        switch self {
        case .text: "Text(verbatim:)"
        case .image: "Image(systemName:)；项目资源图片在 M0 显示可见占位"
        case .button: "Button(role:action:label:) → RuntimeInput.action"
        case .textField: "UITextField 包装（iOS）/ TextField（macOS），本地编辑缓冲 → setBinding"
        case .secureField: "UITextField(isSecureTextEntry) 包装（iOS）/ SecureField（macOS）→ setBinding"
        case .toggle: "Toggle → setBinding(.bool)"
        case .slider: "Slider → setBinding(.double)"
        case .stepper: "Stepper(onIncrement:onDecrement:) → setBinding(.int)"
        case .picker: "Picker + tag(TransferValue) → setBinding"
        case .vstack: "VStack"
        case .hstack: "HStack"
        case .zstack: "ZStack"
        case .spacer: "Spacer(minLength:)"
        case .divider: "Divider"
        case .scrollView: "ScrollView(axes)"
        case .list: "List + ForEach(id: NodeID)"
        case .section: "Section(header:footer:)"
        case .form: "Form"
        case .group: "Group"
        case .navigationStack: "NavigationStack(path:)，路径由 navigationDestination 子节点决定"
        case .navigationLink: "Button → RuntimeInput.navigationPush"
        case .navigationDestination: "navigationDestination(for: NodeID.self) 的目标页面"
        case .sheetHost: ".sheet(isPresented:) → 关闭时 RuntimeInput.action(dismiss)"
        case .alertHost: ".alert(isPresented:actions:message:) → 按钮 action"
        case .progressView: "ProgressView"
        case .emptyView: "EmptyView"
        case .unsupported: "可见占位：符号 + 「运行时尚不支持」"
        }
    }
}

/// RenderModifier 的无载荷标签，rawValue 与契约 case 名一致。
public enum RenderModifierTag: String, CaseIterable, Sendable {
    case padding, font, fontWeight, bold, italic, foregroundColor, background, frame, cornerRadius
    case opacity, disabled, hidden, navigationTitle, buttonStyle, textFieldStyle, listStyle
    case multilineTextAlignment, lineLimit, onAppear, onDisappear, task, accessibilityLabel, animation, tag

    public static func tag(of modifier: RenderModifier) -> RenderModifierTag {
        switch modifier {
        case .padding: .padding
        case .font: .font
        case .fontWeight: .fontWeight
        case .bold: .bold
        case .italic: .italic
        case .foregroundColor: .foregroundColor
        case .background: .background
        case .frame: .frame
        case .cornerRadius: .cornerRadius
        case .opacity: .opacity
        case .disabled: .disabled
        case .hidden: .hidden
        case .navigationTitle: .navigationTitle
        case .buttonStyle: .buttonStyle
        case .textFieldStyle: .textFieldStyle
        case .listStyle: .listStyle
        case .multilineTextAlignment: .multilineTextAlignment
        case .lineLimit: .lineLimit
        case .onAppear: .onAppear
        case .onDisappear: .onDisappear
        case .task: .task
        case .accessibilityLabel: .accessibilityLabel
        case .animation: .animation
        case .tag: .tag
        }
    }

    /// 预编译的 SwiftUI 目标 modifier（文档与诊断用）。
    public var swiftUIModifier: String {
        switch self {
        case .padding: ".padding(_:_:)"
        case .font: ".font(_:)"
        case .fontWeight: ".fontWeight(_:)"
        case .bold: ".bold()"
        case .italic: ".italic()"
        case .foregroundColor: ".foregroundStyle(_:)"
        case .background: ".background(_:)"
        case .frame: ".frame(width:height:alignment:) + .frame(maxWidth:maxHeight:alignment:)"
        case .cornerRadius: ".clipShape(RoundedRectangle(cornerRadius:))"
        case .opacity: ".opacity(_:)"
        case .disabled: ".disabled(_:)"
        case .hidden: ".hidden()"
        case .navigationTitle: ".navigationTitle(_:)"
        case .buttonStyle: ".buttonStyle(.bordered / .borderedProminent / .plain / .borderless)"
        case .textFieldStyle: "环境值 → UITextField.borderStyle（iOS）/ .textFieldStyle（macOS）"
        case .listStyle: ".listStyle(.plain / .insetGrouped / .grouped / .inset / .sidebar)"
        case .multilineTextAlignment: ".multilineTextAlignment(_:)"
        case .lineLimit: ".lineLimit(_:)"
        case .onAppear: ".onAppear → RuntimeInput.action"
        case .onDisappear: ".onDisappear → RuntimeInput.action"
        case .task: ".task → RuntimeInput.action"
        case .accessibilityLabel: ".accessibilityLabel(_:)"
        case .animation: ".animation(_:value:)"
        case .tag: ".tag(TransferValue)"
        }
    }
}
