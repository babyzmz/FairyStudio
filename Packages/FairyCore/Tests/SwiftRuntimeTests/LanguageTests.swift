import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("语言语义：闭包、值语义、数值", .timeLimit(.minutes(1)))
struct LanguageTests {
    // MARK: 闭包

    @Test func counterClosureCapturesVarByReference() async throws {
        let out = try await runScript("""
        func makeCounter() -> () -> Int {
            var n = 0
            return { n += 1; return n }
        }
        let a = makeCounter()
        let b = makeCounter()
        print(a(), a(), b(), a())
        var outer = 10
        let bump = { outer += 5 }
        bump()
        bump()
        print(outer)
        """)
        #expect(out.console == "1 2 1 3\n20\n")
    }

    @Test func letCaptureIsByValueAndLoopBindingsAreFresh() async throws {
        let out = try await runScript("""
        var fs: [() -> Int] = []
        for i in 1...3 {
            let doubled = i * 2
            fs.append { doubled + i }
        }
        print(fs.map { $0() })
        var x = 1
        let captured = x
        let f = { captured }
        x = 99
        print(f(), x)
        """)
        #expect(out.console == "[3, 6, 9]\n1 99\n")
    }

    @Test func closureEscapesIntoButtonAndMutatesState() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var total = 0
            @State private var history: [Int] = []
            var body: some View {
                let step = 5
                VStack {
                    Text("total \\(total)")
                    Text("history \\(history.count)")
                    Button("Add") {
                        total += step
                        history.append(total)
                    }
                    Button("Run", action: runTwice)
                }
            }
            func runTwice() {
                let add = { (n: Int) in total += n }
                add(1)
                add(1)
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        var t = try await s.tap("Add")
        t = try await s.tap("Add")
        #expect(t?.root.texts.contains("total 10") == true)
        #expect(t?.root.texts.contains("history 2") == true)
        t = try await s.tap("Run")
        #expect(t?.root.texts.contains("total 12") == true)
        await s.stop()
    }

    // MARK: 值语义

    @Test func structCopyIsIndependent() async throws {
        let out = try await runScript("""
        struct P { var x: Int; var tags: [String] }
        var a = P(x: 1, tags: ["a"])
        var b = a
        b.x = 2
        b.tags.append("b")
        print(a.x, a.tags, b.x, b.tags)
        func change(_ p: P) -> P { var q = p; q.x = 100; return q }
        let c = change(a)
        print(a.x, c.x)
        """)
        #expect(out.console == "1 [\"a\"] 2 [\"a\", \"b\"]\n1 100\n")
    }

    @Test func arrayCopyIsIndependent() async throws {
        let out = try await runScript("""
        var a = [[1], [2]]
        var b = a
        b[0].append(9)
        b.append([3])
        print(a, b)
        var d = ["k": [1]]
        var e = d
        e["k"]?.append(2)
        print(d, e)
        """)
        #expect(out.console == "[[1], [2]] [[1, 9], [2], [3]]\n[\"k\": [1]] [\"k\": [1, 2]]\n")
    }

    // MARK: Int / Double

    @Test func intAndDoubleMixingIsTypeError() async {
        let v = await validate(TestSupport.script("let a = 1\nlet b = 2.5\nprint(a + b)"))
        let d = v.diagnostics.first { $0.kind == .typeCheck }
        #expect(d != nil)
        #expect(d?.message.contains("Int") == true && d?.message.contains("Double") == true)
        #expect(d?.range?.start.line == 3)
        let v2 = await validate(TestSupport.script("var t: Double = 0\nlet n = 3\nt += n"))
        #expect(v2.diagnostics.contains { $0.kind == .typeCheck })
    }

    @Test func integerLiteralsAdaptToDoubleContext() async throws {
        let out = try await runScript("""
        let x: Double = 3
        let y = x / 2
        let z: Double = 1 / 4
        print(x, y, z, 7 / 2, 7.0 / 2, Double(7) / 2)
        func half(_ v: Double) -> Double { v / 2 }
        print(half(5))
        """)
        #expect(out.console == "3.0 1.5 0.25 3 3.5 3.5\n2.5\n")
    }

    // MARK: 运行错误（受控 trap）

    static let trapCases: [(String, String, String)] = [
        ("overflow", "var x = Int.max\nprint(\"before\")\nx += 1\nprint(x)", "溢出"),
        ("divideByZero", "let zero = 0\nprint(\"before\")\nprint(10 / zero)", "除以零"),
        ("indexOutOfRange", "let a = [1, 2]\nprint(\"before\")\nprint(a[5])", "越界"),
        ("forceUnwrapNil", "let s: String? = nil\nprint(\"before\")\nprint(s!)", "nil"),
        ("missingDictKey", "let d = [\"a\": 1]\nprint(\"before\")\nprint(d[\"b\"]!)", "nil"),
        ("multiplyOverflow", "let big = Int.max / 2\nprint(\"before\")\nprint(big * 3)", "溢出"),
        ("negativeRange", "let n = -1\nprint(\"before\")\nfor i in 0..<n { print(i) }", "下界"),
        ("removeFromEmpty", "var a: [Int] = []\nprint(\"before\")\na.removeLast()", "空数组"),
    ]

    @Test(arguments: trapCases.map(\.0))
    func runtimeTrapsBecomeDiagnostics(name: String) async throws {
        let c = try #require(Self.trapCases.first { $0.0 == name })
        let out = try await runScript(c.1)
        #expect(out.console == "before\n")
        #expect(out.isTrap, "\(String(describing: out.finished))")
        let d = try #require(out.errors.first { $0.kind == .runtimeTrap })
        #expect(d.message.contains(c.2), "\(d.message)")
        #expect(d.range?.start.line == 3)
        #expect(out.states.last == .failed)
        #expect(d.runID == out.envelopes.first?.runID)
    }

    // MARK: 其他语义

    @Test func mutatingMethodThroughStateAndNestedPaths() async throws {
        let out = try await runScript("""
        struct Counter { var n = 0; mutating func inc() { n += 1 } }
        struct Box { var counters: [Counter] = [Counter(), Counter()] }
        var box = Box()
        box.counters[1].inc()
        box.counters[1].inc()
        box.counters[0].inc()
        print(box.counters.map { $0.n })
        """)
        #expect(out.console == "[1, 2]\n")
    }

    @Test func immutableMutationIsCompileError() async {
        let v = await validate(TestSupport.script("""
        struct C { var n = 0; mutating func inc() { n += 1 } }
        let c = C()
        c.inc()
        let k = 1
        k = 2
        """))
        let errs = v.diagnostics.filter { $0.kind == .typeCheck }
        #expect(errs.contains { $0.range?.start.line == 3 })
        #expect(errs.contains { $0.range?.start.line == 5 })
    }

    @Test func switchOnEnumMustBeExhaustive() async {
        let v = await validate(TestSupport.script("""
        enum E { case a, b, c }
        let e = E.a
        switch e {
        case .a: print("a")
        case .b: print("b")
        }
        """))
        #expect(v.diagnostics.contains { $0.message.contains(".c") })
    }
}
