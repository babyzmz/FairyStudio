struct QuizQuestion {
    var prompt: String
    var options: [String]
    var answer: Int
    var explain: String
}

struct QuizModel {
    var questions: [QuizQuestion] = [
        QuizQuestion(prompt: "网线 568B 的线序里，第 1 根是什么颜色？",
                     options: ["白橙", "白绿", "蓝"], answer: 0,
                     explain: "568B：白橙、橙、白绿、蓝、白蓝、绿、白棕、棕。"),
        QuizQuestion(prompt: "POE 供电标准里，802.3at 提供的功率约为？",
                     options: ["15W", "30W", "60W"], answer: 1,
                     explain: "802.3af 约 15W，at（PoE+）约 30W，bt 可到 60W 以上。"),
        QuizQuestion(prompt: "机房冷热通道隔离的主要目的是？",
                     options: ["美观", "提高制冷效率", "防尘"], answer: 1,
                     explain: "冷热隔离减少冷风混合，显著提高制冷效率。"),
    ]
    var index = 0
    var score = 0
    var picked = -1
    var finished = false

    var currentPrompt: String { questions[index].prompt }

    func option(_ i: Int) -> String { questions[index].options[i] }
    var optionCount: Int { questions[index].options.count }
    var optionIndices: [Int] { Array(0..<optionCount) }

    var answered: Bool { picked != -1 }
    var lastCorrect: Bool { picked == questions[index].answer }
    var explainText: String { questions[index].explain }

    mutating func pick(_ i: Int) {
        if answered { return }
        picked = i
        if i == questions[index].answer { score += 1 }
    }

    mutating func next() {
        if index + 1 >= questions.count {
            finished = true
        } else {
            index += 1
            picked = -1
        }
    }

    func grade() -> String {
        if score == questions.count { return "满分！行家。\(score)/\(questions.count)" }
        if score >= 1 { return "不错，\(score)/\(questions.count)" }
        return "再练一次：\(score)/\(questions.count)"
    }
}
