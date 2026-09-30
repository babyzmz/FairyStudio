import SwiftUI

struct DeviceDashboardView: View {
    @State private var model = DashboardModel()
    @State private var threshold = 40

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("设备温度面板").font(.title)
                HStack {
                    Image(systemName: model.latest > Double(threshold) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text("当前 \(String(format: "%.1f", model.latest)) ℃").font(.headline)
                    Text("峰值 \(String(format: "%.1f", model.peak)) ℃").font(.caption)
                }
                Stepper("告警阈值：\(Int(threshold)) ℃", value: $threshold, in: 30...48)
                Divider()
                ForEach(model.readings().indices, id: \.self) { i in
                    HStack {
                        Text("t\(i)").font(.caption)
                        ProgressView(value: model.readings()[i], total: 50)
                        Text(String(format: "%.1f", model.readings()[i])).font(.caption)
                        Image(systemName: model.readings()[i] > Double(threshold) ? "circle.fill" : "circle")
                            .font(.caption)
                    }
                }
                Text("实心点 = 超过阈值（\(Int(threshold)) ℃）").font(.caption)
            }
            .padding()
        }
    }
}
