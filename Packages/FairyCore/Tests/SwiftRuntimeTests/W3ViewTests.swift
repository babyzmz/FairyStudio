import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

/// W3 UI 广度：Slider/Stepper/Picker/导航/sheet/alert/容器。
@Suite("W3 视图：控件/导航/呈现", .timeLimit(.minutes(2)))
struct W3ViewTests {
    // MARK: - 查找辅助

    static func kinds(_ t: RenderTree?) -> [RenderKind] { t?.root.allNodes.map(\.kind) ?? [] }

    static func first<T>(_ t: RenderTree?, match: (RenderKind) -> T?) -> T? {
        t?.root.allNodes.compactMap { match($0.kind) }.first
    }

    static func linkID(_ t: RenderTree?, containing text: String) -> NodeID? {
        t?.root.allNodes.first {
            if case .navigationLink = $0.kind { return $0.texts.contains(text) }
            return false
        }.flatMap {
            if case .navigationLink(let id) = $0.kind { return id }
            return nil
        }
    }

    static func sheetHost(_ t: RenderTree?) -> RenderNode? {
        t?.root.allNodes.first { if case .sheetHost = $0.kind { return true }; return false }
    }

    static func alertHost(_ t: RenderTree?) -> RenderNode? {
        t?.root.allNodes.first { if case .alertHost = $0.kind { return true }; return false }
    }

    // MARK: - 控件

