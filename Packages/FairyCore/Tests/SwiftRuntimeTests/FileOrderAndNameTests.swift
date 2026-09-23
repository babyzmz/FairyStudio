import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// 可重复的伪随机数（测试文件顺序打乱用）。
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

func permutations<T>(_ a: [T]) -> [[T]] {
    if a.count <= 1 { return [a] }
    var out: [[T]] = []
    for i in a.indices {
        var rest = a
        let x = rest.remove(at: i)
        for p in permutations(rest) { out.append([x] + p) }
    }
    return out
}

@Suite("文件顺序无关 / 名称解析", .timeLimit(.minutes(2)))
struct FileOrderAndNameTests {
    static let scriptFiles: [(String, String)] = [
        ("main.swift", """
        var shop = Shop()
        shop.add(Item(name: "pen", price: 2))
        shop.add(Item(name: "cup", price: 5))
        print(shop.summary())
        print(format(total: shop.total))
        """),
        ("Models/Item.swift", """
        struct Item {
            var name: String
            var price: Int
        }
        """),
        ("Models/Shop.swift", """
        struct Shop {
            var items: [Item] = []
            mutating func add(_ i: Item) { items.append(i) }
        }
        """),
        ("Extensions/Shop+Summary.swift", """
        extension Shop {
            var total: Int { items.reduce(0) { $0 + $1.price } }
            func summary() -> String { items.map { $0.name }.joined(separator: ",") }
        }
        func format(total: Int) -> String { "total=\\(total)" }
        """),
    ]

    @Test func allFileOrdersProduceSameScriptOutput() async throws {
        let files = TestSupport.files(Self.scriptFiles)
        var outputs = Set<String>()
        for perm in permutations(files) {
            let out = try await runScript(TestSupport.program(perm))
            #expect(out.errors.isEmpty, "\(out.errors)")
            outputs.insert(out.console)
        }
        #expect(outputs == ["pen,cup\ntotal=7\n"])
    }

    @Test func shuffledFileOrderProducesSameRenderTree() async throws {
        var files = try TestSupport.loadDirectory("counter")
        files.append(contentsOf: TestSupport.files([
            ("Sources/Views/Header.swift", "import SwiftUI\nstruct Header: View { var title: String\n var body: some View { Text(title).bold() } }"),
            ("Sources/Views/Page.swift", "import SwiftUI\nstruct Page: View { var body: some View { VStack { Header(title: \"Hi\"); ContentView() } } }"),
        ]))
        var rng = SeededRNG(state: 42)
        var trees = Set<String>()
        var diagnostics = Set<String>()
        for _ in 0..<20 {
            let shuffled = files.shuffled(using: &rng)
            let v = await validate(TestSupport.program(shuffled))
            diagnostics.insert(v.diagnostics.map(\.message).joined(separator: "|") + "\(v.entryPoints)")
            let s = try await UISession.start(TestSupport.program(shuffled), entry: .rootView(symbol: "Page"))
            let t = try await s.tap("Increment")
            trees.insert(normalizedJSON(try #require(t)))
            await s.stop()
        }
        #expect(trees.count == 1)
        #expect(diagnostics.count == 1)
    }

    @Test func crossFilePrivateMemberIsNameResolutionError() async {
        let files = TestSupport.files([
            ("Models/Vault.swift", "struct Vault {\n    private var code = 42\n    var visible = 1\n}"),
            ("main.swift", "let v = Vault()\nprint(v.code)\nprint(v.visible)"),
        ])
        let v = await validate(TestSupport.program(files))
        let d = try? #require(v.diagnostics.first { $0.kind == .nameResolution })
        #expect(d?.range?.start.fileID == FileID("main.swift"))
        #expect(d?.range?.start.line == 2)
        #expect(d?.range?.start.column == 9)
        #expect(d?.message.contains("private") == true)
    }

    @Test func crossFilePrivateFunctionIsNameResolutionError() async {
        let files = TestSupport.files([
            ("Util.swift", "private func helper() -> Int { 1 }\nfunc pub() -> Int { helper() }"),
            ("main.swift", "print(pub())\nprint(helper())"),
        ])
        let v = await validate(TestSupport.program(files))
        let ds = v.diagnostics.filter { $0.kind == .nameResolution }
        #expect(ds.count == 1)
        #expect(ds.first?.range?.start.fileID == FileID("main.swift"))
        #expect(ds.first?.range?.start.line == 2)
        #expect(ds.first?.range?.start.column == 7)
    }

    @Test func undeclaredSymbolPointsToCorrectFileLineColumn() async {
        let files = TestSupport.files([
            ("A.swift", "struct A { var x = 1 }"),
            ("main.swift", "let a = A()\nlet 名字 = unknownName + a.x"),
        ])
        let v = await validate(TestSupport.program(files))
        let d = v.diagnostics.first { $0.kind == .nameResolution }
        #expect(d?.range?.start.fileID == FileID("main.swift"))
        #expect(d?.range?.start.line == 2)
        // 列按 UTF-8 字节计："let " (4) + "名字" (6) + " = " (3) → 第 14 列
        #expect(d?.range?.start.column == 14)
        let src = "let a = A()\nlet 名字 = unknownName + a.x"
        let expectedOffset = src.utf8.count - "unknownName + a.x".utf8.count
        #expect(d?.range?.start.utf8Offset == expectedOffset)
    }

    @Test func privateSetterBlocksCrossFileMutation() async {
        let files = TestSupport.files([
            ("Counter.swift", "struct Counter { private(set) var value = 0\n mutating func tick() { value += 1 } }"),
            ("main.swift", "var c = Counter()\nc.tick()\nc.value = 5"),
        ])
        let v = await validate(TestSupport.program(files))
        #expect(v.diagnostics.contains { $0.kind == .nameResolution && $0.message.contains("setter") && $0.range?.start.line == 3 })
    }

    @Test func sourceMapRoundTripsLineColumn() {
        let file = SourceFile(id: FileID("x.swift"), path: "x.swift", contents: "ab\n名字c\n\nz")
        let map = SourceMap(file: file)
        let loc = map.location(utf8Offset: 9)   // "c" in line 2
        #expect(loc.line == 2 && loc.column == 7)
        #expect(map.utf8Offset(line: 2, column: 7) == 9)
        #expect(map.location(utf8Offset: 11).line == 3)
        #expect(map.location(utf8Offset: 12).line == 4)
    }
}
