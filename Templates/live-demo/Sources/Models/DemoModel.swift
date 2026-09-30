struct DemoModel {
    var attendees: Double = 40
    var rooms: Double = 3
    var showNotes = false

    var headcount: Int { Int(attendees) }
    var roomCount: Int { Int(rooms) }
    var perRoom: Int { headcount / max(1, roomCount) }
    var load: Double { Double(perRoom) / 20.0 }

    var verdict: String {
        if load > 1.0 { return "超载：建议增加教室" }
        if load > 0.75 { return "偏满：可接受但拥挤" }
        return "舒适"
    }
}
