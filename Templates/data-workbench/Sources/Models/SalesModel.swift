struct SaleRecord {
    var region: String
    var month: String
    var amount: Int
    var done: Bool
}

struct SalesModel {
    var records: [SaleRecord] = [
        SaleRecord(region: "华东", month: "1月", amount: 12000, done: true),
        SaleRecord(region: "华东", month: "2月", amount: 8000, done: true),
        SaleRecord(region: "华北", month: "1月", amount: 15000, done: true),
        SaleRecord(region: "华北", month: "2月", amount: 6000, done: false),
        SaleRecord(region: "华南", month: "1月", amount: 9000, done: true),
        SaleRecord(region: "华南", month: "2月", amount: 11000, done: false),
    ]

    func regions() -> [String] {
        var list = ["全部"]
        for r in records where !list.contains(r.region) {
            list.append(r.region)
        }
        return list
    }

    func filtered(region: String, includeUndone: Bool, byAmount: Bool) -> [SaleRecord] {
        var rows = records
        if region != "全部" { rows = rows.filter { $0.region == region } }
        if !includeUndone { rows = rows.filter { $0.done } }
        if byAmount {
            rows = rows.sorted { $0.amount > $1.amount }
        } else {
            rows = rows.sorted { $0.month < $1.month }
        }
        return rows
    }

    func totals(for rows: [SaleRecord]) -> [String] {
        var order: [String] = []
        var sums: [String: Int] = [:]
        for r in rows {
            if sums[r.region] == nil { order.append(r.region) }
            sums[r.region] = (sums[r.region] ?? 0) + r.amount
        }
        var lines: [String] = []
        for name in order {
            lines.append("\(name)：\(sums[name] ?? 0) 元")
        }
        return lines
    }
}
