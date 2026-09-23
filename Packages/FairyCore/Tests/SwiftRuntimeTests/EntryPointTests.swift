import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("入口点与事件协议", .timeLimit(.minutes(1)))
struct EntryPointTests {
    @Test func scriptEntryPrintsToConsoleAndCompletes() async throws {
        let out = try await runScript("print(\"hello\")\nprint(1 + 2)")
        #expect(out.console == "hello\n3\n")
        #expect(out.finished == .completed)
        #expect(out.states == [.validating, .preparing, .running, .stopping, .stopped])
        // finished 是最后一个事件
        if case .finished = out.envelopes.last?.event {} else { Issue.record("finished 必须是最后一个事件") }
    }

    @Test func eventSequenceIsStrictlyIncreasing() async throws {
        let out = try await runScript("for i in 0..<5 { print(i) }")
        let seqs = out.envelopes.map(\.sequence)
        #expect(seqs == Array(1...UInt64(seqs.count)))
        #expect(Set(out.envelopes.map(\.runID)).count == 1)
    }

    @Test func validateListsScriptEntryAndCapabilities() async {
        let v = await validate(TestSupport.script("let x = [1, 2].map { $0 * 2 }\nprint(x)"))
        #expect(v.entryPoints == [.script(FileID("main.swift"))])
        #expect(v.referencedCapabilities.contains("stdlib.Array.map"))
        #expect(v.referencedCapabilities.contains("stdlib.print"))
        #expect(v.referencedCapabilities.contains("syntax.closure.shorthandArgs"))
    }

    @Test func multipleMainAppsIsError() async {
        let files = TestSupport.files([
            ("A.swift", "import SwiftUI\n@main struct A: App { var body: some Scene { WindowGroup { V() } } }"),
            ("B.swift", "import SwiftUI\n@main struct B: App { var body: some Scene { WindowGroup { V() } } }"),
            ("V.swift", "import SwiftUI\nstruct V: View { var body: some View { Text(\"v\") } }"),
        ])
        let v = await validate(TestSupport.program(files))
        #expect(!v.isRunnable)
        #expect(v.diagnostics.contains { $0.message.contains("多个 @main") })
    }

    @Test func topLevelStatementsOutsideMainSwiftIsError() async {
        let files = TestSupport.files([
            ("main.swift", "print(helper())"),
            ("Helper.swift", "func helper() -> Int { 1 }\nprint(\"stray\")"),
        ])
        let v = await validate(TestSupport.program(files))
        let d = v.diagnostics.first { $0.message.contains("顶层语句只能出现在 main.swift") }
        #expect(d?.range?.start.fileID == FileID("Helper.swift"))
        #expect(d?.range?.start.line == 2)
    }

    @Test func mainAppMixedWithTopLevelCodeIsError() async {
        let files = TestSupport.files([
            ("main.swift", "print(1)"),
            ("App.swift", "import SwiftUI\n@main struct A: App { var body: some Scene { WindowGroup { Text(\"x\") } } }"),
        ])
        let v = await validate(TestSupport.program(files))
        #expect(v.diagnostics.contains { $0.message.contains("不能同时存在") })
    }

    @Test func invalidRootViewEntryFailsWithDiagnostic() async throws {
        let engine = SwiftRuntimeEngine()
        let h = try await engine.runHandle(TestSupport.script("print(1)"), entry: .rootView(symbol: "Missing"))
        var out = RunOutcome()
        for await e in h.events { out.envelopes.append(e) }
        await h.stop()
        #expect(out.states.last == .failed)
        #expect(out.finished == .validationFailed)
        #expect(out.errors.contains { $0.message.contains("Missing") })
    }

    /// CR-1：校验失败 = validating → diagnostic… → failed → finished(.validationFailed)，随后事件流结束。
    @Test func validationFailureEndsStreamWithFailedState() async throws {
        let out = try await runScript("let x: Int = \"text\"\nprint(x)")
        #expect(out.states == [.validating, .failed])
        #expect(out.finished == .validationFailed)
        if case .finished? = out.envelopes.last?.event {} else { Issue.record("最后一个事件应为 finished") }
        #expect(out.errors.contains { $0.kind == .typeCheck })
    }

    @Test func parseErrorIsReportedAsParseDiagnostic() async {
        let v = await validate(TestSupport.script("let x = (1 + \nprint(x"))
        #expect(v.diagnostics.contains { $0.kind == .parse })
        #expect(!v.isRunnable)
    }
}
