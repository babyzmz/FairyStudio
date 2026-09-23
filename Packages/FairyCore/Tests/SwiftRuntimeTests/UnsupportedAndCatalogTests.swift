import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("不支持语法诊断与 capability catalog")
struct UnsupportedAndCatalogTests {
    /// (名称, 源码, 期望 capabilityID)
    static let cases: [(String, String, String)] = [
        ("class", "class Animal { var name = \"x\" }\nprint(1)", "syntax.class"),
        ("classInheritance", "class A {}\nclass B: A {}\nprint(1)", "syntax.class"),
        ("genericFunction", "func first<T>(_ a: [T]) -> T { a[0] }\nprint(1)", "syntax.generics"),
        ("genericStruct", "struct Box<T> { var v: T }\nprint(1)", "syntax.generics"),
        ("protocol", "protocol Shape { func area() -> Double }\nprint(1)", "syntax.protocol"),
        ("protocolConformance", "struct S: Codable { var x = 1 }\nprint(1)", "syntax.protocol"),
        ("asyncFunction", "func load() async -> Int { 1 }\nprint(1)", "syntax.asyncAwait"),
        ("throwsFunction", "func load() throws -> Int { 1 }\nprint(1)", "syntax.errorHandling"),
        ("actor", "actor Bank { var balance = 0 }\nprint(1)", "syntax.actor"),
        ("macroAttribute", "@Observable struct Model { var x = 0 }\nprint(1)", "syntax.macro"),
        ("otherAttribute", "@available(iOS 17, *) func f() {}\nprint(1)", "syntax.attribute"),
        ("tuplePattern", "let (a, b) = (1, 2)\nprint(a + b)", "syntax.tuplePattern"),
        ("tupleSwitchPattern", "let p = (1, 2)\nswitch p {\ncase (0, 0): print(0)\ndefault: print(1)\n}", "syntax.tuplePattern"),
        ("inoutParameter", "func inc(_ x: inout Int) { x += 1 }\nprint(1)", "syntax.function.inout"),
        ("typeCast", "let x = 3\nprint(x as Any)", "syntax.typeCasting"),
        ("typealias", "typealias Score = Int\nprint(1)", "syntax.typealias"),
        ("associatedValues", "enum R { case ok(Int), fail }\nprint(1)", "syntax.enum.associatedValues"),
        ("defer", "func f() { defer { print(1) }\nprint(2) }\nf()", "syntax.defer"),
        ("labeledStatement", "outer: for i in 0..<2 { print(i) }", "syntax.labeledStatement"),
        ("propertyObservers", "struct S { var x = 0 { didSet { print(x) } } }\nprint(1)", "syntax.struct.propertyObservers"),
        ("customOperator", "infix operator <+>\nprint(1)", "syntax.operatorDecl"),
        ("closureCaptureList", "var x = 1\nlet f = { [x] in print(x) }\nf()", "syntax.closure.captureList"),
        ("ifExpression", "let v = if true { 1 } else { 2 }\nprint(v)", "syntax.ifExpression"),
        ("stdlibExtension", "extension Int { var doubled: Int { self * 2 } }\nprint(1)", "syntax.extension.stdlibType"),
        ("unsupportedType", "let s: Set<Int> = []\nprint(s)", "stdlib.Set"),
        ("importUIKit", "import UIKit\nprint(1)", "syntax.import"),
    ]

    @Test(arguments: cases.map(\.0))
    func unsupportedSyntaxMapsToCapabilityID(name: String) async throws {
        let c = try #require(Self.cases.first { $0.0 == name })
        let v = await validate(TestSupport.script(c.1))
        #expect(!v.isRunnable)
        let d = try #require(v.diagnostics.first { $0.capabilityID == c.2 }, "诊断：\(v.diagnostics.map { "\($0.kind) \($0.capabilityID ?? "-") \($0.message)" })")
        #expect(d.kind == .unsupportedSyntax || d.kind == .unsupportedAPI)
        #expect(d.message.contains("尚不支持"))
        #expect(d.range != nil)
        // 不能伪装成用户写错
        #expect(!v.diagnostics.contains { $0.kind == .nameResolution }, "\(v.diagnostics.map(\.message))")
        #expect(SwiftRuntimeEngine.catalog[c.2] != nil, "catalog 缺少 \(c.2)")
        #expect(SwiftRuntimeEngine.catalog[c.2]?.level != .supported)
    }

    static let unsupportedUI: [(String, String, String)] = [
        ("Slider", "Slider(value: $v, in: 0...1)", "view.Slider"),
        ("NavigationLink", "NavigationLink(\"x\") { Text(\"y\") }", "view.NavigationLink"),
        ("shadowModifier", "Text(\"x\").shadow(radius: 2)", "modifier.shadow"),
        ("sheetModifier", "Text(\"x\").sheet(isPresented: $flag) { Text(\"y\") }", "modifier.sheet"),
        ("fontSystem", "Text(\"x\").font(.system(size: 20))", "syntax.implicitMemberCall"),
        ("observedObject", "Text(\"x\")", "propertyWrapper.ObservedObject"),
    ]

