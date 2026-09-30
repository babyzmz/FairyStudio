import Testing
import SwiftUI
import RuntimeContracts
@testable import Fairy_Studio

/// W1 布局断点与兼容性状态（纯函数，不做像素断言）。
@Suite("工作区布局与兼容性")
struct WorkspaceLayoutTests {
    @Test("iPhone compact 走单栏三段")
    func compactIsSingle() {
        #expect(WorkspaceLayout.mode(horizontalSizeClass: .compact, width: 390) == .single)
        #expect(WorkspaceLayout.mode(horizontalSizeClass: nil, width: 390) == .single)
    }

    @Test("iPad regular 按宽度：≥1024 三栏，否则双栏")
    func regularBreakpoints() {
        #expect(WorkspaceLayout.mode(horizontalSizeClass: .regular, width: 1366) == .triple)
        #expect(WorkspaceLayout.mode(horizontalSizeClass: .regular, width: 1024) == .triple)
        #expect(WorkspaceLayout.mode(horizontalSizeClass: .regular, width: 1023) == .double)
        #expect(WorkspaceLayout.mode(horizontalSizeClass: .regular, width: 820) == .double)
    }

    @Test("分段切换：作品 / 代码 / 助手")
    func compactPanes() {
        #expect(WorkspaceCompactPane.allCases.map(\.rawValue) == ["作品", "代码", "助手"])
    }

    @Test("主舞台分段：作品 / 代码")
    func mainViewSegments() {
        #expect(WorkspaceMainView.allCases.map(\.rawValue) == ["作品", "代码"])
    }

    @Test("兼容性：一致 / 可升级 / 不兼容")
    func compatibility() {
        let current = RuntimeVersion(0, 1, 0)
        #expect(compatibilityStatus(manifest: "0.1.0", current: current) == .compatible)
        #expect(compatibilityStatus(manifest: "0.0.9", current: current) == .upgradeable)
        #expect(compatibilityStatus(manifest: "0.2.0", current: current) == .incompatible)
        #expect(compatibilityStatus(manifest: "1.0.0", current: current) == .incompatible)
        #expect(compatibilityStatus(manifest: "oops", current: current) == .incompatible)
    }
}


import Foundation
import ProjectCore
import ProjectContracts

@MainActor
@Suite("Audit: workspace draft protection", .serialized)
struct AuditWorkspaceDraftTests {
    @Test func staleDraftCannotOverwriteAssistantCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ProjectLibrary(documentsURL: directory, currentRuntimeVersion: "0.1.0")
        let store = try await library.openStore(try library.createBlank(displayName: "Draft"))
        let model = WorkspaceModel(store: store, library: library, coordinator: RunCoordinator(engine: RecordingEngine()))
        await model.reload()
        let file = try #require(model.snapshot?.files.first)
        model.open(file.id)
        model.setText("// my uncommitted edit", for: file.id)
        let base = await store.snapshot()
        _ = try await store.apply(FileChangeSet(baseRevision: base.revision,
            operations: [.replace(fileID: file.id, expectedBaseHash: file.hash, contents: "// assistant edit")],
            summary: "AI", origin: .ai(backend: "test")))
        await model.reload()
        #expect(await model.save(file.id) == false)
        #expect(model.text(of: file.id) == "// my uncommitted edit")
        #expect(await store.snapshot().file(id: file.id)?.contents == "// assistant edit")
        model.close(file.id)
        #expect(model.openedTabs.contains(file.id))
        #expect(model.isDirty(file.id))
    }

    @Test func saveAllDoesNotDiscardDeletedFileDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ProjectLibrary(documentsURL: directory, currentRuntimeVersion: "0.1.0")
        let store = try await library.openStore(try library.createBlank(displayName: "Deleted"))
        let model = WorkspaceModel(store: store, library: library, coordinator: RunCoordinator(engine: RecordingEngine()))
        await model.reload()
        let file = try #require(model.snapshot?.files.first)
        model.open(file.id)
        model.setText("recover me", for: file.id)
        let base = await store.snapshot()
        _ = try await store.apply(FileChangeSet(baseRevision: base.revision,
            operations: [.delete(fileID: file.id, expectedBaseHash: file.hash)], summary: "delete", origin: .user))
        await model.reload()
        await model.saveAll()
        #expect(model.text(of: file.id) == "recover me")
        #expect(model.isDirty(file.id))
        model.run()
        #expect(!model.coordinator.isActive)
    }
}
