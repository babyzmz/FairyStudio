import SwiftUI
import FoundationAI

// 助手左面板：个人信息、设置入口、对话历史列表。
// iPad 三栏布局中常驻为侧栏；iPhone 由工具条按钮以 sheet 呈现（同一视图）。

struct AssistantSidebarView: View {
    @Bindable var session: AssistantSession

    var body: some View {
        // 注意：不要在这里再包 NavigationStack——本视图作为推入视图嵌在外层
        // LibraryView 的 NavigationStack(path:) 里，嵌套栈会触发
        // SwiftUI AnyNavigationPath comparisonTypeMismatch 崩溃（iOS 26/27）。
        // sheet 呈现（iPhone / iPad 窄幅）由调用方包栈。
        List {
            Section {
                profileBlock
                LabeledContent("设置", value: "在首页右上角")
                    .foregroundStyle(.secondary)
            }
            Section("对话历史") {
                Button {
                    session.newConversation()
                } label: {
                    Label("新对话", systemImage: "plus.bubble")
                }
                .accessibilityIdentifier("assistant.newChat")
                ForEach(sortedConversations) { conversation in
                    row(conversation)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        deleteConversation(at: index)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("助手")
        .navigationBarTitleDisplayMode(.inline)

    }

    private var sortedConversations: [AssistantConversation] {
        session.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var profileBlock: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(UIDevice.current.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("FairyStudio \(Self.appVersion) · 我的作品库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.profile")
    }

    private func row(_ conversation: AssistantConversation) -> some View {
        Button {
            session.selectConversation(conversation.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.subheadline.weight(conversation.id == session.currentConversationID ? .semibold : .regular))
                        .lineLimit(1)
                    Text(conversation.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if conversation.id == session.currentConversationID {
                    Image(systemName: "bubble.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("assistant.conversation.\(conversation.title)")
    }

    private func deleteConversation(at index: Int) {
        let sorted = sortedConversations
        guard index < sorted.count else { return }
        session.deleteConversation(sorted[index].id)
    }
}

extension AssistantSidebarView {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
