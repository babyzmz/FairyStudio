import SwiftUI

struct QuizView: View {
    @State private var model = QuizModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.finished {
                    Text(model.grade()).font(.headline)
                    Button("再来一局") { model = QuizModel() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("第 \(model.index + 1)/\(model.questions.count) 题").font(.caption)
                    Text(model.currentPrompt).font(.callout)
                    ForEach(model.optionIndices.indices, id: \.self) { i in
                        Button(model.option(i)) { model.pick(i) }
                            .buttonStyle(.bordered)
                    }
                    if model.answered {
                        Text(model.lastCorrect ? "答对了！" : "不对哦。").font(.headline)
                        Text(model.explainText).font(.caption)
                        Button("下一题") { model.next() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("得分 \(model.score)").font(.caption)
                }
            }
            .padding()
        }
    }
}
