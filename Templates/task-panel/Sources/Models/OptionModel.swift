struct PlanOption {
    var id: Int
    var title: String
    var selected: Bool
    var priority: Int
}

struct OptionModel {
    var options: [PlanOption] = [
        PlanOption(id: 1, title: "先做数据接口", selected: true, priority: 3),
        PlanOption(id: 2, title: "先做演示页面", selected: true, priority: 2),
        PlanOption(id: 3, title: "补自动化测试", selected: false, priority: 1),
    ]

    mutating func toggle(_ id: Int) {
        for i in options.indices where options[i].id == id {
            options[i].selected.toggle()
        }
    }

    mutating func morePriority(_ id: Int) {
        for i in options.indices where options[i].id == id {
            if options[i].priority < 5 { options[i].priority += 1 }
        }
    }

    mutating func lessPriority(_ id: Int) {
        for i in options.indices where options[i].id == id {
            if options[i].priority > 1 { options[i].priority -= 1 }
        }
    }

    var chosen: [PlanOption] {
        options.filter { $0.selected }.sorted { $0.priority > $1.priority }
    }

    func planLines() -> [String] {
        var lines: [String] = []
        let picked = chosen
        lines.append("执行计划（\(picked.count) 项）")
        for (i, o) in picked.enumerated() {
            lines.append("\(i + 1). \(o.title)（优先级 \(o.priority)）")
        }
        return lines
    }
}
