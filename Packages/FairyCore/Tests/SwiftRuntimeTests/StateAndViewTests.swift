import Foundation
import RuntimeContracts
@testable import SwiftRuntime
import Testing

@Suite("@State / @Binding / ForEach / 视图子集", .timeLimit(.minutes(1)))
struct StateAndViewTests {
    static let listProgram = TestSupport.program(TestSupport.files([
        ("Views/Row.swift", """
        import SwiftUI
        struct Row: View {
            let title: String
            @State private var likes = 0
            var body: some View {
                HStack {
                    Text("\\(title):\\(likes)")
                    Spacer()
                    Button("Like \\(title)") { likes += 1 }
                }
            }
        }
        """),
        ("Views/ListView.swift", """
        import SwiftUI
        struct ListView: View {
            @State private var items = ["a", "b", "c"]
            var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \\.self) { item in
                        Row(title: item)
                    }
                    Divider()
                    Button("Reverse") { items.reverse() }
                    Button("Drop b") { items.removeAll { $0 == "b" } }
                    Button("Add b") { items.append("b") }
                }
            }
        }
        """),
    ]))

    func rowTexts(_ t: RenderTree?) -> [String] {
        (t?.root.texts ?? []).filter { $0.contains(":") }
    }

    @Test func forEachReorderKeepsRowStateWithItsID() async throws {
        let s = try await UISession.start(Self.listProgram, entry: .rootView(symbol: "ListView"))
        #expect(rowTexts(s.lastTree) == ["a:0", "b:0", "c:0"])
        var t = try await s.tap("Like b")
        t = try await s.tap("Like b")
        #expect(rowTexts(t) == ["a:0", "b:2", "c:0"])
        t = try await s.tap("Reverse")
        #expect(rowTexts(t) == ["c:0", "b:2", "a:0"])
        t = try await s.tap("Like c")
        #expect(rowTexts(t) == ["c:1", "b:2", "a:0"])
        // 删除后再插入：视图离开层级后状态丢弃（与 SwiftUI 一致）
        t = try await s.tap("Drop b")
        #expect(rowTexts(t) == ["c:1", "a:0"])
        t = try await s.tap("Add b")
        #expect(rowTexts(t) == ["c:1", "a:0", "b:0"])
        // 行节点 id 含稳定 id
        let ids = t?.root.allNodes.map(\.id.rawValue).filter { $0.contains("[\"c\"]") } ?? []
        #expect(!ids.isEmpty)
        await s.stop()
    }

