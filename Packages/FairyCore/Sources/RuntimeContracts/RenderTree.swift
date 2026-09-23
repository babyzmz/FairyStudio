import Foundation

/// 一次渲染快照。revision 单调递增；宿主只应用来自当前 RunID 的最新 revision。
public struct RenderTree: Sendable, Hashable, Codable {
    public var runID: RunID
    public var revision: UInt64
    public var root: RenderNode
    public init(runID: RunID, revision: UInt64, root: RenderNode) { self.runID = runID; self.revision = revision; self.root = root }
}

public struct RenderNode: Sendable, Hashable, Codable {
    public var id: NodeID
    public var kind: RenderKind
    public var modifiers: [RenderModifier]
    public var children: [RenderNode]
    public init(id: NodeID, kind: RenderKind, modifiers: [RenderModifier] = [], children: [RenderNode] = []) {
        self.id = id; self.kind = kind; self.modifiers = modifiers; self.children = children
    }
}

public enum StackAlignment: String, Sendable, Codable { case leading, center, trailing, top, bottom }
public enum ScrollAxes: String, Sendable, Codable { case vertical, horizontal, both }
public enum TextStyle: String, Sendable, Codable { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
public enum ImageSource: Sendable, Hashable, Codable { case systemName(String); case resource(String) }
public enum ButtonRole: String, Sendable, Codable { case destructive, cancel }

/// NativeBridge 预编译的组件清单。每个 case 的参数即桥接签名，禁止动态 selector。
public enum RenderKind: Sendable, Hashable, Codable {
    case text(String, style: TextStyle?)
    case image(ImageSource)
    case button(action: ActionID, role: ButtonRole?)          // label = children
    case textField(placeholder: String, binding: BindingID, text: String)
    case secureField(placeholder: String, binding: BindingID, text: String)
    case toggle(binding: BindingID, isOn: Bool)               // label = children
    case slider(binding: BindingID, value: Double, lower: Double, upper: Double, step: Double?)
    case stepper(binding: BindingID, value: Int, lower: Int?, upper: Int?)
    case picker(binding: BindingID, selected: TransferValue, options: [PickerOption])  // label = children
    case vstack(alignment: StackAlignment, spacing: Double?)
    case hstack(alignment: StackAlignment, spacing: Double?)
    case zstack(alignment: StackAlignment)
    case spacer(minLength: Double?)
    case divider
    case scrollView(ScrollAxes)
    case list                                                 // children = rows，行 id 来自 ForEach 稳定 id
    case section(header: String?, footer: String?)
    case form
    case group
    case navigationStack                                      // children[0] = root
    case navigationLink(destinationID: NodeID)                // label = children；目标由 runtime 按需渲染
    case navigationDestination(NodeID)                        // 由 runtime 推入的目标页面节点
    case sheetHost(isPresented: Bool, dismiss: ActionID)      // children = sheet content
    case alertHost(title: String, message: String?, isPresented: Bool, buttons: [AlertButton])
    case progressView(label: String?, value: Double?)
    case emptyView
    case unsupported(symbol: String, capabilityID: String)    // 合法但未实现：显示占位并产生诊断，不静默
}

public struct PickerOption: Sendable, Hashable, Codable {
    public var tag: TransferValue
    public var label: String
    public init(tag: TransferValue, label: String) { self.tag = tag; self.label = label }
}

public struct AlertButton: Sendable, Hashable, Codable {
    public var title: String
    public var role: ButtonRole?
    public var action: ActionID?
    public init(title: String, role: ButtonRole? = nil, action: ActionID? = nil) { self.title = title; self.role = role; self.action = action }
}

public struct ColorValue: Sendable, Hashable, Codable {
    public enum Named: String, Sendable, Codable { case primary, secondary, accent, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray, black, white, clear }
    public var named: Named?
    public var rgba: [Double]?   // [r,g,b,a] 0...1
    public init(named: Named) { self.named = named }
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.rgba = [r, g, b, a] }
}

public enum EdgeSet: String, Sendable, Codable { case all, horizontal, vertical, top, bottom, leading, trailing }
public enum FontWeight: String, Sendable, Codable { case regular, medium, semibold, bold, heavy }
public enum AnimationKind: String, Sendable, Codable { case `default`, easeIn, easeOut, easeInOut, linear, spring }

/// 桥接支持的 modifier 清单（M0 子集）。新增 modifier 必须同步 capability catalog 和测试。
public enum RenderModifier: Sendable, Hashable, Codable {
    case padding(EdgeSet, Double?)
    case font(TextStyle)
    case fontWeight(FontWeight)
    case bold
    case italic
    case foregroundColor(ColorValue)
    case background(ColorValue)
    case frame(width: Double?, height: Double?, maxWidth: Double?, maxHeight: Double?, alignment: StackAlignment?)
    case cornerRadius(Double)
    case opacity(Double)
    case disabled(Bool)
    case hidden(Bool)
    case navigationTitle(String)
    case buttonStyle(String)     // bordered / borderedProminent / plain / borderless
    case textFieldStyle(String)  // roundedBorder / plain
    case listStyle(String)       // plain / insetGrouped / grouped
    case multilineTextAlignment(StackAlignment)
    case lineLimit(Int?)
    case onAppear(ActionID)
    case onDisappear(ActionID)
    case task(ActionID)
    case accessibilityLabel(String)
    case animation(AnimationKind, valueKey: String)
    case tag(TransferValue)
}
