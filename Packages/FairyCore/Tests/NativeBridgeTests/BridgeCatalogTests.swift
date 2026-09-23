import Testing
import RuntimeContracts
@testable import NativeBridge

@Suite("桥接映射表完整性")
struct BridgeCatalogTests {
    @Test("每个 RenderKind 都有映射，标签名与契约 case 名一致")
    func renderKindTableIsComplete() {
        var seen = Set<RenderKindTag>()
        for kind in Samples.allKinds {
            let tag = RenderKindTag.tag(of: kind)
            #expect(tag.rawValue == RenderKindTagName.name(of: kind), "标签 \(tag) 与 case 名 \(RenderKindTagName.name(of: kind)) 不一致")
            #expect(!tag.swiftUIComponent.isEmpty)
            seen.insert(tag)
        }
        #expect(seen == Set(RenderKindTag.allCases), "样例未覆盖：\(Set(RenderKindTag.allCases).subtracting(seen))")
        #expect(Samples.allKinds.count == RenderKindTag.allCases.count)
    }

    @Test("每个 RenderModifier 都有映射，标签名与契约 case 名一致")
    func renderModifierTableIsComplete() {
        var seen = Set<RenderModifierTag>()
        for modifier in Samples.allModifiers {
            let tag = RenderModifierTag.tag(of: modifier)
            #expect(tag.rawValue == RenderKindTagName.name(of: modifier))
            #expect(!tag.swiftUIModifier.isEmpty)
            seen.insert(tag)
        }
        #expect(seen == Set(RenderModifierTag.allCases), "样例未覆盖：\(Set(RenderModifierTag.allCases).subtracting(seen))")
        #expect(Samples.allModifiers.count == RenderModifierTag.allCases.count)
    }

    @Test("数值换算：非法尺寸与区间不会被当作合法值")
    func valueSanitizing() {
        #expect(BridgeValues.fixedLength(-1) == nil)
        #expect(BridgeValues.fixedLength(.nan) == nil)
        #expect(BridgeValues.fixedLength(.infinity) == nil)
        #expect(BridgeValues.maxLength(.infinity) == .infinity)
        #expect(BridgeValues.fixedLength(12) == 12)
        #expect(SliderRange(lower: 0, upper: 0) == nil)
        #expect(SliderRange(lower: 5, upper: 1) == nil)
        #expect(SliderRange(lower: 0, upper: .infinity) == nil)
        #expect(SliderRange(lower: 0, upper: 1) != nil)
        #expect(BridgeValues.horizontal(.top) == nil)
        #expect(BridgeValues.vertical(.leading) == nil)
        #expect(BridgeValues.color(ColorValue(named: .blue)) != nil)
    }

    @Test("Stepper 边界与溢出不回传")
    func stepperMath() {
        #expect(StepperMath.increment(2, upper: 3) == 3)
        #expect(StepperMath.increment(3, upper: 3) == nil)
        #expect(StepperMath.decrement(0, lower: 0) == nil)
        #expect(StepperMath.decrement(1, lower: nil) == 0)
        #expect(StepperMath.increment(.max, upper: nil) == nil)
        #expect(StepperMath.decrement(.min, lower: nil) == nil)
    }
}
