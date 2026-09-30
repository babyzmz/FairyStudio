import Foundation
import Testing
import RuntimeContracts
import ProjectContracts
@testable import ProjectCore

@Suite("ProjectStore 原子提交与快照", .serialized)
struct ProjectStoreTests {
    @Test func createBlankAndOpen() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let id = try library.createBlank(displayName: "空白")
        let store = try await library.openStore(id)
        let snap = await store.snapshot()
        #expect(snap.displayName == "空白")
        #expect(snap.revision == ProjectRevision(0))
        #expect(snap.files.count == 1)
        #expect(snap.entry == .rootView(symbol: "ContentView"))
        let manifest = await store.manifestSnapshot()
        #expect(manifest.schemaVersion == ProjectManifest.currentSchemaVersion)
        #expect(manifest.entryDescription == "根视图 ContentView")
    }

    @Test func applyAdvancesRevisionAtomically() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let id = try library.createBlank(displayName: "A")
        let store = try await library.openStore(id)
        let base = await store.snapshot()
        let oldFile = try #require(base.files.first)
        let cs = FileChangeSet(baseRevision: base.revision, operations: [
            .replace(fileID: oldFile.id, expectedBaseHash: oldFile.hash, contents: "import SwiftUI\n"),
            .create(path: "Sources/Extra.swift", contents: "struct Extra {}\n"),
        ], summary: "test", origin: .user)
        let result = try await store.apply(cs)
        #expect(result.revision == ProjectRevision(1))
        #expect(result.createdFileIDs.count == 1)
        let next = await store.snapshot()
        #expect(next.revision == ProjectRevision(1))
        #expect(next.files.count == 2)
        // 改名外的 fileID 保持稳定。
        #expect(next.file(id: oldFile.id)?.path == oldFile.path)
    }

    @Test func hashMismatchRejectsWholeSet() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "A"))
        let base = await store.snapshot()
        let oldFile = try #require(base.files.first)
        let cs = FileChangeSet(baseRevision: base.revision, operations: [
            .create(path: "Sources/New.swift", contents: "x"),
            .replace(fileID: oldFile.id, expectedBaseHash: ContentHash(rawValue: "stale"), contents: "y"),
        ], summary: "test", origin: .ai(backend: "onDevice"))
        await #expect(throws: ChangeSetError.self) { try await store.apply(cs) }
        // 原子：新建文件也不得落盘，修订号不动。
        #expect(await store.snapshot().revision == base.revision)
        #expect(await store.snapshot().files.count == base.files.count)
    }

    @Test func revisionMismatchRejected() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "A"))
        let cs = FileChangeSet(baseRevision: ProjectRevision(99), operations: [], summary: "", origin: .user)
        await #expect(throws: ChangeSetError.self) { try await store.apply(cs) }
    }

    @Test func idempotentChangeSetID() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "A"))
        let base = await store.snapshot()
        let cs = FileChangeSet(baseRevision: base.revision,
                               operations: [.create(path: "Sources/Once.swift", contents: "x")],
                               summary: "", origin: .user)
        try await store.apply(cs)
        await #expect(throws: ChangeSetError.self) { try await store.apply(cs) }
        #expect(await store.snapshot().revision == ProjectRevision(1))
        #expect((await store.manifestSnapshot()).appliedChangeSets == [cs.id])
    }

    @Test func renameKeepsFileIDAndSyncsEntryFile() async throws {
        let (library, docs) = try ProjectTestSupport.makeLibrary()
        let (entry, files) = try ProjectTestSupport.loadTemplate("counter")
        let id = try library.createFromTemplate(.init(templateID: "counter", entrySymbol: entry, files: files))
        // 改为脚本入口项目：manifest.entryFile 指向模型文件。
        let manifestURL = docs.appendingPathComponent("Projects")
            .appendingPathComponent("\(id.description).mojoproject").appendingPathComponent("project.json")
        var manifest = try ProjectManifest.decode(Data(contentsOf: manifestURL))
        manifest.entryFile = "Sources/Models/Counter.swift"
        manifest.entrySymbol = nil
        try manifest.encoded().write(to: manifestURL, options: .atomic)
        let store = try await library.openStore(id)
        #expect(await store.snapshot().entry == .script((await store.snapshot()).file(path: "Sources/Models/Counter.swift")!.id))
        // 入口文件改名：同 fileID 的新路径同步进 manifest，fileID 不变。
        let snap = await store.snapshot()
        let target = try #require(snap.file(path: "Sources/Models/Counter.swift"))
        let cs = FileChangeSet(baseRevision: snap.revision,
                               operations: [.rename(fileID: target.id, expectedBaseHash: target.hash,
                                                    newPath: "Sources/Models/CounterModel.swift")],
                               summary: "", origin: .user)
        try await store.apply(cs)
        let next = await store.snapshot()
        #expect(next.file(id: target.id)?.path == "Sources/Models/CounterModel.swift")
        #expect((await store.manifestSnapshot()).entryFile == "Sources/Models/CounterModel.swift")
        #expect(next.revision == ProjectRevision(1))
    }

    @Test func limitsEnforced() async throws {
        let docs = try ProjectTestSupport.makeDocuments()
        let small = ProjectLibrary(documentsURL: docs, currentRuntimeVersion: "0.1.0",
                                   limits: ProjectLimits(maxSourceFiles: 2, maxFileBytes: 256, maxTotalSourceBytes: 1024))
        let store = try await small.openStore(try small.createBlank(displayName: "A"))
        let base = await store.snapshot()
        // 单文件过大。
        let big = FileChangeSet(baseRevision: base.revision,
                                operations: [.create(path: "Sources/Big.swift", contents: String(repeating: "x", count: 1024))],
                                summary: "", origin: .user)
        await #expect(throws: ChangeSetError.self) { try await store.apply(big) }
        // 文件数超限。
        var ops: [FileOperation] = []
        for i in 0..<3 { ops.append(.create(path: "Sources/F\(i).swift", contents: "x")) }
        let many = FileChangeSet(baseRevision: base.revision, operations: ops, summary: "", origin: .user)
        await #expect(throws: ChangeSetError.self) { try await store.apply(many) }
    }

    @Test func rollbackRecordWritten() async throws {
        let (library, docs) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "A"))
        let base = await store.snapshot()
        let oldFile = try #require(base.files.first)
        let cs = FileChangeSet(baseRevision: base.revision,
                               operations: [.replace(fileID: oldFile.id, expectedBaseHash: oldFile.hash, contents: "new")],
                               summary: "", origin: .user)
        try await store.apply(cs)
        let record = docs.appendingPathComponent(".snapshots")
            .appendingPathComponent(base.projectID.description).appendingPathComponent("r0")
        #expect(FileManager.default.fileExists(atPath: record.appendingPathComponent("project.json").path))
        let oldContents = try String(contentsOf: record.appendingPathComponent(oldFile.path), encoding: .utf8)
        #expect(oldContents == oldFile.contents)
    }

    @Test func snapshotsStreamPushes() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "A"))
        let stream = await store.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.revision == ProjectRevision(0))
        let base = try #require(first)
        let oldFile = try #require(base.files.first)
        let cs = FileChangeSet(baseRevision: base.revision,
                               operations: [.replace(fileID: oldFile.id, expectedBaseHash: oldFile.hash, contents: "v2")],
                               summary: "", origin: .user)
        try await store.apply(cs)
        let second = await iterator.next()
        #expect(second?.revision == ProjectRevision(1))
    }

    @Test func highSchemaVersionRefused() async throws {
        let (library, docs) = try ProjectTestSupport.makeLibrary()
        let id = try library.createBlank(displayName: "A")
        // 手工抬高 schemaVersion。
        let manifestURL = docs.appendingPathComponent("Projects")
            .appendingPathComponent("\(id.description).mojoproject").appendingPathComponent("project.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 999")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        do {
            _ = try await library.openStore(id)
            Issue.record("高版本 manifest 应被拒绝")
        } catch ProjectStore.OpenError.unsupportedSchemaVersion(let v) {
            #expect(v == 999)
        }
    }

    @Test func duplicateRenameDelete() async throws {
        let (library, docs) = try ProjectTestSupport.makeLibrary()
        let id = try library.createBlank(displayName: "原作")
        let copy = try library.duplicate(id)
        #expect(copy != id)
        let summaries = library.list()
        #expect(summaries.first { $0.projectID == copy }?.displayName == "原作 副本")
        try library.rename(copy, displayName: "改名后")
        #expect(library.list().first { $0.projectID == copy }?.displayName == "改名后")
        // 最近项目按 modifiedAt 倒序（ISO-8601 秒精度：同秒内只保证新作品排在前二）。
        #expect(library.list().prefix(2).contains { $0.projectID == copy })
        try library.delete(copy)
        #expect(!library.list().contains { $0.projectID == copy })
        #expect(!FileManager.default.fileExists(atPath: docs.appendingPathComponent(".snapshots/\(copy.description)").path))
    }

    @Test func importSingleSwift() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("ImportMe-\(UUID().uuidString).swift")
        let code = "import SwiftUI\n\nstruct ImportedView: View {\n    var body: some View { Text(\"hi\") }\n}\n"
        try code.write(to: src, atomically: true, encoding: .utf8)
        let id = try library.importSwiftFile(displayName: "导入", sourceURL: src)
        let store = try await library.openStore(id)
        let snap = await store.snapshot()
        #expect(snap.files.count == 1)
        #expect(snap.entry == .rootView(symbol: "ImportedView"))
        // 原文件不动。
        #expect(try String(contentsOf: src, encoding: .utf8) == code)
    }
}
