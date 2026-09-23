// Double 运算与打印格式（与 Swift description 一致）
let d = 7.0 / 2.0
print(d, 1.0 / 3.0, 0.1 + 0.2, 2.5 * 4)
print(100000.0, 1e16, 0.00001, -0.0, 3.0)
let r = 10.0
print(r * r * 3.14159)
print(Double(7) / 2, Double(1) / 8)
print((2.0).squareRoot(), (9.0).squareRoot())
print(7.5.truncatingRemainder(dividingBy: 2), 2.5.rounded(), (-2.5).rounded())
var total = 0.0
for i in 1...4 {
    total += Double(i) * 0.5
}
print("total", total)
print(Int(3.99), Int(-3.99), Double(Int(2.5)))
let big = 1.0 / 0.0
print(big, -big)
print(min(1.5, 0.5), max(2.0, 3.0))
let half: Double = 1 / 2
print(half)
var ratio: Double = 3
ratio = ratio / 4
print(ratio, ratio * 2 + 1)
