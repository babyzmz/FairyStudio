struct BudgetModel {
    var people = 4
    var dayRate = 1200
    var weeks = 6
    var marginPercent = 20

    func cost(p: Int) -> Int {
        p * dayRate * 5 * weeks
    }

    func quoted(p: Int) -> Int {
        cost(p: p) * (100 + marginPercent) / 100
    }
}
