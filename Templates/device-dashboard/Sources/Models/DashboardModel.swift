// 只读数据面板样例：读数用确定性公式模拟（真实接入属宿主能力）。
struct DashboardModel {
    func readings() -> [Double] {
        var list: [Double] = []
        for i in 0..<12 {
            let v = 36.0 + 8.0 * sin(Double(i) / 2.0)
            list.append((v * 10).rounded() / 10)
        }
        return list
    }

    var latest: Double {
        readings().last ?? 0
    }

    var peak: Double {
        var m = 0.0
        for v in readings() where v > m { m = v }
        return m
    }
}
