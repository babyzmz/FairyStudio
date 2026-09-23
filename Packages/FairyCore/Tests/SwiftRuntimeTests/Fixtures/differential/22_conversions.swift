// 类型转换：Int(String)、String(Int)、Double(Int)、Int(Double)、abs/min/max
print(Int("123") ?? 0, Int("12a") ?? -1, Int("-7") ?? 0)
print(Double("2.5") ?? 0, Double("x") ?? -1)
print(String(99), String(2.25), String(true))
let i = 7
let d = 2.0
print(Double(i) * d, i * Int(d), Int(Double(i) / d))
print(abs(-3), abs(-2.5), min(2, 8), max(-1.5, -2.5))
let parsed = ["4", "five", "6"].map { Int($0) }
print(parsed)
let sum = ["1", "2", "x"].compactMap { Int($0) }.reduce(0, +)
print(sum)
print("\(3)" + "\(4.0)")
print(Int(Double(Int.max) / 2) > 0)
