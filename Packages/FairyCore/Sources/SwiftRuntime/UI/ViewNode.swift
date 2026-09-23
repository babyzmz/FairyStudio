import RuntimeContracts

enum StackKind: String { case v, h, z }

/// 视图修饰符的运行期值。含闭包的修饰符（onAppear/task）在渲染时注册为 ActionID。
enum ModifierValue {
    case render(RenderModifier)
    case onAppear(Value)
    case onDisappear(Value)
    case task(Value)
}

/// 内建 SwiftUI 视图的描述值（不可变）。自定义 View 以 `.record` 表示，渲染时求值其 body。
final class ViewNode {
    enum Kind {
        case text(String)
        case button(label: Value, action: Value, role: ButtonRole?)
        case stack(StackKind, alignment: StackAlignment, spacing: Double?, content: Value)
        case spacer(Double?)
        case divider
        case textField(placeholder: String, binding: Value, secure: Bool)
        case toggle(label: Value, binding: Value)
        case forEach(data: [Value], idPath: [String]?, content: Value)
        case list(content: Value)
        case navigationStack(content: Value)
        case scrollView(ScrollAxes, content: Value)
        case form(content: Value)
        case section(header: String?, content: Value)
        case explicitGroup(content: Value)
        case image(ImageSource)
        case progress(label: String?, value: Double?)
        /// @ViewBuilder 中多条语句组成的视图序列（TupleView）
        case group([Value])
        /// @ViewBuilder 中 if/else、switch 的分支：分支号参与身份路径
        case conditional(Int, Value)
        case empty
        case modified(Value, ModifierValue)
        case unsupported(symbol: String, capabilityID: String)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}
