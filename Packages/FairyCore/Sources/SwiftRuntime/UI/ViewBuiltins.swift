import RuntimeContracts

/// SwiftUI 子集：内建视图构造与修饰符（运行期）。编译期签名见 BuiltinSignatures.swift。
enum ViewBuiltins {
    /// 解析方法全名中的参数标签：`frame(width:height:)` → ["width", "height"]，`padding(_:_:)` → [nil, nil]。
    static func labels(of fullName: String) -> (base: String, labels: [String?]) {
        guard let open = fullName.firstIndex(of: "(") else { return (fullName, []) }
        let base = String(fullName[..<open])
        let inner = fullName[fullName.index(after: open)..<(fullName.lastIndex(of: ")") ?? fullName.endIndex)]
        let parts = inner.split(separator: ":", omittingEmptySubsequences: true).map { $0 == "_" ? nil : String($0) }
        return (base, parts)
    }

    static func number(_ v: Value, _ what: String) throws -> Double {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .symbol("infinity"): return .infinity
        default: throw VMError.typeMismatch("\(what) 需要数值，实际是 '\(ValueOps.typeName(v))'。")
        }
    }

    static func string(_ v: Value, _ what: String) throws -> String {
        if case .string(let s) = v { return s }
        throw VMError.typeMismatch("\(what) 需要 String，实际是 '\(ValueOps.typeName(v))'。")
    }

    static func symbol(_ v: Value, _ what: String) throws -> String {
        switch v {
        case .symbol(let s): return s
        default: throw VMError.typeMismatch("\(what) 需要形如 .name 的常量，实际是 '\(ValueOps.typeName(v))'。")
        }
    }

    static func alignment(_ v: Value) throws -> StackAlignment {
        let s = try symbol(v, "alignment")
        guard let a = StackAlignment(rawValue: s) else {
            throw VMError.unsupported("对齐方式 .\(s)", capabilityID: "view.alignment.\(s)")
        }
        return a
    }

    static func color(_ v: Value) throws -> ColorValue {
        let s = try symbol(v, "颜色")
        if s.hasPrefix("rgb:") {
            let comps = s.dropFirst(4).split(separator: ",").compactMap { Double(String($0)) }
            if comps.count == 4 { return ColorValue(r: comps[0], g: comps[1], b: comps[2], a: comps[3]) }
        }
        if s == "accentColor" { return ColorValue(named: .accent) }
        guard let n = ColorValue.Named(rawValue: s) else {
            throw VMError.unsupported("颜色 .\(s)", capabilityID: "view.Color")
        }
        return ColorValue(named: n)
    }

    static func isView(_ vm: VM, _ v: Value) -> Bool {
        switch v {
        case .view: return true
        case .record(let r): return vm.program.types[r.type].isView
        default: return false
        }
    }

    static func requireView(_ vm: VM, _ v: Value, _ what: String) throws -> Value {
        guard isView(vm, v) else {
            throw VMError.typeMismatch("\(what) 需要一个 View，实际是 '\(ValueOps.typeName(v))'。")
        }
        return v
    }

    static func text(_ s: String) -> Value { .view(ViewNode(.text(s))) }

    // MARK: - 视图构造

    static func construct(_ vm: VM, _ name: String, labels: [String?], args: [Value]) throws -> Value? {
        func arg(_ label: String?) -> Value? {
            guard let i = labels.firstIndex(where: { $0 == label }) else { return nil }
            return args[i]
        }
        switch name {
        case "Text":
            if labels == [nil] || labels == ["verbatim"] { return text(try string(args[0], "Text")) }
        case "Button":
            let role: ButtonRole? = try arg("role").map { r -> ButtonRole in
                let s = try symbol(r, "role")
                guard let role = ButtonRole(rawValue: s) else { throw VMError.unsupported("按钮角色 .\(s)", capabilityID: "view.Button") }
                return role
            }
            if let action = arg("action") {
                if let title = arg(nil) {
                    return .view(ViewNode(.button(label: text(try string(title, "Button 标题")), action: action, role: role)))
                }
                if let label = arg("label") {
                    return .view(ViewNode(.button(label: try requireView(vm, label, "Button label"), action: action, role: role)))
                }
            }
        case "VStack", "HStack":
            guard let content = arg("content") else { break }
            let alignment = try arg("alignment").map(alignment) ?? .center
            let spacing = try arg("spacing").map { try number($0, "spacing") }
            return .view(ViewNode(.stack(name == "VStack" ? .v : .h, alignment: alignment, spacing: spacing, content: content)))
        case "ZStack":
            guard let content = arg("content") else { break }
            let alignment = try arg("alignment").map(alignment) ?? .center
            return .view(ViewNode(.stack(.z, alignment: alignment, spacing: nil, content: content)))
        case "Spacer":
            return .view(ViewNode(.spacer(try arg("minLength").map { try number($0, "minLength") })))
        case "Divider":
            return .view(ViewNode(.divider))
        case "EmptyView":
            return .view(ViewNode(.empty))
        case "TextField", "SecureField":
            guard let title = arg(nil), let binding = arg("text") else { break }
            guard case .binding = binding else { throw VMError.typeMismatch("\(name) 的 text: 需要 Binding（使用 $变量）。") }
            return .view(ViewNode(.textField(placeholder: try string(title, name), binding: binding, secure: name == "SecureField")))
        case "Toggle":
            guard let binding = arg("isOn") else { break }
            guard case .binding = binding else { throw VMError.typeMismatch("Toggle 的 isOn: 需要 Binding（使用 $变量）。") }
            if let title = arg(nil) {
                return .view(ViewNode(.toggle(label: text(try string(title, "Toggle 标题")), binding: binding)))
            }
            if let label = arg("label") { return .view(ViewNode(.toggle(label: label, binding: binding))) }
        case "ForEach":
            guard let data = arg(nil), let content = arg("content") else { break }
            return try forEach(vm, data: data, id: arg("id"), content: content)
        case "List":
            if let data = arg(nil), let row = arg("rowContent") {
                let fe = try forEach(vm, data: data, id: arg("id"), content: row)
                return .view(ViewNode(.list(content: fe)))
            }
            if let content = arg("content") { return .view(ViewNode(.list(content: content))) }
        case "NavigationStack", "NavigationView":
            if let content = arg("content") {
                if let p = arg("path") {
                    guard case .binding = p else { throw VMError.typeMismatch("NavigationStack 的 path: 需要 Binding（使用 $path，元素为 [String]）。") }
                    return .view(ViewNode(.navigationStack(content: content, path: p)))
                }
                return .view(ViewNode(.navigationStack(content: content, path: nil)))
            }
        case "NavigationLink":
            // 值导航（B-2：String/Int）与目标闭包导航（destination 按稳定 id 注册）
            if let dest = arg("destination") {
                let label: Value
                if let t = arg(nil) { label = text(try string(t, "NavigationLink 标题")) }
                else if let l = arg("label") { label = try requireView(vm, l, "NavigationLink label") }
                else { break }
                return .view(ViewNode(.navigationLink(destinationKey: "link", value: dest, label: label)))
            }
            if let v = arg("value") {
                let dv = try deref(v)
                let key: String
                switch dv {
                case .string: key = "String"
                case .int: key = "Int"
                default:
                    throw VMError.typeMismatch("NavigationLink 的 value: 只支持 String/Int（实际是 '\(ValueOps.typeName(v))'）。")
                }
                let label: Value
                if let t = arg(nil) { label = text(try string(t, "NavigationLink 标题")) }
                else if let l = arg("label") { label = try requireView(vm, l, "NavigationLink label") }
                else { break }
                return .view(ViewNode(.navigationLink(destinationKey: key, value: dv, label: label)))
            }
        case "ScrollView":
            guard let content = arg("content") else { break }
            var axes = ScrollAxes.vertical
            if let a = arg(nil) {
                let s = try symbol(a, "ScrollView 轴")
                axes = ScrollAxes(rawValue: s) ?? .vertical
            }
            return .view(ViewNode(.scrollView(axes, content: content)))
        case "Group":
            if let content = arg("content") { return .view(ViewNode(.explicitGroup(content: content))) }
        case "Form":
            if let content = arg("content") { return .view(ViewNode(.form(content: content))) }
        case "Section":
            guard let content = arg("content") else { break }
            let header = try arg(nil).map { try string($0, "Section 标题") } ?? (try arg("header").map { try string($0, "Section header") })
            let footer = try arg("footer").map { try string($0, "Section footer") }
            return .view(ViewNode(.section(header: header, footer: footer, content: content)))
        case "Image":
            if let n = arg("systemName") { return .view(ViewNode(.image(.systemName(try string(n, "systemName"))))) }
            if let n = arg(nil) { return .view(ViewNode(.image(.resource(try string(n, "Image"))))) }
        case "Slider":
            guard let binding = arg("value"), let range = arg("in") else { break }
            guard case .binding = binding else { throw VMError.typeMismatch("Slider 的 value: 需要 Binding<Double>（使用 $变量）。") }
            guard case .range(let r) = range, r.closed else {
                throw VMError.typeMismatch("Slider 的 in: 需要闭区间（如 0...100），实际是 '\(ValueOps.typeName(range))'。")
            }
            let step = try arg("step").map { try number($0, "step") }
            return .view(ViewNode(.slider(binding: binding, lower: Double(r.lower), upper: Double(r.upper), step: step)))
        case "Stepper":
            guard let binding = arg("value") else { break }
            guard case .binding = binding else { throw VMError.typeMismatch("Stepper 的 value: 需要 Binding<Int>（使用 $变量）。") }
            var lower: Int?, upper: Int?
            if let range = arg("in") {
                guard case .range(let r) = range, r.closed else {
                    throw VMError.typeMismatch("Stepper 的 in: 需要闭区间（如 0...10）。")
                }
                lower = r.lower
                upper = r.upper
            }
            let label: Value
            if let t = arg(nil) { label = text(try string(t, "Stepper 标题")) }
            else if let l = arg("label") { label = try requireView(vm, l, "Stepper label") }
            else { break }
            return .view(ViewNode(.stepper(label: label, binding: binding, lower: lower, upper: upper)))
        case "Picker":
            guard let binding = arg("selection"), let content = arg("content") else { break }
            guard case .binding = binding else { throw VMError.typeMismatch("Picker 的 selection: 需要 Binding（使用 $变量）。") }
            let label: Value
            if let t = arg(nil) { label = text(try string(t, "Picker 标题")) }
            else if let l = arg("label") { label = try requireView(vm, l, "Picker label") }
            else { break }
            return .view(ViewNode(.picker(label: label, binding: binding, content: content)))
        case "ProgressView":
            let label = try arg(nil).map { try string($0, "ProgressView 标题") }
            let value = try arg("value").map { try number($0, "value") }
            // total：原生 ProgressView(value:total:) 语义，归一化为 0...1 的比例。
            var fraction = value
            if let v = value, let t = try arg("total").map({ try number($0, "total") }), t > 0 {
                fraction = min(1.0, max(0.0, v / t))
            }
            return .view(ViewNode(.progress(label: label, value: fraction)))
        case "Color":
            if let r = arg("red"), let g = arg("green"), let b = arg("blue") {
                let a = try arg("opacity").map { try number($0, "opacity") } ?? 1
                return .symbol("rgb:\(try number(r, "red")),\(try number(g, "green")),\(try number(b, "blue")),\(a)")
            }
        default:
            return nil
        }
        throw VMError.typeMismatch("\(name)(\(labels.map { ($0 ?? "_") + ":" }.joined())) 的参数不受支持。")
    }

    static func forEach(_ vm: VM, data: Value, id: Value?, content: Value) throws -> Value {
        var idPath: [String]? = nil
        if let id {
            guard case .keyPath(let p) = id else { throw VMError.typeMismatch("ForEach 的 id: 需要 KeyPath（如 \\.self 或 \\.id）。") }
            idPath = p
        }
        let elems: [Value]
        switch data {
        case .range(let r):
            try vm.meter.checkCollection(r.count)
            elems = (r.lower..<r.endExclusive).map { .int($0) }
            if idPath == nil { idPath = [] }
        case .array(let a):
            elems = a
        default:
            throw VMError.typeMismatch("ForEach 的数据需要数组或 Range，实际是 '\(ValueOps.typeName(data))'。")
        }
        return .view(ViewNode(.forEach(data: elems, idPath: idPath, content: content)))
    }

    /// `.sheet(isPresented:onDismiss:content:)`（B-3 子集）：isPresented Binding + 内容闭包（+ 可选 onDismiss）。
    static func sheetModifier(_ recv: Value, labels: [String?], args: [Value]) throws -> Value {
        func arg(_ label: String?) -> Value? {
            guard let i = labels.firstIndex(where: { $0 == label }) else { return nil }
            return args[i]
        }
        guard let presented = arg("isPresented"), let content = arg("content") else {
            throw VMError.typeMismatch(".sheet 需要 isPresented: 与内容闭包，例如 `.sheet(isPresented: $flag) { … }`。")
        }
        guard case .binding = presented else { throw VMError.typeMismatch(".sheet 的 isPresented: 需要 Binding<Bool>（使用 $变量）。") }
        return .view(ViewNode(.modified(recv, .sheet(isPresented: presented, content: content, onDismiss: arg("onDismiss")))))
    }

    /// `.alert(title:isPresented:actions:message:)`（B-4 子集）：标题 + Binding + 按钮闭包 + 可选消息闭包。
    static func alertModifier(_ recv: Value, labels: [String?], args: [Value]) throws -> Value {
        func arg(_ label: String?) -> Value? {
            guard let i = labels.firstIndex(where: { $0 == label }) else { return nil }
            return args[i]
        }
        guard let title = arg(nil), let presented = arg("isPresented"), let actions = arg("actions") else {
            throw VMError.typeMismatch(".alert 需要标题、isPresented: 与按钮闭包，例如 `.alert(\"T\", isPresented: $f) { … } message: { … }`。")
        }
        guard case .binding = presented else { throw VMError.typeMismatch(".alert 的 isPresented: 需要 Binding<Bool>（使用 $变量）。") }
        return .view(ViewNode(.modified(recv, .alert(title: try string(title, ".alert 标题"), isPresented: presented,
                                                actions: actions, message: arg("message")))))
    }

    // MARK: - 修饰符
    static func modifier(_ vm: VM, _ recv: Value, _ fullName: String, _ args: [Value]) throws -> Value? {
        guard isView(vm, recv) else { return nil }
        let (base, labels) = labels(of: fullName)
        func arg(_ label: String?) -> Value? {
            guard let i = labels.firstIndex(where: { $0 == label }) else { return nil }
            return args[i]
        }
        func wrap(_ m: RenderModifier) -> Value { .view(ViewNode(.modified(recv, .render(m)))) }
        switch base {
        case "padding":
            switch args.count {
            case 0: return wrap(.padding(.all, nil))
            case 1:
                if case .symbol(let s) = args[0] {
                    guard let e = EdgeSet(rawValue: s) else { throw VMError.unsupported("padding 边 .\(s)", capabilityID: "modifier.padding") }
                    return wrap(.padding(e, nil))
                }
                return wrap(.padding(.all, try number(args[0], "padding")))
            case 2:
                let s = try symbol(args[0], "padding 边")
                guard let e = EdgeSet(rawValue: s) else { throw VMError.unsupported("padding 边 .\(s)", capabilityID: "modifier.padding") }
                return wrap(.padding(e, try number(args[1], "padding")))
            default: break
            }
        case "font":
            let s = try symbol(args[0], "font")
            guard let style = TextStyle(rawValue: s) else {
                throw VMError.unsupported("字体 .\(s)（只支持文本样式如 .title、.body）", capabilityID: "modifier.font")
            }
            return wrap(.font(style))
        case "fontWeight":
            let s = try symbol(args[0], "fontWeight")
            guard let w = FontWeight(rawValue: s) else { throw VMError.unsupported("字重 .\(s)", capabilityID: "modifier.fontWeight") }
            return wrap(.fontWeight(w))
        case "bold": return wrap(.bold)
        case "italic": return wrap(.italic)
        case "foregroundColor", "foregroundStyle", "tint":
            return wrap(.foregroundColor(try color(args[0])))
        case "background":
            return wrap(.background(try color(args[0])))
        case "frame":
            var width: Double?, height: Double?, maxWidth: Double?, maxHeight: Double?
            var align: StackAlignment?
            for (i, l) in labels.enumerated() {
                switch l {
                case "width": width = try number(args[i], "width")
                case "height": height = try number(args[i], "height")
                case "maxWidth": maxWidth = try number(args[i], "maxWidth")
                case "maxHeight": maxHeight = try number(args[i], "maxHeight")
                case "alignment": align = try alignment(args[i])
                default: throw VMError.unsupported("frame 参数 \(l ?? "_")", capabilityID: "modifier.frame")
                }
            }
            return wrap(.frame(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight, alignment: align))
        case "cornerRadius": return wrap(.cornerRadius(try number(args[0], "cornerRadius")))
        case "opacity": return wrap(.opacity(try number(args[0], "opacity")))
        case "disabled": return wrap(.disabled(try ValueOps.truthy(args[0])))
        case "hidden": return wrap(.hidden(true))
        case "navigationTitle": return wrap(.navigationTitle(try string(args[0], "navigationTitle")))
        case "buttonStyle": return wrap(.buttonStyle(try symbol(args[0], "buttonStyle")))
        case "textFieldStyle": return wrap(.textFieldStyle(try symbol(args[0], "textFieldStyle")))
        case "listStyle": return wrap(.listStyle(try symbol(args[0], "listStyle")))
        case "multilineTextAlignment": return wrap(.multilineTextAlignment(try alignment(args[0])))
        case "lineLimit":
            if case .none = args[0] { return wrap(.lineLimit(nil)) }
            guard case .int(let n) = args[0] else { throw VMError.typeMismatch("lineLimit 需要 Int。") }
            return wrap(.lineLimit(n))
        case "accessibilityLabel": return wrap(.accessibilityLabel(try string(args[0], "accessibilityLabel")))
        case "tag":
            return wrap(.tag(try TransferConvert.toTransfer(vm, args[0])))
        case "onAppear":
            if let f = arg("perform") { return .view(ViewNode(.modified(recv, .onAppear(f)))) }
        case "onDisappear":
            if let f = arg("perform") { return .view(ViewNode(.modified(recv, .onDisappear(f)))) }
        case "task":
            if let f = arg(nil) { return .view(ViewNode(.modified(recv, .task(f)))) }
        case "pickerStyle":
            // 样式透传：segmented/menu/automatic 直接通过（桥接按默认样式渲染，见能力备注）
            let s = try symbol(args[0], "pickerStyle")
            guard s == "segmented" || s == "menu" || s == "automatic" else {
                throw VMError.unsupported("pickerStyle .\(s)（只支持 .segmented/.menu/.automatic）",
                                          capabilityID: "modifier.pickerStyle")
            }
            return recv
        case "navigationDestination":
            guard labels == ["for", nil], args.count == 2 else { break }
            let t = try symbol(args[0], "navigationDestination(for:)")
            guard t == "String" || t == "Int" else {
                throw VMError.typeMismatch("navigationDestination(for:) 只支持 String.self / Int.self（实际是 \(t).self）。")
            }
            return .view(ViewNode(.modified(recv, .navigationDestination(typeName: t, builder: args[1]))))
        case "sheet":
            return try sheetModifier(recv, labels: labels, args: args)
        case "alert":
            return try alertModifier(recv, labels: labels, args: args)
        default:
            break
        }
        throw VMError.unsupported("修饰符 .\(fullName)", capabilityID: "modifier.\(base)")
    }
}

