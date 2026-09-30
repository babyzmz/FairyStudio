import SwiftUI

struct StoryView: View {
    @State private var model = StoryModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.finished {
                    Text(model.endingText()).font(.headline)
                    Button("重新开始") { model = StoryModel() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(model.currentText).font(.callout)
                    ForEach(model.choiceIndices.indices, id: \.self) { i in
                        Button(model.choiceLabel(i)) {
                            model.choose(i)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("勇气 \(model.courage)").font(.caption)
                }
            }
            .padding()
        }
    }
}
