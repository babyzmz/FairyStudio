struct WorkEntry {
    var client: String
    var minutes: Int
}

struct WorktimeModel {
    var entries: [WorkEntry] = [
        WorkEntry(client: "客户甲", minutes: 90),
        WorkEntry(client: "客户乙", minutes: 45),
    ]

    var clients: [String] {
        var list: [String] = []
        for e in entries where !list.contains(e.client) {
            list.append(e.client)
        }
        return list
    }

    mutating func add(client: String, minutes: Int) {
        entries.append(WorkEntry(client: client, minutes: minutes))
    }

    func total(for client: String) -> Int {
        var sum = 0
        for e in entries where e.client == client {
            sum += e.minutes
        }
        return sum
    }

    func hours(_ minutes: Int) -> String {
        String(format: "%.1f 小时", Double(minutes) / 60.0)
    }
}
