import SwiftUI

struct ContentView: View {
    @State private var items: [TodoItem] = [
        TodoItem(id: 0, title: "运行这个模板", done: true),
        TodoItem(id: 1, title: "加一条待办", done: false)
    ]
    @State private var nextID = 2
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("新待办", text: $draft)
                Button("添加") {
                    if draft != "" {
                        items.append(TodoItem(id: nextID, title: draft, done: false))
                        nextID += 1
                        draft = ""
                    }
                }
            }
            .padding(.horizontal)
            if items.isEmpty {
                Text("全部完成！")
            }
            // 下标遍历：避免嵌套闭包，删除/切换都走下标写回 @State 数组。
            ForEach(items.indices, id: \.self) { i in
                HStack {
                    Button(items[i].done ? "已完成" : "未完成") {
                        items[i].done.toggle()
                    }
                    Text(items[i].title)
                    Button("删除") {
                        items.remove(at: i)
                    }
                }
            }
        }
        .padding()
    }
}
