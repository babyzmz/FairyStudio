import SwiftUI

struct TaskPanelView: View {
    @State private var model = OptionModel()
    @State private var showPlan = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("方案面板").font(.title)
                ForEach(model.options.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(model.options[i].selected ? "已选" : "未选") {
                                model.toggle(model.options[i].id)
                            }
                            .buttonStyle(model.options[i].selected ? .borderedProminent : .bordered)
                            Text(model.options[i].title)
                        }
                        HStack {
                            Button("−") { model.lessPriority(model.options[i].id) }
                            Text("优先级 \(model.options[i].priority)")
                            Button("+") { model.morePriority(model.options[i].id) }
                        }
                        .font(.callout)
                        Divider()
                    }
                }
                Button("根据当前选择生成计划") { showPlan = true }
                    .buttonStyle(.borderedProminent)
                Text("已选 \(model.chosen.count) / \(model.options.count)").font(.caption)
            }
            .padding()
        }
        .sheet(isPresented: $showPlan) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.planLines().indices, id: \.self) { i in
                        Text(model.planLines()[i])
                    }
                }
                .padding()
            }
        }
    }
}
