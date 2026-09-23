import SwiftUI
import RuntimeContracts

/// 契约值 → SwiftUI 值的纯映射。无法表示的值返回 nil，由调用方显示可见的「无效参数」标记。
enum BridgeValues {
    static func font(_ style: TextStyle) -> Font {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    static func weight(_ weight: FontWeight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    static func color(_ value: ColorValue) -> Color? {
        if let named = value.named {
            return namedColor(named)
        }
        if let rgba = value.rgba, rgba.count == 4, rgba.allSatisfy({ $0.isFinite }) {
            return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
        }
        return nil
    }

    private static func namedColor(_ named: ColorValue.Named) -> Color {
        switch named {
        case .primary: .primary
        case .secondary: .secondary
        case .accent: .accentColor
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        case .black: .black
        case .white: .white
        case .clear: .clear
        }
    }

    static func edges(_ set: EdgeSet) -> Edge.Set {
        switch set {
        case .all: .all
        case .horizontal: .horizontal
        case .vertical: .vertical
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    static func alignment(_ value: StackAlignment) -> Alignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// VStack 只接受水平对齐；top / bottom 对 VStack 无意义，返回 nil。
    static func horizontal(_ value: StackAlignment) -> HorizontalAlignment? {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .top, .bottom: nil
        }
    }

    /// HStack 只接受垂直对齐；leading / trailing 对 HStack 无意义，返回 nil。
    static func vertical(_ value: StackAlignment) -> VerticalAlignment? {
        switch value {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        case .leading, .trailing: nil
        }
    }

    static func textAlignment(_ value: StackAlignment) -> TextAlignment? {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .top, .bottom: nil
        }
    }

    static func role(_ role: RuntimeContracts.ButtonRole?) -> SwiftUI.ButtonRole? {
        switch role {
        case .destructive: .destructive
        case .cancel: .cancel
        case nil: nil
        }
    }

    static func animation(_ kind: AnimationKind) -> Animation {
        switch kind {
        case .default: .default
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        case .easeInOut: .easeInOut
        case .linear: .linear
        case .spring: .spring
        }
    }

    /// 尺寸：负数、NaN 视为无效（nil）；固定尺寸不接受无穷大。
    static func fixedLength(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return CGFloat(value)
    }

    /// 最大尺寸：允许 .infinity（对应 SwiftUI 的 maxWidth: .infinity）。
    static func maxLength(_ value: Double?) -> CGFloat? {
        guard let value, !value.isNaN, value >= 0 else { return nil }
        return CGFloat(value)
    }

    static func spacing(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return CGFloat(value)
    }
}
