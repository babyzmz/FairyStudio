import SwiftUI

struct ExpenseSplitView: View {
    @State private var model = SplitModel()
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("费用分摊").font(.title)
                HStack {
                    Button("− 总费用") { model.lessTotal() }
                    Text("总费用 \(model.total) 元")
                    Button("+ 总费用") { model.moreTotal() }
                }
                ForEach(model.members.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.members[i].name)
                            Spacer()
                            Text("分摊 \(model.share(i)) 元").font(.callout)
                        }
                        HStack {
                            Button("−15 分") { model.lessMinutes(i) }
                            Text("\(model.members[i].minutes) 分钟")
                            Button("+15 分") { model.moreMinutes(i) }
                        }
                        Divider()
                    }
                }
                HStack {
                    TextField("新成员", text: $draft)
                    Button("加入") {
                        if draft != "" {
                            model.addMember(draft)
                            draft = ""
                        }
                    }
                }
                Text("总时长 \(model.totalMinutes) 分钟").font(.caption)
            }
            .padding()
        }
    }
}
