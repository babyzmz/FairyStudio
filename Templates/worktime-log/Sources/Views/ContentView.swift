import SwiftUI

struct WorktimeLogView: View {
    @State private var model = WorktimeModel()
    @State private var client = "客户甲"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("工时本").font(.title)
                Picker("客户", selection: $client) {
                    ForEach(model.clients.indices, id: \.self) { i in
                        Text(model.clients[i]).tag(model.clients[i])
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button("15 分钟") { model.add(client: client, minutes: 15) }
                        .buttonStyle(.bordered)
                    Button("30 分钟") { model.add(client: client, minutes: 30) }
                        .buttonStyle(.borderedProminent)
                    Button("60 分钟") { model.add(client: client, minutes: 60) }
                        .buttonStyle(.bordered)
                    Button("120 分钟") { model.add(client: client, minutes: 120) }
                        .buttonStyle(.bordered)
                }
                Divider()
                ForEach(model.clients.indices, id: \.self) { i in
                    let c = model.clients[i]
                    HStack {
                        Text(c)
                        Spacer()
                        Text(model.hours(model.total(for: c))).font(.callout)
                    }
                }
                Divider()
                ForEach(model.entries.indices, id: \.self) { i in
                    Text("\(model.entries[i].client) · \(model.entries[i].minutes) 分钟")
                        .font(.caption)
                }
            }
            .padding()
        }
    }
}
