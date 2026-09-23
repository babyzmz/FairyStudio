// 元组值、三元、嵌套条件、全局函数访问全局变量、CustomStringConvertible
var visits = 0
func visit() -> Int {
    visits += 1
    return visits
}
_ = visit()
_ = visit()
print("visits", visit())
let pair = (name: "x", score: 3)
print(pair.name, pair.score, pair.0)
let t = (1, 2)
print(t.0 + t.1)
let score = 72
let label = score >= 90 ? "great" : score >= 60 ? "pass" : "fail"
print(label)
struct Money: CustomStringConvertible {
    var cents: Int
    var description: String {
        "$\(cents / 100).\(cents % 100 < 10 ? "0" : "")\(cents % 100)"
    }
}
let price = Money(cents: 1234)
print(price)
print("price is \(price)")
print([Money(cents: 5), Money(cents: 250)])
let big = 1_000_000
print(big, 0x1F, 0b1010)
