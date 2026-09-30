import SwiftUI

struct MathLabView: View {
    @State private var model = QuadModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("y = a·x² + b·x + c").font(.title)
                VStack(alignment: .leading) {
                    Text("a = \(String(format: "%.1f", model.a))")
                    Slider(value: $model.a, in: -3...3, step: 0.1)
                }
                VStack(alignment: .leading) {
                    Text("b = \(String(format: "%.1f", model.b))")
                    Slider(value: $model.b, in: -6...6, step: 0.1)
                }
                VStack(alignment: .leading) {
                    Text("c = \(String(format: "%.1f", model.c))")
                    Slider(value: $model.c, in: -8...8, step: 0.1)
                }
                Divider()
                Text("判别式：\(String(format: "%.2f", model.discriminant))").font(.headline)
                if model.hasRoots {
                    Text("x₁ = \(String(format: "%.2f", model.root(-1)))")
                    Text("x₂ = \(String(format: "%.2f", model.root(1)))")
                } else {
                    Text("无实数根（或 a = 0）").font(.callout)
                }
                Divider()
                ForEach(model.rows().indices, id: \.self) { i in
                    Text(model.rows()[i]).font(.callout)
                }
            }
            .padding()
        }
    }
}
