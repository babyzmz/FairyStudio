import SwiftUI

struct InboxTriageView: View {
    @State private var model = TriageModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("材料分拣").font(.title)
            Text("保留 \(model.count("保留")) · 归档 \(model.count("归档")) · 放弃 \(model.count("放弃"))")
                .font(.callout)
            List {
                ForEach(model.items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.items[i].name).font(.callout)
                        Button("用途：\(model.items[i].action)（点击切换）") {
                            model.cycle(i)
                        }
                        .font(.caption)
                    }
                }
            }
            Button("应用分拣") { model.apply() }
                .buttonStyle(.borderedProminent)
            if model.applied {
                Text("已按当前选择分拣完成。").font(.headline)
            }
        }
        .padding(.top)
    }
}
