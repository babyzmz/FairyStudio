import SwiftUI
import RuntimeContracts

/// 单个 RenderNode 的渲染：先按 kind 选择预编译组件，再按顺序应用 modifier。
struct RenderNodeView: View {
    let node: RenderNode
    let send: BridgeSend

    var body: some View {
        if node.modifiers.isEmpty {
            NodeContent(node: node, send: send)
        } else {
            ModifierChain.apply(node.modifiers, to: AnyView(NodeContent(node: node, send: send)), send: send)
        }
    }
}

/// kind → 组件。每个分支只做参数换算，交互组件的状态逻辑放在 Components/ 下的独立视图里。
private struct NodeContent: View {
    let node: RenderNode
    let send: BridgeSend

    var body: some View {
        switch node.kind {
        case let .text(string, style):
            Text(verbatim: string)
                .font(style.map(BridgeValues.font))
                .accessibilityIdentifier(node.id.rawValue)
        case let .image(source):
            BridgeImage(source: source)
        case let .button(action, role):
            Button(role: BridgeValues.role(role)) {
                send(.action(action))
            } label: {
                ChildNodes(children: node.children, send: send)
            }
            .accessibilityIdentifier(node.id.rawValue)
        case let .textField(placeholder, binding, text):
            BridgeTextInput(placeholder: placeholder, binding: binding, runtimeText: text, isSecure: false, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .secureField(placeholder, binding, text):
            BridgeTextInput(placeholder: placeholder, binding: binding, runtimeText: text, isSecure: true, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .toggle(binding, isOn):
            BridgeToggle(binding: binding, runtimeValue: isOn, label: node.children, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .slider(binding, value, lower, upper, step):
            BridgeSlider(binding: binding, runtimeValue: value, lower: lower, upper: upper, step: step, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .stepper(binding, value, lower, upper):
            BridgeStepper(binding: binding, value: value, lower: lower, upper: upper, label: node.children, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .picker(binding, selected, options):
            BridgePicker(binding: binding, runtimeValue: selected, options: options, label: node.children, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case let .vstack(alignment, spacing):
            BridgeVStack(alignment: alignment, spacing: spacing, children: node.children, send: send)
        case let .hstack(alignment, spacing):
            BridgeHStack(alignment: alignment, spacing: spacing, children: node.children, send: send)
        case let .zstack(alignment):
            ZStack(alignment: BridgeValues.alignment(alignment)) {
                ChildNodes(children: node.children, send: send)
            }
        case let .spacer(minLength):
            Spacer(minLength: BridgeValues.spacing(minLength))
        case .divider:
            Divider()
        case let .scrollView(axes):
            ScrollView(scrollAxes(axes)) {
                ChildNodes(children: node.children, send: send)
            }
        case .list:
            List {
                ChildNodes(children: node.children, send: send)
            }
        case let .section(header, footer):
            BridgeSection(header: header, footer: footer, children: node.children, send: send)
        case .form:
            Form {
                ChildNodes(children: node.children, send: send)
            }
        case .group:
            Group {
                ChildNodes(children: node.children, send: send)
            }
        case .navigationStack:
            BridgeNavigationStack(node: node, send: send)
        case let .navigationLink(destinationID):
            BridgeNavigationLink(destinationID: destinationID, label: node.children, send: send)
                .accessibilityIdentifier(node.id.rawValue)
        case .navigationDestination:
            // 目标页面内容；正常情况下由 BridgeNavigationStack 在 navigationDestination(for:) 中渲染。
            Group {
                ChildNodes(children: node.children, send: send)
            }
        case let .sheetHost(isPresented, dismiss):
            BridgeSheetHost(isPresented: isPresented, dismiss: dismiss, content: node.children, send: send)
        case let .alertHost(title, message, isPresented, buttons):
            BridgeAlertHost(title: title, message: message, isPresented: isPresented, buttons: buttons, send: send)
        case let .progressView(label, value):
            BridgeProgress(label: label, value: value)
                .accessibilityIdentifier(node.id.rawValue)
        case .emptyView:
            EmptyView()
        case let .unsupported(symbol, capabilityID):
            UnsupportedNodeView(symbol: symbol, capabilityID: capabilityID)
        }
    }

    private func scrollAxes(_ axes: ScrollAxes) -> Axis.Set {
        switch axes {
        case .vertical: .vertical
        case .horizontal: .horizontal
        case .both: [.vertical, .horizontal]
        }
    }
}

private struct BridgeVStack: View {
    let alignment: StackAlignment
    let spacing: Double?
    let children: [RenderNode]
    let send: BridgeSend

    var body: some View {
        let resolved = BridgeValues.horizontal(alignment)
        VStack(alignment: resolved ?? .center, spacing: BridgeValues.spacing(spacing)) {
            ChildNodes(children: children, send: send)
        }
        .invalidParameter(resolved == nil ? "VStack(alignment: .\(alignment.rawValue))" : nil)
    }
}

private struct BridgeHStack: View {
    let alignment: StackAlignment
    let spacing: Double?
    let children: [RenderNode]
    let send: BridgeSend

    var body: some View {
        let resolved = BridgeValues.vertical(alignment)
        HStack(alignment: resolved ?? .center, spacing: BridgeValues.spacing(spacing)) {
            ChildNodes(children: children, send: send)
        }
        .invalidParameter(resolved == nil ? "HStack(alignment: .\(alignment.rawValue))" : nil)
    }
}

private struct BridgeSection: View {
    let header: String?
    let footer: String?
    let children: [RenderNode]
    let send: BridgeSend

    var body: some View {
        Section {
            ChildNodes(children: children, send: send)
        } header: {
            if let header { Text(verbatim: header) }
        } footer: {
            if let footer { Text(verbatim: footer) }
        }
    }
}

private struct BridgeImage: View {
    let source: ImageSource

    var body: some View {
        switch source {
        case let .systemName(name):
            Image(systemName: name)
                .accessibilityLabel(Text(verbatim: name))
        case let .resource(name):
            // M0 尚无项目资源存储（ProjectCore 在 M1），不静默显示空白。
            UnsupportedNodeView(symbol: "Image(\"\(name)\")", capabilityID: "view.Image.resource")
        }
    }
}

private struct BridgeProgress: View {
    let label: String?
    let value: Double?

    var body: some View {
        if let value, value.isFinite {
            ProgressView(value: min(max(value, 0), 1)) {
                if let label { Text(verbatim: label) }
            }
        } else {
            ProgressView {
                if let label { Text(verbatim: label) }
            }
        }
    }
}
