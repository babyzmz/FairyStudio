import Foundation
import Testing
import RuntimeContracts
import ProjectContracts
@testable import ProjectCore

@Suite("Audit: project integrity", .serialized)
struct AuditProjectRegressionTests {
    @Test func corruptZipIsErrorNotTrap() throws {
        let original = ZipArchive.encode([.init(name: "Sources/A.swift", data: Data("let x = 1".utf8))])
        #expect(try ZipArchive.decode(original).count == 1)
        var bad = original
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let central = try #require(bad.range(of: signature)).lowerBound
        for offset in 20..<24 { bad[central + offset] = 0xff }
        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive.decode(bad) }
    }

    @Test func declaredSizeRejectedBeforeInflate() throws {
        let data = ZipArchive.encode([.init(name: "a", data: Data(repeating: 1, count: 32))])
        #expect(throws: ZipArchive.ZipError.self) {
            try ZipArchive.decode(data, limits: .init(maxFiles: 1, maxFileBytes: 8, maxTotalBytes: 8))
        }
    }

    @Test func storedCRCIsChecked() throws {
        var data = ZipArchive.encode([.init(name: "a", data: Data([1, 2, 3]))])
        data[31] ^= 0xff
        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive.decode(data) }
    }

    @Test func metadataCannotBeWrittenAsSource() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "Protected"))
        let base = await store.snapshot()
        for path in ["project.json", "PROJECT.JSON", "project.json/child", ".snapshots/x"] {
            let change = FileChangeSet(baseRevision: base.revision,
                operations: [.create(path: path, contents: "bad")], summary: "", origin: .user)
            await #expect(throws: ChangeSetError.self) { try await store.apply(change) }
        }
        #expect(await store.snapshot() == base)
    }

    @Test func createIdentityIsStableAcrossPreviewAndCommit() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "Identity"))
        let base = await store.snapshot()
        let change = FileChangeSet(baseRevision: base.revision,
            operations: [.create(path: "Sources/New.swift", contents: "struct New {}")], summary: "", origin: .user)
        let preview = try ChangeSetPreview.apply(change, to: base)
        _ = try await store.apply(change)
        let committed = await store.snapshot()
        #expect(preview.file(path: "Sources/New.swift")?.id == committed.file(path: "Sources/New.swift")?.id)
    }

    @Test func sameProjectGetsSameActorAndRejectsStaleWriter() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let id = try library.createBlank(displayName: "Shared")
        async let first = library.openStore(id)
        async let second = library.openStore(id)
        let (a, b) = try await (first, second)
        #expect(a === b)
        let base = await a.snapshot()
        let change = FileChangeSet(baseRevision: base.revision,
            operations: [.create(path: "Sources/A.swift", contents: "a")], summary: "", origin: .user)
        _ = try await a.apply(change)
        let stale = FileChangeSet(baseRevision: base.revision,
            operations: [.create(path: "Sources/B.swift", contents: "b")], summary: "", origin: .user)
        await #expect(throws: ChangeSetError.self) { try await b.apply(stale) }
    }

    @Test func cancelledTaskDoesNotCommit() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "Cancelled"))
        let base = await store.snapshot()
        let change = FileChangeSet(baseRevision: base.revision,
            operations: [.create(path: "Sources/Bad.swift", contents: "bad")], summary: "", origin: .user)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.apply(change)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.snapshot() == base)
    }

    @Test func rawZipPreservesSameBasenameInDifferentDirectories() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let data = ZipArchive.encode([
            .init(name: "Models/Row.swift", data: Data("struct ModelRow {}".utf8)),
            .init(name: "Views/Row.swift", data: Data("struct ViewRow {}".utf8))
        ])
        let store = try await library.openStore(library.importZIP(data))
        let snapshot = await store.snapshot()
        #expect(snapshot.file(path: "Sources/Models/Row.swift")?.contents == "struct ModelRow {}")
        #expect(snapshot.file(path: "Sources/Views/Row.swift")?.contents == "struct ViewRow {}")
    }

    @Test func inverseRemovesCreatedFilesAndRestoresRename() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let store = try await library.openStore(try library.createBlank(displayName: "Restore"))
        let before = await store.snapshot()
        let file = try #require(before.files.first)
        let change = FileChangeSet(baseRevision: before.revision, operations: [
            .rename(fileID: file.id, expectedBaseHash: file.hash, newPath: "Sources/Renamed.swift"),
            .replace(fileID: file.id, expectedBaseHash: file.hash, contents: "changed"),
            .create(path: "Sources/Helper.swift", contents: "helper")
        ], summary: "", origin: .user)
        _ = try await store.apply(change)
        let after = await store.snapshot()
        let inverse = try SourceRestore.changeSet(before: before, after: after, current: after)
        _ = try await store.apply(inverse)
        let restored = await store.snapshot()
        #expect(Set(restored.files) == Set(before.files))
        #expect(throws: ChangeSetError.self) {
            try SourceRestore.changeSet(before: before, after: after, current: restored)
        }
    }
}
