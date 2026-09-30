struct CheckItem {
    var id: Int
    var title: String
    var result: String
    var reason: String
}

struct ChecklistModel {
    var items: [CheckItem] = [
        CheckItem(id: 1, title: "设备固定与水平", result: "待定", reason: ""),
        CheckItem(id: 2, title: "线缆标签完整", result: "待定", reason: ""),
        CheckItem(id: 3, title: "通电自检通过", result: "待定", reason: ""),
    ]

    var passed: Int {
        var n = 0
        for i in items where i.result == "通过" { n += 1 }
        return n
    }

    var failed: Int {
        var n = 0
        for i in items where i.result == "不通过" { n += 1 }
        return n
    }

    mutating func setResult(_ id: Int, _ result: String) {
        for i in items.indices where items[i].id == id {
            items[i].result = result
        }
    }

    mutating func setReason(_ id: Int, _ reason: String) {
        for i in items.indices where items[i].id == id {
            items[i].reason = reason
        }
    }

    func itemTitle(_ id: Int) -> String {
        for i in items where i.id == id { return i.title }
        return ""
    }

    func report() -> String {
        var lines: [String] = []
        lines.append("验收小结：通过 \(passed)，不通过 \(failed)，共 \(items.count) 项")
        for i in items {
            var line = "\(i.title)：\(i.result)"
            if i.result == "不通过" && i.reason != "" {
                line += "（原因：\(i.reason)）"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
