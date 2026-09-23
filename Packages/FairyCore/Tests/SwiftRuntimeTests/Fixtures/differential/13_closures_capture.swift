// 闭包捕获：var 按引用、let 按值、计数器工厂、循环中的新绑定
func makeCounter(start: Int) -> () -> Int {
    var count = start
    return {
        count += 1
        return count
    }
}
let c1 = makeCounter(start: 0)
let c2 = makeCounter(start: 10)
print(c1(), c1(), c2(), c1(), c2())

var shared = 0
let add = { (n: Int) in shared += n }
add(3)
add(4)
print("shared", shared)

var value = 1
let snapshot = value
let readLater = { snapshot * 100 }
value = 2
print(readLater(), value)

var closures: [() -> Int] = []
for i in 0..<3 {
    closures.append { i * i }
}
print(closures.map { $0() })

func makeAccumulator() -> (Int) -> Int {
    var total = 0
    func add(_ x: Int) -> Int {
        total += x
        return total
    }
    return add
}
let acc = makeAccumulator()
print(acc(5), acc(10), acc(-3))

var log: [String] = []
let record = { (s: String) in log.append(s) }
record("a")
record("b")
print(log)
