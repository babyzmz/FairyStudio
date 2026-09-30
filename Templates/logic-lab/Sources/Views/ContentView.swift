import SwiftUI

struct LogicLabView: View {
    @State private var model = LogicModel()

    var body: some View {
        VStack(spacing: 14) {
            Text("逻辑门实验").font(.title)
            Toggle("输入 A", isOn: $model.a)
            Toggle("输入 B", isOn: $model.b)
            Picker("门", selection: $model.gate) {
                Text("AND").tag("AND")
                Text("OR").tag("OR")
                Text("XOR").tag("XOR")
                Text("NAND").tag("NAND")
            }
            .pickerStyle(.segmented)
            Divider()
            HStack {
                Image(systemName: model.output ? "lightbulb.fill" : "lightbulb")
                Text("输出：\(model.output ? "亮" : "灭")").font(.headline)
            }
            Divider()
            Text("真值表（\(model.gate)）").font(.callout)
            ForEach(model.truthLines().indices, id: \.self) { i in
                Text(model.truthLines()[i]).font(.caption)
            }
        }
        .padding()
    }
}
