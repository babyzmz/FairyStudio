import Foundation
import Testing
import RuntimeContracts
import ProjectContracts
@testable import ProjectCore

@Suite("ZIP 导入导出与攻击拒绝", .serialized)
struct ZipImportTests {
    @Test func exportImportRoundtripKeepsProject() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let (entry, files) = try ProjectTestSupport.loadTemplate("todo")
        let id = try library.createFromTemplate(.init(templateID: "todo", entrySymbol: entry, files: files),
                                                displayName: "待办")
        let data = try library.exportZIP(id)
        let imported = try library.importZIP(data)
        #expect(imported != id, "导入换新 projectID 防碰撞")
        let store = try await library.openStore(imported)
        let snap = await store.snapshot()
        #expect(snap.displayName == "待办")
        #expect(snap.files.count == 2)
        #expect(snap.entry == .rootView(symbol: "ContentView"))
    }

    @Test func bareSourcePackageImport() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let code = "import SwiftUI\n\nstruct BareView: View {\n    var body: some View { Text(\"bare\") }\n}\n"
        let data = ZipArchive.encode([
            .init(name: "random-dir/App.swift", data: Data(code.utf8)),
            .init(name: "README.txt", data: Data("hi".utf8)),
        ])
        let id = try library.importZIP(data, displayName: "裸包")
        let store = try await library.openStore(id)
        let snap = await store.snapshot()
        #expect(snap.entry == .rootView(symbol: "BareView"), "入口从首个 struct X: View 推断")
        #expect(snap.file(path: "Sources/App.swift") != nil)
    }

    @Test func traversalAndAbsolutePathsRejected() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        for name in ["../evil.swift", "/tmp/evil.swift", "Sources/../evil.swift", "Sources//x.swift"] {
            let data = ZipArchive.encode([.init(name: name, data: Data("x".utf8))])
            #expect(throws: ProjectLibrary.LibraryError.self, "应拒绝：\(name)") {
                try library.importZIP(data)
            }
        }
    }

    @Test func symlinkRejected() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let data = ZipArchive.encode([.init(name: "Sources/Link.swift", data: Data("x".utf8), isSymlink: true)])
        #expect(throws: ProjectLibrary.LibraryError.self) { try library.importZIP(data) }
    }

    @Test func caseConflictRejected() async throws {
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let data = ZipArchive.encode([
            .init(name: "Sources/App.swift", data: Data("a".utf8)),
            .init(name: "sources/app.swift", data: Data("b".utf8)),
        ])
        #expect(throws: ProjectLibrary.LibraryError.self) { try library.importZIP(data) }
    }

    @Test func limitsEnforced() async throws {
        let docs = try ProjectTestSupport.makeDocuments()
        let small = ProjectLibrary(documentsURL: docs, currentRuntimeVersion: "0.1.0",
                                   limits: ProjectLimits(maxSourceFiles: 1, maxFileBytes: 8, maxTotalSourceBytes: 16))
        // 单文件过大。
        let big = ZipArchive.encode([.init(name: "A.swift", data: Data(repeating: 0, count: 64))])
        #expect(throws: ProjectLibrary.LibraryError.self) { try small.importZIP(big) }
        // 文件数超限（派生上限 = maxSourceFiles * 2 = 2）。
        let many = ZipArchive.encode((0..<5).map { .init(name: "F\($0).swift", data: Data("x".utf8)) })
        #expect(throws: ProjectLibrary.LibraryError.self) { try small.importZIP(many) }
    }

    @Test func deflatedZipDecodes() async throws {
        // 真实 deflate 包（python3 zipfile）：Finder 下载、网页导出的常见形态。
        let code = "import SwiftUI\n\nstruct ZipView: View {\n    var body: some View { Text(\"zip\") }\n}\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deflate-\(UUID().uuidString).zip")
        let script = "import zipfile; z = zipfile.ZipFile(r'\(tmp.path)', 'w', zipfile.ZIP_DEFLATED); z.writestr('Hello.swift', r'''\(code)'''); z.close()"
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/python3")
        proc.arguments = ["-c", script]
        try proc.run()
        proc.waitUntilExit()
        try #require(proc.terminationStatus == 0)
        let entries = try ZipArchive.decode(Data(contentsOf: tmp))
        #expect(entries.count == 1)
        #expect(String(data: entries[0].data, encoding: .utf8) == code)
        let (library, _) = try ProjectTestSupport.makeLibrary()
        let id = try library.importZIP(Data(contentsOf: tmp))
        let store = try await library.openStore(id)
        #expect(await store.snapshot().entry == .rootView(symbol: "ZipView"))
    }
}
