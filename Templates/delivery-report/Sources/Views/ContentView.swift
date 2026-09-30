import SwiftUI

struct DeliveryReportView: View {
    @State private var model = ReportModel()
    @State private var showReport = false

    var body: some View {
        Form {
            Section("项目信息") {
                TextField("客户名称", text: $model.customer)
                TextField("项目名称", text: $model.project)
                Stepper("设备：\(Int(model.devices)) 台", value: $model.devices, in: 1...200)
                Picker("验收结论", selection: $model.result) {
                    Text("验收通过").tag("验收通过")
                    Text("有条件通过").tag("有条件通过")
                    Text("整改后复验").tag("整改后复验")
                }
            }
            Section("备注") {
                TextField("补充说明", text: $model.note)
            }
            Section {
                Button("生成报告") { showReport = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("交付报告")
        .sheet(isPresented: $showReport) {
            ScrollView {
                Text(model.text()).padding()
            }
        }
    }
}
