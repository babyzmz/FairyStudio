import Foundation
import FoundationAI

// 会话历史（内存态）：左面板的对话列表。当前对话的消息仍由 AssistantSession.messages
// 承载，切换时写回 / 读出；跨启动持久化待 M3（变更卡片含快照，需先设计序列化边界）。

struct AssistantConversation: Identifiable {
    let id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [AssistantMessage] = []

    init(title: String = "新对话") {
        self.title = title
    }

    /// 列表副标题：相对时间 + 消息数。
    var summary: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: updatedAt, relativeTo: Date())
        let count = messages.isEmpty ? "空" : "\(messages.count) 条消息"
        return "\(relative) · \(count)"
    }
}
