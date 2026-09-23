// 闭包语法：尾随闭包、$0 简写、显式参数与返回类型、闭包作为参数
let numbers = [5, 2, 8, 1, 9]
let doubled = numbers.map { $0 * 2 }
let sortedDesc = numbers.sorted { $0 > $1 }
let sortedExplicit = numbers.sorted(by: { (a: Int, b: Int) -> Bool in a < b })
print(doubled, sortedDesc, sortedExplicit)
let total = numbers.reduce(0) { acc, n in acc + n }
print(total)
func repeatAction(_ times: Int, action: () -> Void) {
    for _ in 0..<times { action() }
}
var ticks = 0
repeatAction(3) {
    ticks += 1
}
print("ticks", ticks)
func transform(_ v: Int, using f: (Int) -> Int) -> Int { f(v) }
print(transform(6) { $0 * $0 }, transform(6, using: { x in x + 1 }))
let describe: (Int, String) -> String = { n, word in
    "\(n) \(word)"
}
print(describe(3, "apples"))
let strings = numbers.map { "#\($0)" }
print(strings)
print(numbers.sorted(by: >), numbers.reduce(1, *))
let compose = { (f: @escaping (Int) -> Int, g: @escaping (Int) -> Int) -> (Int) -> Int in
    { x in g(f(x)) }
}
let inc = { (x: Int) in x + 1 }
let dbl = { (x: Int) in x * 2 }
print(compose(inc, dbl)(5))
