// 参数可调的计算演示：单价 × 数量 + 税率，全部用 Button 步进（解释器暂不支持 Slider/Stepper）。
struct CalcModel {
    var price: Int = 100
    var count: Int = 1
    var taxPercent: Int = 5

    var subtotal: Int {
        price * count
    }

    var total: Int {
        subtotal * (100 + taxPercent) / 100
    }

    var label: String {
        "Total: \(total)"
    }

    mutating func morePrice() {
        price += 10
    }

    mutating func lessPrice() {
        if price >= 10 {
            price -= 10
        }
    }

    mutating func moreCount() {
        count += 1
    }

    mutating func lessCount() {
        if count > 1 {
            count -= 1
        }
    }

    mutating func moreTax() {
        taxPercent += 1
    }

    mutating func lessTax() {
        if taxPercent > 0 {
            taxPercent -= 1
        }
    }
}
