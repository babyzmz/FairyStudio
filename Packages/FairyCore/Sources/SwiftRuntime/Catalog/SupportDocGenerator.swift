import RuntimeContracts

/// 由 capability catalog 生成 docs/SWIFT_SUPPORT.md（测试保证文档与目录一致）。
public enum SupportDocGenerator {
    static func categoryTitle(_ c: CapabilityCategory) -> String {
        switch c {
        case .syntax: return "语言语法"
        case .stdlib: return "标准库"
        case .view: return "SwiftUI 视图"
        case .modifier: return "SwiftUI 修饰符"
        case .propertyWrapper: return "属性包装器"
        case .hostCapability: return "宿主能力"
        }
    }

    static func levelText(_ l: SupportLevel) -> String {
        switch l {
        case .supported: return "**supported**"
        case .partial: return "partial"
        case .unsupported: return "unsupported"
        }
    }

    static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    public static func markdown(_ catalog: CapabilityCatalog) -> String {
        var out = """
        # Fairy Studio Swift 支持范围（SwiftRuntime \(catalog.runtimeVersion)）

        > 本文件由 capability catalog 生成（`swift run fairy-run catalog --markdown`），请勿手改；
        > 测试 `supportDocMatchesCatalog` 保证与 `SwiftRuntimeEngine.catalog` 一致。
        >
        > 级别：supported = 已实现且有测试覆盖；partial = 已实现但有限制（见备注）；unsupported = 合法 Swift/SwiftUI，但运行时尚不支持，
        > 使用时产生 `unsupportedSyntax` / `unsupportedAPI` 诊断并附带对应的 capabilityID。


        """
        let order: [CapabilityCategory] = [.syntax, .stdlib, .propertyWrapper, .view, .modifier, .hostCapability]
        for cat in order {
            let entries = catalog.entries.filter { $0.category == cat }
            if entries.isEmpty { continue }
            let s = entries.filter { $0.level == .supported }.count
            let p = entries.filter { $0.level == .partial }.count
            let u = entries.filter { $0.level == .unsupported }.count
            out += "## \(categoryTitle(cat))（supported \(s) / partial \(p) / unsupported \(u)）\n\n"
            out += "| capabilityID | 名称 | 级别 | 签名 | 测试 | 备注 |\n|---|---|---|---|---|---|\n"
            for e in entries {
                let tests = e.testIDs.isEmpty ? "—" : e.testIDs.map { "`\($0)`" }.joined(separator: " ")
                out += "| `\(e.id)` | \(cell(e.displayName)) | \(levelText(e.level)) | \(e.signature.map { "`\(cell($0))`" } ?? "—") | \(tests) | \(cell(e.notes ?? "")) |\n"
            }
            out += "\n"
        }
        return out
    }
}
