import SwiftUI

struct ContentView: View {
    @State private var model = CounterModel()

    var body: some View {
        VStack(spacing: 16) {
            Text(model.label)
                .font(.title)
            HStack {
                Button("Increment") {
                    model.increment()
                }
                .buttonStyle(.borderedProminent)
                Button("Reset") {
                    model.reset()
                }
                .disabled(model.count == 0)
            }
        }
        .padding()
    }
}
