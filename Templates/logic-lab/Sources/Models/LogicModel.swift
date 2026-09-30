struct LogicModel {
    var a = true
    var b = false
    var gate = "AND"

    var output: Bool {
        eval(a, b)
    }

    func eval(_ x: Bool, _ y: Bool) -> Bool {
        if gate == "AND" { return x && y }
        if gate == "OR" { return x || y }
        if gate == "XOR" { return x != y }
        return !(x && y)
    }

    func truthLines() -> [String] {
        var lines: [String] = []
        let values = [(true, true), (true, false), (false, true), (false, false)]
        for v in values {
            lines.append("\(v.0 ? "真" : "假") · \(v.1 ? "真" : "假") → \(eval(v.0, v.1) ? "亮" : "灭")")
        }
        return lines
    }
}