/// 运行期值 ↔ TransferValue。
enum TransferConvert {
    static func toTransfer(_ vm: VM, _ v: Value) throws -> TransferValue {
        switch try deref(v) {
        case .none: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(try a.map { try toTransfer(vm, $0) })
        case .enumCase(let t, let i, let p):
            if !p.isEmpty { throw VMError.typeMismatch("带关联值的 enum 不能传给宿主。") }
            return .string(vm.program.types[t].caseNames[i])
        case .dict(let d):
            var out: [String: TransferValue] = [:]
            for (i, k) in d.keys.enumerated() {
                guard case .string(let ks) = k else { throw VMError.typeMismatch("只有 String 键的字典可以传给宿主。") }
                out[ks] = try toTransfer(vm, d.values[i])
            }
            return .dictionary(out)
        case .record(let r):
            let info = vm.program.types[r.type]
            var out: [String: TransferValue] = [:]
            for (i, n) in info.fieldNames.enumerated() { out[n] = try toTransfer(vm, r.fields[i]) }
            return .dictionary(out)
        default:
            throw VMError.typeMismatch("'\(ValueOps.typeName(v))' 不能传给宿主。")
        }
    }

    /// 宿主写入的值 → 运行期值，按当前值的形态校验（setBinding）。
    static func fromTransfer(_ t: TransferValue, matching current: Value) throws -> Value {
        switch (t, current) {
        case (.string(let s), .string): return .string(s)
        case (.bool(let b), .bool): return .bool(b)
        case (.int(let i), .int): return .int(i)
        case (.double(let d), .double): return .double(d)
        case (.int(let i), .double): return .double(Double(i))
        case (.double(let d), .int):
            guard d.rounded() == d, d.isFinite, abs(d) < 9.0e18 else { throw VMError.typeMismatch("绑定需要整数。") }
            return .int(Int(d))
        case (.null, .none): return .none
        case (.string(let s), .none): return .string(s)
        default:
            throw VMError.typeMismatch("宿主写入的值类型与绑定不匹配。")
        }
    }
}
