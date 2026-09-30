import SwiftUI

struct SiteChecklistView: View {
    @State private var model = ChecklistModel()
    @State private var reasonID = 0
    @State private var draftReason = ""
    @State private var showReport = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("安装验收").font(.title)
                ProgressView(value: Double(model.passed), total: Double(model.items.count))
                ForEach(model.items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.items[i].title).font(.callout)
                        HStack {
                            Button("通过") { model.setResult(model.items[i].id, "通过") }
                                .buttonStyle(.bordered)
                            Button("不通过") {
                                model.setResult(model.items[i].id, "不通过")
                                reasonID = model.items[i].id
                                draftReason = ""
                            }
                            .buttonStyle(.bordered)
                            Text(model.items[i].result).font(.caption)
                        }
                        if model.items[i].result == "不通过" && model.items[i].reason != "" {
                            Text("原因：\(model.items[i].reason)").font(.caption)
                        }
                        Divider()
                    }
                }
                if reasonID != 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("填写不通过原因：\(model.itemTitle(reasonID))").font(.callout)
                        TextField("问题描述（必填）", text: $draftReason)
                        Button("保存原因") {
                            model.setReason(reasonID, draftReason)
                            reasonID = 0
                            draftReason = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Button("生成验收小结") { showReport = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .sheet(isPresented: $showReport) {
            ScrollView {
                Text(model.report()).padding()
            }
        }
    }
}
