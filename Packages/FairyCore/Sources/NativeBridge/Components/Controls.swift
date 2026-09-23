import SwiftUI
import RuntimeContracts

// 交互控件：本地先行显示用户操作（避免等待运行时回写造成闪烁）；运行时给出新 revision 后以运行时值为准。
// 所有回传都是强类型 RuntimeInput.setBinding(BindingID, TransferValue)。

struct BridgeToggle: View {
    let binding: BindingID
    let runtimeValue: Bool
    let label: [RenderNode]
    let send: BridgeSend
    @Environment(\.bridgeRevision) private var revision
    @State private var local: Bool?

    var body: some View {
        Toggle(isOn: Binding(
            get: { local ?? runtimeValue },
            set: { newValue in
                local = newValue
                send(.setBinding(binding, .bool(newValue)))
            }
        )) {
            ChildNodes(children: label, send: send)
        }
        .onChange(of: revision) { _, _ in local = nil }
    }
}

struct BridgeSlider: View {
    let binding: BindingID
    let runtimeValue: Double
    let lower: Double
    let upper: Double
    let step: Double?
    let send: BridgeSend
    @Environment(\.bridgeRevision) private var revision
    @State private var local: Double?
    @State private var isEditing = false

    var body: some View {
        if let range = SliderRange(lower: lower, upper: upper) {
            let value = Binding(
                get: { local ?? min(max(runtimeValue.isFinite ? runtimeValue : range.lower, range.lower), range.upper) },
                set: { newValue in
                    local = newValue
                    send(.setBinding(binding, .double(newValue)))
                }
            )
            Group {
                if let step, step.isFinite, step > 0 {
                    Slider(value: value, in: range.lower...range.upper, step: step) { isEditing = $0 }
                } else {
                    Slider(value: value, in: range.lower...range.upper) { isEditing = $0 }
                }
            }
            // 拖动中保留本地值，避免运行时回写的旧值让滑块抖动。
            .onChange(of: revision) { _, _ in if !isEditing { local = nil } }
        } else {
            UnsupportedNodeView(symbol: "Slider(in: \(lower)...\(upper))", capabilityID: "view.Slider.invalidRange")
        }
    }
}

/// Slider 的合法区间：两端有限且 lower < upper。
struct SliderRange: Equatable {
    let lower: Double
    let upper: Double

    init?(lower: Double, upper: Double) {
        guard lower.isFinite, upper.isFinite, lower < upper else { return nil }
        self.lower = lower
        self.upper = upper
    }
}

struct BridgeStepper: View {
    let binding: BindingID
    let value: Int
    let lower: Int?
    let upper: Int?
    let label: [RenderNode]
    let send: BridgeSend
    @Environment(\.bridgeRevision) private var revision
    /// 连续点击时以本地值为基准，避免在运行时回写前重复发送同一个值。
    @State private var local: Int?

    var body: some View {
        Stepper {
            ChildNodes(children: label, send: send)
        } onIncrement: {
            if let next = StepperMath.increment(local ?? value, upper: upper) {
                local = next
                send(.setBinding(binding, .int(next)))
            }
        } onDecrement: {
            if let next = StepperMath.decrement(local ?? value, lower: lower) {
                local = next
                send(.setBinding(binding, .int(next)))
            }
        }
        .onChange(of: revision) { _, _ in local = nil }
    }
}

/// Stepper 边界计算；越界或溢出时返回 nil（不回传）。
enum StepperMath {
    static func increment(_ value: Int, upper: Int?) -> Int? {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { return nil }
        if let upper, next > upper { return nil }
        return next
    }

    static func decrement(_ value: Int, lower: Int?) -> Int? {
        let (next, overflow) = value.subtractingReportingOverflow(1)
        guard !overflow else { return nil }
        if let lower, next < lower { return nil }
        return next
    }
}

struct BridgePicker: View {
    let binding: BindingID
    let runtimeValue: TransferValue
    let options: [PickerOption]
    let label: [RenderNode]
    let send: BridgeSend
    @Environment(\.bridgeRevision) private var revision
    @State private var local: TransferValue?

    var body: some View {
        Picker(selection: Binding(
            get: { local ?? runtimeValue },
            set: { newValue in
                local = newValue
                send(.setBinding(binding, newValue))
            }
        )) {
            ForEach(options, id: \.tag) { option in
                Text(verbatim: option.label).tag(option.tag)
            }
        } label: {
            ChildNodes(children: label, send: send)
        }
        .onChange(of: revision) { _, _ in local = nil }
    }
}
