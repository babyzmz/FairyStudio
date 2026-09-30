import SwiftUI

struct PlanCompareView: View {
    @State private var model = PlanCompareModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("设备方案演算").font(.title)
                Stepper("设备数量：\(model.units)", value: $model.units, in: 1...30)
                Toggle("监测模块", isOn: $model.monitoring)
                Toggle("报表模块", isOn: $model.reporting)
                ForEach(model.current.summary().indices, id: \.self) { i in
                    Text(model.current.summary()[i])
                }
                HStack {
                    Button("存为方案 A") { model.saveA() }
                    Button("存为方案 B") { model.saveB() }
                }
                Divider()
                ForEach(model.savedLines.indices, id: \.self) { i in
                    Text(model.savedLines[i]).font(.callout)
                }
                Text(model.diffText).font(.headline)
            }
            .padding()
        }
    }
}
