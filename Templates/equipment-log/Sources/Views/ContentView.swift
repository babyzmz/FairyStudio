import SwiftUI

struct EquipmentLogView: View {
    @State private var model = EquipmentModel()
    @State private var draftItem = ""
    @State private var draftPerson = ""
    @State private var filter = "全部"
    @State private var activity = "全部活动"

    var body: some View {
        VStack(spacing: 10) {
            TextField("器材名称", text: $draftItem)
                .padding(.horizontal)
            TextField("借给谁", text: $draftPerson)
                .padding(.horizontal)
            Picker("活动", selection: $activity) {
                ForEach(model.activities().indices, id: \.self) { i in
                    Text(model.activities()[i]).tag(model.activities()[i])
                }
            }
            .pickerStyle(.menu)
            Picker("筛选", selection: $filter) {
                Text("全部").tag("全部")
                Text("借出中").tag("借出中")
                Text("已归还").tag("已归还")
            }
            .pickerStyle(.segmented)
            Button("登记借出") {
                if draftItem != "" && draftPerson != "" {
                    model.add(item: draftItem, person: draftPerson, activity: activity == "全部活动" ? "日常" : activity)
                    draftItem = ""
                    draftPerson = ""
                }
            }
            .buttonStyle(.borderedProminent)
            List {
                ForEach(model.filtered(filter, activity: activity).indices, id: \.self) { i in
                    let r = model.filtered(filter, activity: activity)[i]
                    HStack {
                        Button(r.out ? "归还" : "再借出") {
                            model.toggle(r.id)
                        }
                        VStack(alignment: .leading) {
                            Text(r.item).font(.callout)
                            Text("借给 \(r.person) · \(r.activity)").font(.caption)
                        }
                        Spacer()
                        Text(r.out ? "借出中" : "已还").font(.caption)
                    }
                }
            }
        }
        .padding(.top)
    }
}
