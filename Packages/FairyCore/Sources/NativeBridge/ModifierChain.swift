import SwiftUI
import RuntimeContracts

/// 按契约顺序应用 RenderModifier。SwiftUI modifier 的顺序有语义（padding 与 background 等），因此逐个折叠。
/// 无法识别的样式字符串或无效参数不会被静默丢弃：节点上会叠加一个可见的「无效参数」标记。
@MainActor
enum ModifierChain {
    static func apply(_ modifiers: [RenderModifier], to content: AnyView, send: @escaping BridgeSend) -> AnyView {
        modifiers.reduce(content) { view, modifier in
            apply(modifier, to: view, send: send)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func apply(_ modifier: RenderModifier, to view: AnyView, send: @escaping BridgeSend) -> AnyView {
        switch modifier {
        case let .padding(edges, length):
            let resolved = length.flatMap { BridgeValues.fixedLength($0) }
            return AnyView(view.padding(BridgeValues.edges(edges), resolved))
        case let .font(style):
            return AnyView(view.font(BridgeValues.font(style)))
        case let .fontWeight(weight):
            return AnyView(view.fontWeight(BridgeValues.weight(weight)))
        case .bold:
            return AnyView(view.bold())
        case .italic:
            return AnyView(view.italic())
        case let .foregroundColor(color):
            guard let resolved = BridgeValues.color(color) else {
                return AnyView(view.invalidParameter("foregroundColor(\(color))"))
            }
            return AnyView(view.foregroundStyle(resolved))
        case let .background(color):
            guard let resolved = BridgeValues.color(color) else {
                return AnyView(view.invalidParameter("background(\(color))"))
            }
            return AnyView(view.background(resolved))
        case let .frame(width, height, maxWidth, maxHeight, alignment):
            return frame(view, width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        case let .cornerRadius(radius):
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: BridgeValues.fixedLength(radius) ?? 0)))
        case let .opacity(value):
            return AnyView(view.opacity(value.isFinite ? min(max(value, 0), 1) : 1))
        case let .disabled(isDisabled):
            return AnyView(view.disabled(isDisabled))
        case let .hidden(isHidden):
            return isHidden ? AnyView(view.hidden()) : view
        case let .navigationTitle(title):
            return AnyView(view.navigationTitle(Text(verbatim: title)))
        case let .buttonStyle(name):
            return buttonStyle(view, name: name)
        case let .textFieldStyle(name):
            guard let style = BridgeTextFieldStyle(rawValue: name) else {
                return AnyView(view.invalidParameter("textFieldStyle(\"\(name)\")"))
            }
            return AnyView(view.environment(\.bridgeTextFieldStyle, style))
        case let .listStyle(name):
            return listStyle(view, name: name)
        case let .multilineTextAlignment(alignment):
            guard let resolved = BridgeValues.textAlignment(alignment) else {
                return AnyView(view.invalidParameter("multilineTextAlignment(.\(alignment.rawValue))"))
            }
            return AnyView(view.multilineTextAlignment(resolved))
        case let .lineLimit(limit):
            return AnyView(view.lineLimit(limit.map { max($0, 1) }))
        case .onAppear, .onDisappear, .task:
            // 生命周期 modifier 由 RenderNodeView 统一挂接（LifecycleHooks）：发送 .action 之外另发 .appear/.disappear(NodeID)，
            // 且每个节点只挂一次。这里不重复挂接，避免执行两次。
            return view
        case let .accessibilityLabel(label):
            return AnyView(view.accessibilityLabel(Text(verbatim: label)))
        case let .animation(kind, valueKey):
            return AnyView(view.animation(BridgeValues.animation(kind), value: valueKey))
        case let .tag(value):
            return AnyView(view.tag(value))
        }
    }

    private static func frame(_ view: AnyView, width: Double?, height: Double?, maxWidth: Double?, maxHeight: Double?,
                              alignment: StackAlignment?) -> AnyView {
        let align = alignment.map(BridgeValues.alignment) ?? .center
        var result = view
        let fixedWidth = BridgeValues.fixedLength(width)
        let fixedHeight = BridgeValues.fixedLength(height)
        if fixedWidth != nil || fixedHeight != nil {
            result = AnyView(result.frame(width: fixedWidth, height: fixedHeight, alignment: align))
        }
        let maxW = BridgeValues.maxLength(maxWidth)
        let maxH = BridgeValues.maxLength(maxHeight)
        if maxW != nil || maxH != nil {
            result = AnyView(result.frame(maxWidth: maxW, maxHeight: maxH, alignment: align))
        }
        let invalid = (width != nil && fixedWidth == nil) || (height != nil && fixedHeight == nil)
            || (maxWidth != nil && maxW == nil) || (maxHeight != nil && maxH == nil)
        return invalid ? AnyView(result.invalidParameter("frame（含负数或非有限尺寸）")) : result
    }

    private static func buttonStyle(_ view: AnyView, name: String) -> AnyView {
        switch name {
        case "bordered": AnyView(view.buttonStyle(.bordered))
        case "borderedProminent": AnyView(view.buttonStyle(.borderedProminent))
        case "plain": AnyView(view.buttonStyle(.plain))
        case "borderless": AnyView(view.buttonStyle(.borderless))
        default: AnyView(view.invalidParameter("buttonStyle(\"\(name)\")"))
        }
    }

    private static func listStyle(_ view: AnyView, name: String) -> AnyView {
        switch name {
        case "plain": return AnyView(view.listStyle(.plain))
        case "inset": return AnyView(view.listStyle(.inset))
        case "sidebar": return AnyView(view.listStyle(.sidebar))
        #if os(iOS)
        case "insetGrouped": return AnyView(view.listStyle(.insetGrouped))
        case "grouped": return AnyView(view.listStyle(.grouped))
        #endif
        default: return AnyView(view.invalidParameter("listStyle(\"\(name)\")"))
        }
    }
}

/// 桥接 TextField 的外观；由 `.textFieldStyle` modifier 通过环境值向下传递。
public enum BridgeTextFieldStyle: String, Sendable, CaseIterable {
    case roundedBorder
    case plain
}

extension EnvironmentValues {
    @Entry var bridgeTextFieldStyle: BridgeTextFieldStyle = .roundedBorder
}

extension View {
    /// 对无效参数叠加可见标记（非 nil 时）。不静默吞掉运行时给出的非法值。
    func invalidParameter(_ description: String?) -> some View {
        overlay(alignment: .topTrailing) {
            if let description {
                InvalidParameterBadge(description: description)
            }
        }
    }
}