    @Test func sliderBindingWritesBack() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var speed = 50.0
            var body: some View {
                VStack {
                    Slider(value: $speed, in: 0...100, step: 5)
                    Text("speed \\(speed)")
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let slider = try #require(Self.first(s.lastTree) { k in
            if case .slider(let bid, let value, let lo, let hi, let step) = k { return (bid, value, lo, hi, step) }
            return nil
        })
        #expect(slider.1 == 50 && slider.2 == 0 && slider.3 == 100 && slider.4 == 5)
        await s.send(.setBinding(slider.0, .double(75)))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("speed 75.0") == true)
        // 类型不匹配的写入 → 受控错误
        await s.send(.setBinding(slider.0, .string("x")))
        await s.stop()
        #expect(s.outcome.errors.contains { $0.kind == .typeCheck })
    }

    @Test func stepperRendersLabelAndBounds() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var count = 3
            var body: some View {
                Stepper("Count", value: $count, in: 0...10)
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let stepper = try #require(Self.first(s.lastTree) { k in
            if case .stepper(let bid, let value, let lo, let hi) = k { return (bid, value, lo, hi) }
            return nil
        })
        #expect(stepper.1 == 3 && stepper.2 == 0 && stepper.3 == 10)
        #expect(s.lastTree?.root.texts.contains("Count") == true)
        await s.send(.setBinding(stepper.0, .int(7)))
        let t = await s.nextRender()
        let stepper2 = try #require(Self.first(t) { k in
            if case .stepper(_, let value, _, _) = k { return value }
            return nil
        })
        #expect(stepper2 == 7)
        await s.stop()
    }

    @Test func pickerOptionsAndSelection() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var flavor = "van"
            var body: some View {
                VStack {
                    Picker("Flavor", selection: $flavor) {
                        ForEach(["van", "choc"], id: \\.self) { f in
                            Text(f).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("pick \\(flavor)")
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let picker = try #require(Self.first(s.lastTree) { k in
            if case .picker(let bid, let sel, let opts) = k { return (bid, sel, opts) }
            return nil
        })
        #expect(picker.1 == .string("van"))
        #expect(picker.2.map(\.label) == ["van", "choc"])
        #expect(picker.2.map(\.tag) == [.string("van"), .string("choc")])
        await s.send(.setBinding(picker.0, .string("choc")))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("pick choc") == true)
        await s.stop()
    }

    // MARK: - 导航（B-2）

    @Test func navigationPushPopUnbound() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                NavigationStack {
                    VStack {
                        NavigationLink("Go", value: "d1")
                        Text("home")
                    }
                    .navigationDestination(for: String.self) { s in
                        Text("dest \\(s)")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        #expect(s.lastTree?.root.texts.contains("home") == true)
        let did = try #require(Self.linkID(s.lastTree, containing: "Go"))
        await s.send(.navigationPush(destinationID: did))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("dest d1") == true)
        #expect(t?.root.texts.contains("home") == true)
        await s.send(.navigationPop(count: 1))
        let t2 = await s.nextRender()
        #expect(t2?.root.texts.contains("dest d1") != true)
        #expect(t2?.root.texts.contains("home") == true)
        await s.stop()
    }

    @Test func navigationPathBinding() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var path: [String] = []
            var body: some View {
                NavigationStack(path: $path) {
                    VStack {
                        NavigationLink(value: 7) { Text("Seven") }
                        Button("AddC") { path.append("c") }
                        Text("depth \\(path.count)")
                    }
                    .navigationDestination(for: String.self) { s in
                        Text("str \\(s)")
                    }
                    .navigationDestination(for: Int.self) { i in
                        Text("int \\(i)")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        // Int 链接推入 path 绑定（记为 "7"，按 Int 目标解析）
        let did = try #require(Self.linkID(s.lastTree, containing: "Seven"))
        await s.send(.navigationPush(destinationID: did))
        let t = try #require(await s.nextRender())
        #expect(t.root.texts.contains("int 7") == true)
        #expect(t.root.texts.contains("depth 1") == true)
        // 代码直接改 path
        _ = try await s.tap("AddC")
        let t2 = try #require(s.lastTree)
        #expect(t2.root.texts.contains("str c") == true)
        #expect(t2.root.texts.contains("depth 2") == true)
        await s.send(.navigationPop(count: 2))
        let t3 = try #require(await s.nextRender())
        #expect(t3.root.texts.contains("depth 0") == true)
        await s.stop()
    }

    @Test func navigationDestinationLinkForm() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                NavigationStack {
                    NavigationLink("Open") {
                        Text("detail page")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let did = try #require(Self.linkID(s.lastTree, containing: "Open"))
        await s.send(.navigationPush(destinationID: did))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("detail page") == true)
        await s.stop()
    }

    // MARK: - sheet / alert（B-3/B-4）

    @Test func sheetPresentDismiss() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var show = false
            @State private var speed = 3.0
            @State private var dismissed = 0
            var body: some View {
                VStack {
                    Button("Show") { show = true }
                    Text("dismissed \\(dismissed)")
                }
                .sheet(isPresented: $show, onDismiss: { dismissed += 1 }) {
                    Text("sheet speed \\(speed)")
                    Button("Faster") { speed += 1 }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        var host = try #require(Self.sheetHost(s.lastTree))
        guard case .sheetHost(let presented0, _) = host.kind else { Issue.record("应为 sheetHost"); return }
        #expect(presented0 == false)
        _ = try await s.tap("Show")
        host = try #require(Self.sheetHost(s.lastTree))
        guard case .sheetHost(let presented1, let dismiss) = host.kind else { return }
        #expect(presented1 == true)
        #expect(host.texts.contains("sheet speed 3.0"))
        // sheet 内容闭包捕获 state：内部按钮写回
        _ = try await s.tap("Faster")
        #expect(Self.sheetHost(s.lastTree)?.texts.contains("sheet speed 4.0") == true)
        // 手势关闭 → 写 false + 跑 onDismiss
        await s.send(.action(dismiss))
        let t = await s.nextRender()
        if case .sheetHost(let presented2, _)? = Self.sheetHost(t)?.kind { #expect(presented2 == false) }
        #expect(t?.root.texts.contains("dismissed 1") == true)
        await s.stop()
    }

    @Test func alertButtonsAndAutoDismiss() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var show = false
            @State private var result = "none"
            @State private var count = 2
            var body: some View {
                VStack {
                    Button("Ask") { show = true }
                    Text("result \\(result)")
                }
                .alert("Hi", isPresented: $show) {
                    Button("OK") { result = "ok" }
                    Button("Cancel", role: .cancel) { result = "cancel" }
                } message: {
                    Text("msg \\(count)")
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        _ = try await s.tap("Ask")
        let host = try #require(Self.alertHost(s.lastTree))
        guard case .alertHost(let title, let message, let presented, let buttons) = host.kind else {
            Issue.record("应为 alertHost"); return
        }
        #expect(title == "Hi" && message == "msg 2" && presented == true)
        #expect(buttons.map(\.title) == ["OK", "Cancel"])
        #expect(buttons.allSatisfy { $0.action != nil })
        // 点 OK：用户动作执行 + 自动关闭
        await s.send(.action(try #require(buttons[0].action)))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("result ok") == true)
        if case .alertHost(_, _, let presented2, _)? = Self.alertHost(t)?.kind { #expect(presented2 == false) }
        await s.stop()
    }

    // MARK: - 容器与修饰器

    @Test func w3ContainersRender() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                ScrollView(.horizontal) {
                    Group {
                        Image(systemName: "star")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let kinds = Self.kinds(s.lastTree)
        #expect(kinds.contains(.scrollView(.horizontal)))
        #expect(kinds.contains(.group))
        #expect(kinds.contains(.image(.systemName("star"))))
        await s.stop()
    }

    @Test func w3ControlsRender() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var name = ""
            var body: some View {
                Form {
                    Section("H", footer: "F") {
                        TextField("Name", text: $name)
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let kinds = Self.kinds(s.lastTree)
        #expect(kinds.contains(.form))
        #expect(kinds.contains(.section(header: "H", footer: "F")))
        await s.stop()
    }

    @Test func taskRunsSyncBodyOnce() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var n = 0
            func compute() -> Int { 41 + 1 }
            var body: some View {
                Text("n \\(n)")
                    .task { n = await compute() }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        #expect(s.lastTree?.root.texts.contains("n 0") == true)
        guard let taskAction = s.lastTree?.root.allNodes.compactMap({ n -> ActionID? in
            if case .task(let aid) = n.modifiers.first(where: { if case .task = $0 { return true }; return false }) { return aid }
            return nil
        }).first else { Issue.record("缺少 task"); return }
        await s.send(.action(taskAction))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("n 42") == true)
        await s.stop()
    }
}
