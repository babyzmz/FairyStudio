struct ChordPracticeModel {
    var sequenceNames: [String] = ["C 大调基础", "Am 小调进行", "卡农进行"]
    var orders: [String: [String]] = [
        "C 大调基础": ["C", "G", "Am", "F"],
        "Am 小调进行": ["Am", "F", "C", "G"],
        "卡农进行": ["C", "G", "Am", "Em", "F", "C", "F", "G"],
    ]
    var sequenceName = "C 大调基础"
    var position = 0
    var rounds = 0
    var tempo: Double = 60
    var hard: [String: Bool] = ["F": true]

    var order: [String] {
        orders[sequenceName] ?? []
    }

    var current: String {
        if position >= order.count { return "完成！" }
        return order[position]
    }

    var isHard: Bool {
        hard[current] == true
    }

    mutating func toggleHard() {
        hard[current] = !(hard[current] ?? false)
    }

    mutating func next() {
        if position + 1 >= order.count {
            position = 0
            rounds += 1
        } else {
            position += 1
        }
    }
}
