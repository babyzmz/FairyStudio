import RuntimeContracts

enum StackKind: String { case v, h, z }

/// 视图修饰符的运行期值。含闭包的修饰符（onAppear/task）在渲染时注册为 ActionID。
enum ModifierValue {
    case render(RenderModifier)
    case onAppear(Value)
    case onDisappear(Value)
    case task(Value)
    /// navigationDestination 目标注册（B-2）：求值时登记类型→内容闭包，视图本身透传。
    case navigationDestination(typeName: String, builder: Value)
    /// sheet 呈现（B-3）：isPresented Binding + 内容闭包（+ 可选 onDismiss）。
    case sheet(isPresented: Value, content: Value, onDismiss: Value?)
    /// alert 呈现（B-4）：标题 + isPresented Binding + 按钮闭包 + 可选消息闭包。
    case alert(title: String, isPresented: Value, actions: Value, message: Value?)
}

/// 导航栈内的一个已推入目标（运行时权威路径）。
struct NavEntry {
    /// 注册键："String"/"Int"（for: 目标）或 "link:<destinationID>"（destination 闭包链接）。
    var key: String
    var value: Value
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
        case slider(binding: Value, lower: Double, upper: Double, step: Double?)
        case stepper(label: Value, binding: Value, lower: Int?, upper: Int?)
        case picker(label: Value, binding: Value, content: Value)
        case forEach(data: [Value], idPath: [String]?, content: Value)
        case list(content: Value)
        case navigationStack(content: Value, path: Value?)
        case navigationLink(destinationKey: String, value: Value?, label: Value)
        case scrollView(ScrollAxes, content: Value)
        case form(content: Value)
        case section(header: String?, footer: String?, content: Value)
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
