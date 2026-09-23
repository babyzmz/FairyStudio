// 高阶函数：map / filter / reduce / sorted / contains(where:) / first(where:) / compactMap / enumerated
struct Item {
    var name: String
    var price: Double
    var qty: Int
}
let cart = [
    Item(name: "pen", price: 1.5, qty: 4),
    Item(name: "book", price: 12.0, qty: 1),
    Item(name: "bag", price: 30.0, qty: 1),
]
let names = cart.map { $0.name }
let expensive = cart.filter { $0.price > 10 }.map { $0.name }
let total = cart.reduce(0.0) { $0 + $1.price * Double($1.qty) }
print(names, expensive, total)
let byPrice = cart.sorted { $0.price > $1.price }.map { $0.name }
print(byPrice)
print(cart.contains { $0.qty > 3 }, cart.contains(where: { $0.name == "cup" }))
if let first = cart.first(where: { $0.price < 5 }) {
    print("cheap:", first.name)
}
let parsed = ["1", "x", "3"].compactMap { Int($0) }
print(parsed)
for (index, item) in cart.enumerated() {
    print(index, item.name)
}
let squares = (1...5).map { $0 * $0 }
print(squares, squares.filter { $0 % 2 == 1 }, squares.reduce(0, +))
cart.forEach { print("-", $0.name) }
print([3, 1, 2].sorted(), ["b", "a"].sorted())
print(squares.allSatisfy { $0 > 0 }, squares.firstIndex(where: { $0 > 5 }) ?? -1)