    @Test func textFieldSetBindingWritesBack() async throws {
        let program = TestSupport.program(TestSupport.files([("Form.swift", """
        import SwiftUI
        struct NameForm: View {
            @State private var name = ""
            @State private var subscribed = false
            var body: some View {
                VStack {
                    TextField("Your name", text: $name)
                    Toggle("Subscribe", isOn: $subscribed)
                    Text(name.isEmpty ? "Hello, stranger" : "Hello, \\(name)")
                    if subscribed {
                        Text("Thanks for subscribing")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "NameForm"))
        let tf = try #require(s.lastTree?.root.textFields.first)
        guard case .textField(let placeholder, let bid, let text) = tf.kind else { return }
        #expect(placeholder == "Your name" && text == "")
        await s.send(.setBinding(bid, .string("Ada")))
        let t = await s.nextRender()
        #expect(t?.root.texts.contains("Hello, Ada") == true)
        guard case .textField(_, _, let text2)? = t?.root.textFields.first?.kind else { return }
        #expect(text2 == "Ada")
        let toggle = try #require(t?.root.toggles.first)
        guard case .toggle(let tid, let isOn) = toggle.kind else { return }
        #expect(isOn == false)
        await s.send(.setBinding(tid, .bool(true)))
        let t2 = await s.nextRender()
        #expect(t2?.root.texts.contains("Thanks for subscribing") == true)
        // 类型不匹配的写入 → 受控错误，不崩溃
        await s.send(.setBinding(bid, .int(3)))
        await s.stop()
        #expect(s.outcome.errors.contains { $0.kind == .typeCheck })
    }

    @Test func bindingPassedToChildWritesParentState() async throws {
        let program = TestSupport.program(TestSupport.files([
            ("Parent.swift", """
            import SwiftUI
            struct Parent: View {
                @State private var count = 0
                var body: some View {
                    VStack {
                        Text("parent \\(count)")
                        Stepperish(value: $count)
                    }
                }
            }
            """),
            ("Child.swift", """
            import SwiftUI
            struct Stepperish: View {
                @Binding var value: Int
                @State private var taps = 0
                var body: some View {
                    HStack {
                        Button("Plus") {
                            value += 1
                            taps += 1
                        }
                        Text("child \\(value) taps \\(taps)")
                    }
                }
            }
            """),
        ]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "Parent"))
        var t = try await s.tap("Plus")
        t = try await s.tap("Plus")
        #expect(t?.root.texts.contains("parent 2") == true)
        // 子视图的 @State 在父视图重建时不被重新初始化
        #expect(t?.root.texts.contains("child 2 taps 2") == true)
        await s.stop()
    }

    @Test func conditionalBranchesAndOnAppear() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var showDetail = false
            @State private var appeared = 0
            var body: some View {
                NavigationStack {
                    List {
                        if showDetail {
                            Text("detail")
                        } else {
                            Text("summary")
                        }
                        Button(showDetail ? "Hide" : "Show") { showDetail.toggle() }
                        Text("appeared \\(appeared)")
                    }
                    .navigationTitle("Demo")
                    .onAppear { appeared += 1 }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let t1 = try #require(s.lastTree)
        guard case .navigationStack = t1.root.kind else { Issue.record("根应为 NavigationStack"); return }
        let list = try #require(t1.root.allNodes.first { $0.kind == .list })
        #expect(list.modifiers.contains(.navigationTitle("Demo")))
        #expect(t1.root.texts.contains("summary"))
        let t2 = try await s.tap("Show")
        #expect(t2?.root.texts.contains("detail") == true)
        #expect(t2?.root.button(labeled: "Hide") != nil)
        // onAppear 闭包由宿主发送对应 .action(ActionID) 触发（契约裁决 B-5）；.appear(NodeID) 只记账。
        guard case .onAppear(let appearAction)? = list.modifiers.first(where: { if case .onAppear = $0 { return true }; return false }) else {
            Issue.record("List 应带 onAppear"); return
        }
        await s.send(.appear(list.id))
        await s.send(.action(appearAction))
        let t3 = await s.nextRender()
        #expect(t3?.root.texts.contains("appeared 1") == true)
        await s.stop()
    }

    @Test func modifiersMapToRenderModifiers() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            var body: some View {
                ZStack(alignment: .top) {
                    Text("styled")
                        .font(.headline)
                        .bold()
                        .foregroundStyle(.red)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(width: 100, height: 40)
                        .background(Color.yellow)
                        .cornerRadius(6)
                        .opacity(0.5)
                    Spacer(minLength: 10)
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let text = try #require(s.lastTree?.root.node(withText: "styled"))
        #expect(text.modifiers == [
            .font(.headline), .bold, .foregroundColor(ColorValue(named: .red)), .foregroundColor(ColorValue(named: .blue)),
            .padding(.horizontal, 8), .padding(.all, 12),
            .frame(width: nil, height: nil, maxWidth: .infinity, maxHeight: nil, alignment: .leading),
            .frame(width: 100, height: 40, maxWidth: nil, maxHeight: nil, alignment: nil),
            .background(ColorValue(named: .yellow)), .cornerRadius(6), .opacity(0.5),
        ])
        guard case .zstack(let a)? = s.lastTree?.root.kind else { Issue.record("应为 ZStack"); return }
        #expect(a == .top)
        await s.stop()
    }

    @Test func forEachOverIdentifiableAndRange() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct Todo: Identifiable {
            var id: Int
            var title: String
        }
        struct V: View {
            @State private var todos = [Todo(id: 1, title: "one"), Todo(id: 2, title: "two")]
            var body: some View {
                VStack {
                    ForEach(todos) { todo in
                        Text(todo.title)
                    }
                    ForEach(0..<3) { i in
                        Text("row \\(i)")
                    }
                    ForEach(todos, id: \\.id) { todo in
                        Text("#\\(todo.id)")
                    }
                }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        #expect(s.lastTree?.root.texts == ["one", "two", "row 0", "row 1", "row 2", "#1", "#2"])
        let ids = Set(s.lastTree?.root.allNodes.map(\.id.rawValue) ?? [])
        #expect(ids.count == s.lastTree?.root.allNodes.count)   // NodeID 唯一
        await s.stop()
    }

    @Test func runtimeErrorInsideActionEndsRunWithTrap() async throws {
        let program = TestSupport.program(TestSupport.files([("V.swift", """
        import SwiftUI
        struct V: View {
            @State private var items: [Int] = []
            var body: some View {
                Button("Crash") { print(items[3]) }
            }
        }
        """)]))
        let s = try await UISession.start(program, entry: .rootView(symbol: "V"))
        let t = try await s.tap("Crash")
        #expect(t == nil)
        await s.stop()
        #expect(s.outcome.isTrap)
        #expect(s.outcome.errors.contains { $0.kind == .runtimeTrap && $0.range?.start.line == 5 })
        #expect(s.outcome.states.last == .failed)
    }
}
