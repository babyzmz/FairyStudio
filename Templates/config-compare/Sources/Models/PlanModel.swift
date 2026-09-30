struct Plan {
    var name: String
    var units: Int
    var monitoring: Bool
    var reporting: Bool

    var unitPrice: Int {
        800 + (monitoring ? 300 : 0) + (reporting ? 200 : 0)
    }

    var total: Int {
        hardware() + install()
    }

    func hardware() -> Int {
        units * unitPrice
    }

    func install() -> Int {
        units * 120
    }

    func summary() -> [String] {
        var lines: [String] = []
        lines.append("\(name)：\(units) 台 × \(unitPrice) 元")
        lines.append("硬件 \(hardware()) 元 / 安装 \(install()) 元")
        lines.append("功能：基础\(monitoring ? " + 监测" : "")\(reporting ? " + 报表" : "")")
        lines.append("合计 \(total) 元")
        return lines
    }
}

struct PlanCompareModel {
    var units: Int = 6
    var monitoring = true
    var reporting = false
    var savedPlans: [Plan] = []

    var current: Plan {
        Plan(name: "当前", units: units, monitoring: monitoring, reporting: reporting)
    }

    mutating func saveA() {
        savedPlans.append(Plan(name: "方案 A", units: units, monitoring: monitoring, reporting: reporting))
    }

    mutating func saveB() {
        savedPlans.append(Plan(name: "方案 B", units: units, monitoring: monitoring, reporting: reporting))
    }

    var diffText: String {
        var totalA = 0
        var totalB = 0
        for p in savedPlans {
            if p.name == "方案 A" { totalA = p.total }
            if p.name == "方案 B" { totalB = p.total }
        }
        if savedPlans.count < 2 { return "先保存两个方案再对比" }
        return "方案差额：\(totalB - totalA) 元"
    }

    var savedLines: [String] {
        var lines: [String] = []
        for p in savedPlans {
            lines.append("— \(p.name) —")
            for l in p.summary() { lines.append(l) }
        }
        return lines
    }
}
