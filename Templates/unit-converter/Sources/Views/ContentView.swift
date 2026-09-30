import SwiftUI

struct UnitConverterView: View {
    @State private var model = ConverterModel()

    var body: some View {
        VStack(spacing: 14) {
            Picker("类别", selection: $model.kind) {
                Text("长度").tag("长度")
                Text("重量").tag("重量")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                Text("数值：\(Int(model.value))")
                Slider(value: $model.value, in: 1...1000, step: 1)
            }
            ForEach(model.names().indices, id: \.self) { i in
                HStack {
                    Text(model.names()[i])
                    Spacer()
                    Text(String(format: "%.3f", model.converted(model.names()[i]))).font(.callout)
                }
            }
        }
        .padding()
    }
}
