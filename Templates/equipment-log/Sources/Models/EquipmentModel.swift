struct LoanRecord {
    var id: Int
    var item: String
    var person: String
    var activity: String
    var out: Bool
}

struct EquipmentModel {
    var records: [LoanRecord] = [
        LoanRecord(id: 1, item: "无线麦 1 号", person: "张三", activity: "年会", out: true),
        LoanRecord(id: 2, item: "投影仪 B", person: "李四", activity: "例会", out: false),
    ]
    var nextID = 3

    mutating func add(item: String, person: String, activity: String) {
        records.append(LoanRecord(id: nextID, item: item, person: person, activity: activity, out: true))
        nextID += 1
    }

    mutating func toggle(_ id: Int) {
        for i in records.indices where records[i].id == id {
            records[i].out.toggle()
        }
    }

    func filtered(_ filter: String, activity: String) -> [LoanRecord] {
        var rows = records
        if filter == "借出中" { rows = rows.filter { $0.out } }
        if filter == "已归还" { rows = rows.filter { !$0.out } }
        if activity != "全部活动" { rows = rows.filter { $0.activity == activity } }
        return rows
    }

    func activities() -> [String] {
        var list = ["全部活动"]
        for r in records where !list.contains(r.activity) {
            list.append(r.activity)
        }
        return list
    }
}
