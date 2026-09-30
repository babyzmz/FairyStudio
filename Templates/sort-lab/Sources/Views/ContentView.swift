import SwiftUI

struct SortLabView: View {
    @State private var model = SortModel()

    var body: some View {
        VStack(spacing: 14) {
            Text("排序实验").font(.title)
            ForEach(model.values.indices, id: \.self) { k in
                HStack {
                    Text("\(model.values[k])")
                    ProgressView(value: Double(model.values[k]), total: 8)
                }
            }
            Text("比较 \(model.comparisons) 次 · 交换 \(model.swaps) 次")
                .font(.callout)
            HStack {
                Button("单步") { model.step() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.done)
                Button("重置") { model.reset() }
                    .buttonStyle(.bordered)
            }
            if model.done {
                Text("排序完成！").font(.headline)
            }
        }
        .padding()
    }
}
