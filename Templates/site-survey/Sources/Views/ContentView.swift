import SwiftUI

struct SiteSurveyView: View {
    @State private var model = SurveyModel()
    @State private var device = ""
    @State private var location = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("现场勘察").font(.title)
            TextField("设备编号", text: $device)
                .padding(.horizontal)
            TextField("安装位置", text: $location)
                .padding(.horizontal)
            Button("追加记录") {
                if device != "" {
                    model.add(device: device, location: location)
                    device = ""
                    location = ""
                }
            }
            .buttonStyle(.borderedProminent)
            Text("已录 \(model.rows.count) 台 · 正常 \(model.okCount) 台").font(.caption)
            List {
                ForEach(model.rows.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.rows[i].device).font(.callout)
                        Text(model.rows[i].location).font(.caption)
                        Button(model.rows[i].status == "正常" ? "标记待整改" : "恢复正常") {
                            model.toggleStatus(i)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.top)
    }
}
