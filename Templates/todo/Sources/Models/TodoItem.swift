// 待办清单模型：Identifiable 行 + 数组增删改。
struct TodoItem: Identifiable, Hashable {
    var id: Int
    var title: String
    var done: Bool
}
