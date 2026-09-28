import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// W3 语言广度：错误诊断与差分夹具之外的语义边角。
@Suite("W3 语言：解构/关联值/setter/didSet/inout/format/单侧范围", .timeLimit(.minutes(2)))
struct W3LanguageTests {
    func errors(_ code: String) async -> [Diagnostic] {
        await validate(TestSupport.script(code)).diagnostics.filter { $0.severity == .error }
    }

    // MARK: - 元组解构

    @Test func tupleDestructureCountMismatchIsError() async throws {
        let ds = await errors("let (a, b) = (1, 2, 3)\nprint(a)")
        #expect(ds.contains { $0.kind == .typeCheck && $0.message.contains("2 元组") })
    }

    @Test func tupleDestructureNonTupleIsError() async throws {
        let ds = await errors("let (a, b) = 5\nprint(a)")
        #expect(ds.contains { $0.kind == .typeCheck })
    }

    @Test func nestedTuplePatternIsUnsupported() async throws {
        let v = await validate(TestSupport.script("let (a, (b, c)) = (1, (2, 3))\nprint(a)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.capabilityID == "syntax.tuplePattern" })
    }

    @Test func tupleDestructureAssignmentStillUnsupported() async throws {
        let v = await validate(TestSupport.script("var a = 0\nvar b = 0\n(a, b) = (1, 2)\nprint(a)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.capabilityID == "syntax.tuplePattern" })
    }

    // MARK: - enum 关联值

    @Test func enumAssociatedLabelMismatchIsError() async throws {
        let ds = await errors("enum R { case pt(x: Int, y: Int) }\nlet r = R.pt(y: 1, x: 2)\nprint(r)")
        #expect(ds.contains { $0.kind == .typeCheck && $0.message.contains("标签") })
    }

    @Test func barePayloadCaseNeedsArguments() async throws {
        let ds = await errors("enum R { case ok(Int) }\nlet r = R.ok\nprint(r)")
        #expect(ds.contains { $0.kind == .typeCheck && $0.message.contains("关联值") })
    }

    @Test func rawValueAndPayloadCannotMix() async throws {
        let v = await validate(TestSupport.script("enum R: Int { case ok(Int), fail }\nprint(1)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.kind == .typeCheck })
    }

    @Test func caseIterableWithPayloadIsError() async throws {
        let v = await validate(TestSupport.script("enum R: CaseIterable { case ok(Int), fail }\nprint(1)"))
        #expect(!v.isRunnable)
    }

    @Test func nonExhaustiveAssociatedSwitchIsError() async throws {
        let v = await validate(TestSupport.script("enum R { case ok(Int), fail }\nlet r = R.fail\nswitch r {\ncase .ok(let x): print(x)\n}"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.message.contains("穷尽") })
    }

    @Test func payloadEnumEqualityIsLenientSuperset() async throws {
        let out = try await runScript("""
        enum R { case ok(Int), fail }
        print(R.ok(1) == R.ok(1))
        print(R.ok(1) == R.ok(2))
        print(R.ok(1) == R.fail)
        """)
        #expect(out.console == "true\nfalse\nfalse\n")
    }

    // MARK: - inout

    @Test func inoutMissingAmpersandIsError() async throws {
        let ds = await errors("func inc(_ x: inout Int) { x += 1 }\nvar a = 1\ninc(a)\nprint(a)")
        #expect(ds.contains { $0.kind == .typeCheck && $0.message.contains("&") })
    }

    @Test func inoutOnLetIsError() async throws {
        let ds = await errors("func inc(_ x: inout Int) { x += 1 }\nlet a = 1\ninc(&a)\nprint(a)")
        #expect(ds.contains { $0.kind == .typeCheck })
    }

    @Test func inoutOnLiteralIsError() async throws {
        let ds = await errors("func inc(_ x: inout Int) { x += 1 }\ninc(&3)")
        #expect(ds.contains { $0.kind == .typeCheck })
    }

    @Test func inoutNoImplicitConversion() async throws {
        let ds = await errors("func f(_ x: inout Double) { x += 1 }\nvar a = 1\nf(&a)\nprint(a)")
        #expect(ds.contains { $0.kind == .typeCheck })
    }

    // MARK: - setter / didSet

    @Test func setterWithoutGetterIsError() async throws {
        let v = await validate(TestSupport.script("struct S { var x: Int { set { print(newValue) } } }\nprint(1)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.message.contains("缺少 get") })
    }

    @Test func willSetIsIgnoredWithWarning() async throws {
        let v = await validate(TestSupport.script("var x = 1 { willSet { print(newValue) } }\nx = 2\nprint(x)"))
        #expect(v.isRunnable)
        #expect(v.diagnostics.contains { $0.severity == .warning && $0.message.contains("willSet") })
        let out = try await runScript("var x = 1 { willSet { print(newValue) } }\nx = 2\nprint(x)")
        #expect(out.console == "2\n")
    }

    @Test func staticSetterIsUnsupported() async throws {
        let v = await validate(TestSupport.script("struct S { static var x: Int { get { 1 } set { print(newValue) } } }\nprint(1)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.capabilityID == "syntax.struct.computedSetter" })
    }

    // MARK: - String(format:) / 单侧范围

    @Test func stringFormatOtherSpecifiersUnsupported() async throws {
        // %d 的拒绝发生在运行期（格式串可能是变量，编译期无法判定）
        let out = try await runScript("import Foundation\nprint(String(format: \"%d\", 3))")
        #expect(out.errors.contains { $0.kind == .unsupportedAPI && $0.capabilityID == "stdlib.String.format" })
    }

    @Test func stringFormatIntArgActsAsDouble() async throws {
        let out = try await runScript("import Foundation\nprint(String(format: \"%.1f\", 7))")
        #expect(out.console == "7.0\n")
    }

    @Test func stringFormatMissingArgTraps() async throws {
        let out = try await runScript("import Foundation\nprint(String(format: \"%.1f %.1f\", 1.5))")
        #expect(out.isTrap)
        #expect(out.errors.contains { $0.kind == .runtimeTrap })
    }

    @Test func forInOverPartialRangeIsError() async throws {
        let ds = await errors("for i in 2... { print(i) }")
        #expect(ds.contains { $0.kind == .typeCheck })
    }

    @Test func doublePartialRangeUnsupported() async throws {
        let v = await validate(TestSupport.script("let r = 2.5...\nprint(r)"))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.capabilityID == "syntax.range" })
    }
}
