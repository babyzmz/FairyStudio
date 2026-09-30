import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("计数器夹具（两个互相引用的文件）", .timeLimit(.minutes(1)))
struct CounterFixtureTests {
    @Test func counterFixtureFilesArePresent() throws {
        let files = try TestSupport.loadDirectory("counter")
        #expect(files.map(\.path) == ["Sources/Models/Counter.swift", "Sources/Views/ContentView.swift"])
    }

    @Test func counterRootViewRendersAndIncrementsOnAction() async throws {
        let files = try TestSupport.loadDirectory("counter")
        let s = try await UISession.start(TestSupport.program(files), entry: .rootView(symbol: "ContentView"))
        let t1 = try #require(s.lastTree)
        #expect(t1.revision == 1)
        #expect(t1.runID == s.handle.runID)
        #expect(t1.root.texts.contains("Count: 0"))
        let inc = try #require(t1.root.button(labeled: "Increment"))
        guard case .button(let aid, _) = inc.kind else { Issue.record("不是按钮"); return }
        #expect(inc.modifiers.contains(.buttonStyle("borderedProminent")))
        let reset = try #require(t1.root.button(labeled: "Reset"))
        #expect(reset.modifiers.contains(.disabled(true)))
        #expect(t1.root.node(withText: "Count: 0")?.modifiers.contains(.font(.title)) == true)
        guard case .vstack(_, let spacing) = t1.root.kind else { Issue.record("根节点应为 VStack"); return }
        #expect(spacing == 16)

        await s.send(.action(aid))
        let t2 = try #require(await s.nextRender())
        #expect(t2.revision == 2)
        #expect(t2.root.texts.contains("Count: 1"))
        #expect(t2.root.button(labeled: "Reset")?.modifiers.contains(.disabled(false)) == true)
        // 同一按钮在重新渲染后 ActionID 稳定
        guard case .button(let aid2, _)? = t2.root.button(labeled: "Increment")?.kind else { return }
        #expect(aid2 == aid)

        let t3 = try #require(try await s.tap("Increment"))
        #expect(t3.revision == 3)
        #expect(t3.root.texts.contains("Count: 2"))
        let t4 = try #require(try await s.tap("Reset"))
        #expect(t4.root.texts.contains("Count: 0"))
        await s.stop()
        #expect(s.outcome.states == [.validating, .preparing, .running, .stopping, .stopped])
        #expect(s.outcome.finished == .stoppedByUser)
    }

    @Test func counterViaMainAppEntry() async throws {
        var files = try TestSupport.loadDirectory("counter")
        files.append(SourceFile(id: FileID("Sources/App/CounterApp.swift"), path: "Sources/App/CounterApp.swift", contents: """
        import SwiftUI

        @main
        struct CounterApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """))
        let v = await validate(TestSupport.program(files))
        #expect(v.isRunnable)
        #expect(v.entryPoints.contains(.mainApp))
        let s = try await UISession.start(TestSupport.program(files), entry: .mainApp)
        #expect(s.lastTree?.root.texts.contains("Count: 0") == true)
        let t = try await s.tap("Increment")
        #expect(t?.root.texts.contains("Count: 1") == true)
        await s.stop()
    }

    @Test func validateReportsEntryPointsAndCapabilities() async throws {
        let files = try TestSupport.loadDirectory("counter")
        let v = await validate(TestSupport.program(files))
        #expect(v.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(v.entryPoints == [.rootView(symbol: "ContentView")])
        for cap in ["view.Text", "view.Button", "view.VStack", "view.HStack", "propertyWrapper.State", "modifier.padding",
                    "modifier.font", "syntax.struct.mutating", "syntax.struct.computedProperty", "syntax.stringInterpolation"] {
            #expect(v.referencedCapabilities.contains(cap), "缺少 \(cap)")
        }
        let catalogIDs = Set(SwiftRuntimeEngine.catalog.entries.map(\.id))
        for cap in v.referencedCapabilities {
            #expect(catalogIDs.contains(cap), "catalog 中缺少 \(cap)")
        }
    }
}

/// M0-C：App 包内的 Counter 模板（仓库 Templates/Counter）必须与本夹具逐字节一致，
/// 保证模拟器 / 实机上跑的就是 macOS 单测验证过的同一份源码。
@Suite("App 模板与夹具一致")
struct AppTemplateConsistencyTests {
    @Test func appCounterTemplateMatchesFixture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/Packages/FairyCore/Tests/SwiftRuntimeTests/CounterFixtureTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let template = repoRoot.appendingPathComponent("Templates/counter")
        let fixture = try TestSupport.loadDirectory("counter")
        #expect(fixture.count == 2)
        for file in fixture {
            let copy = try String(contentsOf: template.appendingPathComponent(file.path), encoding: .utf8)
            #expect(copy == file.contents, "Templates/counter/\(file.path) 与夹具不一致")
        }
        let manifest = try String(contentsOf: template.appendingPathComponent("template.json"), encoding: .utf8)
        for file in fixture { #expect(manifest.contains("\"\(file.path)\"")) }
        #expect(manifest.contains("\"entrySymbol\": \"ContentView\""))
    }
}
