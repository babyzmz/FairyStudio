struct TriageItem {
    var name: String
    var action: String
}

struct TriageModel {
    var items: [TriageItem] = [
        TriageItem(name: "合同扫描件", action: "保留"),
        TriageItem(name: "旧版报价单", action: "归档"),
        TriageItem(name: "重复截图", action: "放弃"),
        TriageItem(name: "会议录音", action: "归档"),
    ]
    var applied = false

    mutating func cycle(_ i: Int) {
        if items[i].action == "保留" {
            items[i].action = "归档"
        } else if items[i].action == "归档" {
            items[i].action = "放弃"
        } else {
            items[i].action = "保留"
        }
    }

    mutating func apply() {
        applied = true
    }

    func count(_ action: String) -> Int {
        var n = 0
        for i in items where i.action == action { n += 1 }
        return n
    }
}
