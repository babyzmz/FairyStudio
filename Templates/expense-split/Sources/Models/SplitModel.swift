struct SplitMember {
    var name: String
    var minutes: Int
}

struct SplitModel {
    var members: [SplitMember] = [
        SplitMember(name: "阿兔", minutes: 90),
        SplitMember(name: "小鹿", minutes: 60),
        SplitMember(name: "阿獭", minutes: 30),
    ]
    var total = 360

    var totalMinutes: Int {
        var sum = 0
        for m in members { sum += m.minutes }
        return max(1, sum)
    }

    mutating func addMember(_ name: String) {
        members.append(SplitMember(name: name, minutes: 30))
    }

    mutating func moreMinutes(_ i: Int) {
        members[i].minutes += 15
    }

    mutating func lessMinutes(_ i: Int) {
        if members[i].minutes >= 15 {
            members[i].minutes -= 15
        }
    }

    mutating func moreTotal() {
        total += 10
    }

    mutating func lessTotal() {
        if total >= 10 {
            total -= 10
        }
    }

    func share(_ i: Int) -> Int {
        Int(Double(total) * Double(members[i].minutes) / Double(totalMinutes) + 0.5)
    }
}
