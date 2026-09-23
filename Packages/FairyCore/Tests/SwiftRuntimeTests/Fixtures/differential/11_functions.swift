// 函数：参数标签、默认值、返回值、重载、嵌套函数、元组返回
func greet(_ name: String, from place: String = "Earth", times: Int = 1) -> String {
    var out = ""
    for _ in 0..<times {
        out += "Hi \(name) from \(place). "
    }
    return out
}
print(greet("Ann"))
print(greet("Bo", from: "Mars"))
print(greet("Cy", times: 2))
func area(width w: Double, height h: Double) -> Double {
    w * h
}
print(area(width: 3, height: 4.5))
func describe(_ x: Int) -> String { "Int \(x)" }
func describe(_ x: String) -> String { "String \(x)" }
print(describe(3), describe("s"))
func outer() -> Int {
    func helper(_ v: Int) -> Int { v * 10 }
    return helper(4) + helper(1)
}
print(outer())
func minMax(_ values: [Int]) -> (min: Int, max: Int) {
    var lo = values[0]
    var hi = values[0]
    for v in values {
        if v < lo { lo = v }
        if v > hi { hi = v }
    }
    return (lo, hi)
}
let mm = minMax([5, 3, 9, 1])
print(mm.min, mm.max)
func noReturn() {
    print("side effect")
}
noReturn()
func apply(_ f: (Int) -> Int, to v: Int) -> Int { f(v) }
func square(_ x: Int) -> Int { x * x }
print(apply(square, to: 7), [1, 2, 3].map(square))
