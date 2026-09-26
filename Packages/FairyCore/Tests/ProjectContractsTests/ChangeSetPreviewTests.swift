import Testing
import Foundation
import RuntimeContracts
@testable import ProjectContracts

@Suite("ChangeSetPreview 原子演算")
struct ChangeSetPreviewTests {
    func base() -> ProjectSnapshot {
        ProjectSnapshot(projectID: ProjectID(), revision: ProjectRevision(3), displayName: "T", moduleName: "T",
                        entry: .rootView(symbol: "ContentView"),
                        files: [ProjectFileSnapshot(id: FileID("a"), path: "Sources/Main.swift", contents: "let a = 1")])
    }

    @Test func hashMismatchRejectsWholeSet() {
        let b = base()
        let cs = FileChangeSet(baseRevision: b.revision, operations: [
            .create(path: "Sources/New.swift", contents: "let b = 2"),
            .replace(fileID: FileID("a"), expectedBaseHash: ContentHash(rawValue: "stale"), contents: "let a = 2"),
        ], summary: "", origin: .user)
        #expect(throws: ChangeSetError.self) { try ChangeSetPreview.apply(cs, to: b) }
    }

    @Test func validSetAdvancesRevision() throws {
        let b = base()
        let cs = FileChangeSet(baseRevision: b.revision, operations: [
            .replace(fileID: FileID("a"), expectedBaseHash: b.files[0].hash, contents: "let a = 2"),
            .create(path: "Sources/Views/V.swift", contents: "struct V {}"),
        ], summary: "", origin: .ai(backend: "onDevice"))
        let next = try ChangeSetPreview.apply(cs, to: b)
        #expect(next.revision == ProjectRevision(4))
        #expect(next.files.count == 2)
        #expect(next.file(id: FileID("a"))?.contents == "let a = 2")
        #expect(next.program.files.count == 2)
    }

    @Test(arguments: ["../x.swift", "/abs.swift", "Sources//x.swift", "Sources/./x.swift", "", "a/"])
    func invalidPathsRejected(path: String) {
        #expect(throws: ChangeSetError.self) { try ChangeSetPreview.validatePath(path) }
    }

    @Test func revisionMismatchRejected() {
        let b = base()
        let cs = FileChangeSet(baseRevision: ProjectRevision(2), operations: [], summary: "", origin: .user)
        #expect(throws: ChangeSetError.self) { try ChangeSetPreview.apply(cs, to: b) }
    }
}
