struct QuadModel {
    var a: Double = 1
    var b: Double = 0
    var c: Double = -4

    var discriminant: Double {
        b * b - 4 * a * c
    }

    var hasRoots: Bool {
        discriminant >= 0 && a != 0
    }

    func root(_ sign: Double) -> Double {
        (-b + sign * discriminant.squareRoot()) / (2 * a)
    }

    func value(_ x: Double) -> Double {
        a * x * x + b * x + c
    }

    func rows() -> [String] {
        var lines: [String] = []
        for x in -3...3 {
            lines.append("x = \(x) → y = \(String(format: "%.2f", value(Double(x))))")
        }
        return lines
    }
}
