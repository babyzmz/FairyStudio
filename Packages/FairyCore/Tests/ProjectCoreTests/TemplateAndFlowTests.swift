import Foundation
import Testing
import RuntimeContracts
import ProjectContracts
@testable import ProjectCore
@testable import SwiftRuntime

/// 三个模板在当前解释器上真实 validate 可运行。
@Suite("模板可运行（真实 SwiftRuntime validate）", .serialized)
struct TemplateRunTests {
    @Test(arguments: ["counter", "calc", "todo"])
    func templateValidates(id: String) async throws {
        let (entrySymbol, files) = try ProjectTestSupport.loadTemplate(id)
        let program = ProgramSource(moduleName: "Template",
                                    files: files.map { SourceFile(id: FileID($0.path), path: $0.path, contents: $0.contents) })
        let engine = SwiftRuntimeEngine()
        let result = await engine.validate(program)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(id) 校验错误：\(errors.map(\.message))")
        #expect(result.isRunnable)
        #expect(result.entryPoints.contains(.rootView(symbol: entrySymbol)))
    }

    @Test func templatesImportThroughLibrary() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        for id in ["counter", "calc", "todo"] {
            let (entrySymbol, files) = try ProjectTestSupport.loadTemplate(id)
            let projectID = try library.createFromTemplate(
                .init(templateID: id, entrySymbol: entrySymbol, files: files))
            let store = try await library.openStore(projectID)
            #expect(await store.snapshot().entry == .rootView(symbol: entrySymbol))
        }
        #expect(library.list().count == 3)
    }
}

/// 端到端流程（逻辑层）：新建 → 第二文件 → 编辑 → 运行 → 改名 → 重跑一致 → 删除 → 诊断显示。
@Suite("作品流程（存储 + 真实运行）", .serialized)
struct ProjectWorkspaceFlowTests {
    private func texts(in tree: RenderTree) -> [String] {
        var out: [String] = []
        func walk(_ node: RenderNode) {
            if case let .text(value, _) = node.kind { out.append(value) }
            for child in node.children { walk(child) }
        }
        walk(tree.root)
        return out
    }

    /// 运行到首个 RenderTree 后停止，返回文本。
    private func runTexts(_ program: ProgramSource, entry: EntryPoint,
                          engine: SwiftRuntimeEngine) async throws -> [String] {
        let handle = try await engine.run(program, entry: entry, budget: .default,
                                          options: RunOptions(runtimeVersion: SwiftRuntimeEngine.version))
        var texts: [String] = []
        for await envelope in handle.events {
            if case let .render(tree) = envelope.event {
                texts = self.texts(in: tree)
                break
            }
            if case .finished = envelope.event { break }
        }
        await handle.stop()
        return texts
    }

    @Test func fullFlow() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let (entry, files) = try ProjectTestSupport.loadTemplate("counter")
        let id = try library.createFromTemplate(.init(templateID: "counter", entrySymbol: entry, files: files),
                                                displayName: "流程")
        let store = try await library.openStore(id)
        let engine = SwiftRuntimeEngine()

        // 新建第二文件。
        var snap = await store.snapshot()
        try await store.apply(FileChangeSet(baseRevision: snap.revision,
                                            operations: [.create(path: "Sources/Helpers/Format.swift",
                                                                 contents: "struct Format {\n    static func label(_ n: Int) -> String {\n        \"Count: \\(n)\"\n    }\n}\n")],
                                            summary: "新建第二文件", origin: .user))
        // 编辑：按钮改名。
        snap = await store.snapshot()
        var view = try #require(snap.file(path: "Sources/Views/ContentView.swift"))
        let edited = view.contents.replacingOccurrences(of: "Button(\"Increment\")", with: "Button(\"Add One\")")
        try await store.apply(FileChangeSet(baseRevision: snap.revision,
                                            operations: [.replace(fileID: view.id, expectedBaseHash: view.hash, contents: edited)],
                                            summary: "编辑", origin: .user))
        // 运行。
        snap = await store.snapshot()
        let engineEntry = snap.entry
        var validation = await engine.validate(snap.program)
        #expect(validation.isRunnable)
        let before = try await runTexts(snap.program, entry: engineEntry, engine: engine)
        #expect(before.contains("Count: 0"))

        // 改名第二文件：fileID 稳定，重跑一致。
        snap = await store.snapshot()
        let second = try #require(snap.file(path: "Sources/Helpers/Format.swift"))
        try await store.apply(FileChangeSet(baseRevision: snap.revision,
                                            operations: [.rename(fileID: second.id, expectedBaseHash: second.hash,
                                                                 newPath: "Sources/Helpers/TextFormat.swift")],
                                            summary: "改名", origin: .user))
        snap = await store.snapshot()
        #expect(snap.file(id: second.id)?.path == "Sources/Helpers/TextFormat.swift")
        validation = await engine.validate(snap.program)
        #expect(validation.isRunnable)
        let after = try await runTexts(snap.program, entry: engineEntry, engine: engine)
        #expect(after == before, "改名不影响运行结果")

        // 删除第二文件：仍可运行。
        snap = await store.snapshot()
        let doomed = try #require(snap.file(path: "Sources/Helpers/TextFormat.swift"))
        try await store.apply(FileChangeSet(baseRevision: snap.revision,
                                            operations: [.delete(fileID: doomed.id, expectedBaseHash: doomed.hash)],
                                            summary: "删除", origin: .user))
        snap = await store.snapshot()
        #expect(await engine.validate(snap.program).isRunnable)

        // 破坏主文件：诊断显示 capability。
        view = try #require(snap.file(path: "Sources/Views/ContentView.swift"))
        try await store.apply(FileChangeSet(baseRevision: snap.revision,
                                            operations: [.replace(fileID: view.id, expectedBaseHash: view.hash,
                                                                  contents: view.contents + "\nclass Base {}\nclass Derived: Base {}\n")],
                                            summary: "破坏", origin: .user))
        snap = await store.snapshot()
        let broken = await engine.validate(snap.program)
        #expect(!broken.isRunnable)
        let diagnostic = try #require(broken.diagnostics.first { $0.kind == .unsupportedSyntax })
        #expect(diagnostic.capabilityID == "syntax.class")
    }
}
