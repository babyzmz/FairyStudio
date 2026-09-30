import SwiftUI

struct LiveDemoView: View {
    @State private var model = DemoModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("培训排期演算").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("学员人数：\(model.headcount)")
                    Slider(value: $model.attendees, in: 10...120, step: 5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("教室数量：\(model.roomCount)")
                    Slider(value: $model.rooms, in: 1...8, step: 1)
                }
                Divider()
                Text("每室 \(model.perRoom) 人").font(.title)
                ProgressView(value: min(1.0, model.load))
                Text("负载判断：\(model.verdict)").font(.headline)
                if model.showNotes {
                    Divider()
                    Text("演讲备注：每室 20 人是体验上限；超过 100 人建议增加助教 1 名。")
                        .font(.callout)
                }
                Toggle("讲解模式（显示备注）", isOn: $model.showNotes)
            }
            .padding()
        }
    }
}
