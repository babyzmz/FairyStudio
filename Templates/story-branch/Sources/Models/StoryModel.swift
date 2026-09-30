// 场景 = 文本 + 选项[(标签, 下一场景, 勇气变化)]；下一场景 -1 表示进入结局。
struct StoryScene {
    var text: String
    var choices: [(String, Int, Int)]
}

struct StoryModel {
    var scenes: [StoryScene] = [
        StoryScene(text: "深夜的机房，主灯熄灭。你听到配电柜后面有嗡嗡声。",
              choices: [("先断电再检查", 1, 2), ("直接伸手摸", 2, -3)]),
        StoryScene(text: "电闸拉下。你用手机照明，发现是一颗松动的端子。",
              choices: [("拧紧并记录", 3, 2), ("拍照留给白班", 3, 1)]),
        StoryScene(text: "你被静电狠狠麻了一下，退后两步。",
              choices: [("冷静重新断电", 1, 1)]),
        StoryScene(text: "问题解决。窗外天快亮了。",
              choices: [("结束", -1, 0)]),
    ]
    var current = 0
    var courage = 0
    var endingIndex = -1

    var finished: Bool { endingIndex != -1 }

    var currentText: String {
        scenes[current].text
    }

    func choiceLabel(_ i: Int) -> String {
        scenes[current].choices[i].0
    }

    var choiceCount: Int {
        scenes[current].choices.count
    }

    var choiceIndices: [Int] {
        Array(0..<choiceCount)
    }

    mutating func choose(_ i: Int) {
        let next = scenes[current].choices[i].1
        courage += scenes[current].choices[i].2
        if next == -1 {
            endingIndex = courage >= 3 ? 0 : (courage >= 0 ? 1 : 2)
        } else {
            current = next
        }
    }

    func endingText() -> String {
        if endingIndex == 0 { return "结局：专业可靠的你被点名负责下一期机房改造。（勇气 \(courage)）" }
        if endingIndex == 1 { return "结局：这次靠运气过关，你把过程写进了复盘报告。（勇气 \(courage)）" }
        return "结局：你决定先把电工证考下来。（勇气 \(courage)）"
    }
}
