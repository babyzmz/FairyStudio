import SwiftUI

struct DataWorkbenchView: View {
    @State private var model = SalesModel()
    @State private var region = "全部"
    @State private var includeUndone = true
    @State private var byAmount = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("销售数据台").font(.title)
                Picker("区域", selection: $region) {
                    ForEach(model.regions().indices, id: \.self) { i in
                        Text(model.regions()[i]).tag(model.regions()[i])
                    }
                }
                .pickerStyle(.segmented)
                Toggle("包含未完成记录", isOn: $includeUndone)
                Toggle("按金额排序", isOn: $byAmount)
                Divider()
                ForEach(model.filtered(region: region, includeUndone: includeUndone, byAmount: byAmount).indices, id: \.self) { i in
                    let r = model.filtered(region: region, includeUndone: includeUndone, byAmount: byAmount)[i]
                    HStack {
                        Text("\(r.region) · \(r.month)")
                        Spacer()
                        Text("\(r.amount) 元").font(.callout)
                        Text(r.done ? "已完成" : "进行中").font(.caption)
                    }
                }
                Divider()
                Text("按区域汇总").font(.headline)
                ForEach(model.totals(for: model.filtered(region: region, includeUndone: includeUndone, byAmount: byAmount)).indices, id: \.self) { i in
                    Text(model.totals(for: model.filtered(region: region, includeUndone: includeUndone, byAmount: byAmount))[i])
                        .font(.callout)
                }
            }
            .padding()
        }
    }
}
