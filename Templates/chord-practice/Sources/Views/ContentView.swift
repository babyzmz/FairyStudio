import SwiftUI

struct ChordPracticeView: View {
    @State private var model = ChordPracticeModel()

    var body: some View {
        VStack(spacing: 16) {
            Picker("序列", selection: $model.sequenceName) {
                ForEach(model.sequenceNames.indices, id: \.self) { i in
                    Text(model.sequenceNames[i]).tag(model.sequenceNames[i])
                }
            }
            VStack(alignment: .leading) {
                Text("速度：\(Int(model.tempo)) BPM（视觉节拍，不含音频）")
                Slider(value: $model.tempo, in: 40...180, step: 5)
            }
            Text(model.current)
                .font(.largeTitle)
                .bold()
            if model.isHard {
                Text("难点和弦，慢速练").font(.caption)
            }
            Button(model.isHard ? "取消难点标记" : "标记为难点") {
                model.toggleHard()
            }
            .buttonStyle(.bordered)
            HStack {
                Button("下一个和弦") { model.next() }
                    .buttonStyle(.borderedProminent)
                Text("完成 \(model.rounds) 轮").font(.callout)
            }
        }
        .padding()
    }
}
