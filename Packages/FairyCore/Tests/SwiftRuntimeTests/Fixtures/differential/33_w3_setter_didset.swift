// W3：带 setter 的计算属性 + didSet（存储属性/全局，赋值后触发一次）
struct Temp {
    var celsius: Double {
        get { (fahrenheit - 32) * 5 / 9 }
        set { fahrenheit = newValue * 9 / 5 + 32 }
    }
    var fahrenheit: Double
}
var t = Temp(fahrenheit: 32)
print(t.celsius)
t.celsius = 100
print(t.fahrenheit)
t.celsius += 10
print(t.fahrenheit)
struct Counter {
    var count = 0 {
        didSet { print("didSet \(oldValue)->\(count)") }
    }
    init() {}
}
var c = Counter()
c.count = 1
c.count += 1
print(c.count)
struct Clamp {
    var v = 0 {
        didSet {
            if v > 10 { v = 10 }
            print("clamped \(v)")
        }
    }
}
var cl = Clamp()
cl.v = 5
cl.v = 99
print(cl.v)
struct M {
    var items: [Int] = [] {
        didSet { print("items now \(items)") }
    }
    var n: Int = 0
    init(start: Int) {
        n = start
        items = [start]
    }
}
var m = M(start: 5)
m.items.append(6)
m.n = 7
print(m.items, m.n)
var g = 0 {
    didSet { print("g \(oldValue)->\(g)") }
}
g = 5
print(g)
