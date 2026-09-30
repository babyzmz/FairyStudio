// 排序步进机：每步只做一次相邻比较（必要时交换），确定性可回放。
struct SortModel {
    var values: [Int] = [5, 1, 4, 2, 8, 3]
    var position = 0
    var comparisons = 0
    var swaps = 0
    var done = false

    var isSorted: Bool {
        var sorted = true
        for k in 1..<values.count where values[k - 1] > values[k] { sorted = false }
        return sorted
    }

    mutating func reset() {
        values = [5, 1, 4, 2, 8, 3]
        position = 0
        comparisons = 0
        swaps = 0
        done = false
    }

    mutating func step() {
        if isSorted || position + 1 >= values.count {
            done = true
            return
        }
        comparisons += 1
        if values[position] > values[position + 1] {
            values.swapAt(position, position + 1)
            swaps += 1
        }
        position += 1
        if position >= values.count - 1 {
            position = 0
        }
    }
}
