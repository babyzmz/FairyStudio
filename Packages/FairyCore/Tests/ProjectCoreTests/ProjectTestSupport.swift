import Foundation
import Testing
import RuntimeContracts
import ProjectContracts
@testable import ProjectCore

/// ProjectStore / ProjectLibrary 测试共用的临时 Documents 目录。
struct ProjectTestSupport {
    static func makeDocuments() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("W1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeLibrary(documents: URL? = nil) throws -> (ProjectLibrary, URL) {
        let docs = try documents.map { $0 } ?? makeDocuments()
        return (ProjectLibrary(documentsURL: docs, currentRuntimeVersion: "0.1.0"), docs)
    }

    /// 仓库 Templates/<id>/Sources 下的模板源码（同时校验 template.json 文件表）。
    static func loadTemplate(_ id: String) throws -> (entrySymbol: String, files: [(path: String, contents: String)]) {
        let here = URL(filePath: #filePath).deletingLastPathComponent()
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("Templates")
        let dir = base.appendingPathComponent(id, isDirectory: true)
        struct Manifest: Decodable {
            struct File: Decodable { var path: String }
            var entrySymbol: String
            var files: [File]
        }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: dir.appendingPathComponent("template.json")))
        let files = try manifest.files.map { file in
            (path: file.path, contents: try String(contentsOf: dir.appendingPathComponent(file.path), encoding: .utf8))
        }
        return (manifest.entrySymbol, files)
    }

    static func replaceAll(in store: ProjectStore, path: String, contents: String) async throws {
        let snap = await store.snapshot()
        let file = try #require(snap.file(path: path))
        let cs = FileChangeSet(baseRevision: snap.revision,
                               operations: [.replace(fileID: file.id, expectedBaseHash: file.hash, contents: contents)],
                               summary: "test", origin: .user)
        try await store.apply(cs)
    }
}
