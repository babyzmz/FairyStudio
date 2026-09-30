struct SurveyRow {
    var device: String
    var location: String
    var status: String
}

struct SurveyModel {
    var rows: [SurveyRow] = [
        SurveyRow(device: "AP-001", location: "三层走廊", status: "正常"),
    ]

    var okCount: Int {
        var n = 0
        for r in rows where r.status == "正常" { n += 1 }
        return n
    }

    mutating func add(device: String, location: String) {
        rows.append(SurveyRow(device: device, location: location, status: "正常"))
    }

    mutating func toggleStatus(_ i: Int) {
        rows[i].status = rows[i].status == "正常" ? "待整改" : "正常"
    }
}