    @Test(arguments: unsupportedUI.map(\.0))
    func unsupportedSwiftUIMapsToCapabilityID(name: String) async throws {
        let c = try #require(Self.unsupportedUI.first { $0.0 == name })
        let extra = name == "observedObject" ? "@ObservedObject var model: Int\n" : ""
        let src = """
        import SwiftUI
        struct V: View {
            @State private var v = 0.5
            @State private var flag = false
            \(extra)
            var body: some View {
                \(c.1)
            }
        }
        """
        let v = await validate(TestSupport.program(TestSupport.files([("V.swift", src)])))
        let d = try #require(v.diagnostics.first { $0.capabilityID == c.2 }, "\(v.diagnostics.map { "\($0.capabilityID ?? "-") \($0.message)" })")
        #expect(d.kind == .unsupportedSyntax || d.kind == .unsupportedAPI)
        #expect(!v.diagnostics.contains { $0.kind == .nameResolution })
        #expect(SwiftRuntimeEngine.catalog[c.2] != nil, "catalog 缺少 \(c.2)")
    }

    // MARK: catalog

    static var testsDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    /// 扫描测试源码中声明的函数名。
    static func declaredTestFunctions() throws -> Set<String> {
        var names = Set<String>()
        let fm = FileManager.default
        for f in try fm.contentsOfDirectory(atPath: testsDirectory.path) where f.hasSuffix(".swift") {
            let text = try String(contentsOf: testsDirectory.appendingPathComponent(f), encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let r = line.range(of: "func ") else { continue }
                let rest = line[r.upperBound...]
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.insert(String(name)) }
            }
        }
        return names
    }

    @Test func catalogSupportedEntriesReferenceRealTests() throws {
        let funcs = try Self.declaredTestFunctions()
        let fixtures = Set(try FileManager.default.contentsOfDirectory(
            atPath: TestSupport.fixturesURL.appendingPathComponent("differential").path))
        var missing: [String] = []
        for e in SwiftRuntimeEngine.catalog.entries where e.level != .unsupported {
            if e.level == .supported && e.testIDs.isEmpty { missing.append("\(e.id)：supported 但没有 testIDs") }
            for t in e.testIDs {
                if t.hasPrefix("differential/") {
                    if !fixtures.contains(String(t.dropFirst("differential/".count))) { missing.append("\(e.id)：\(t)") }
                } else if !funcs.contains(t) {
                    missing.append("\(e.id)：\(t)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing)")
    }

    @Test func catalogIDsAreUniqueAndWellFormed() {
        let ids = SwiftRuntimeEngine.catalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        for e in SwiftRuntimeEngine.catalog.entries {
            let prefix: String
            switch e.category {
            case .syntax: prefix = "syntax."
            case .stdlib: prefix = "stdlib."
            case .view: prefix = "view."
            case .modifier: prefix = "modifier."
            case .propertyWrapper: prefix = "propertyWrapper."
            case .hostCapability: prefix = "host."
            }
            #expect(e.id.hasPrefix(prefix), "\(e.id)")
        }
    }

    @Test func supportDocMatchesCatalog() throws {
        let docURL = Self.testsDirectory.appendingPathComponent("../../../../docs/SWIFT_SUPPORT.md").standardizedFileURL
        let doc = try String(contentsOf: docURL, encoding: .utf8)
        #expect(doc == SupportDocGenerator.markdown(SwiftRuntimeEngine.catalog),
                "docs/SWIFT_SUPPORT.md 与 catalog 不一致；请运行 swift run fairy-run catalog --markdown > docs/SWIFT_SUPPORT.md")
    }

    @Test func referencedCapabilitiesExistInCatalog() async throws {
        var all = Set<String>()
        let fixtureDir = TestSupport.fixturesURL.appendingPathComponent("differential")
        for f in try FileManager.default.contentsOfDirectory(atPath: fixtureDir.path) where f.hasSuffix(".swift") {
            let code = try String(contentsOf: fixtureDir.appendingPathComponent(f), encoding: .utf8)
            all.formUnion(await validate(TestSupport.script(code)).referencedCapabilities)
        }
        all.formUnion(await validate(StateAndViewTests.listProgram).referencedCapabilities)
        let ids = Set(SwiftRuntimeEngine.catalog.entries.map(\.id))
        let missing = all.subtracting(ids).sorted()
        #expect(missing.isEmpty, "\(missing)")
    }
}
