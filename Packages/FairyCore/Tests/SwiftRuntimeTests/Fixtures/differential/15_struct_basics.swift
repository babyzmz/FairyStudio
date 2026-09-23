// struct：存储/计算属性、逐一成员构造、默认值、实例方法、mutating、打印
struct Rect {
    var width: Double
    var height: Double = 1
    var area: Double { width * height }
    var isSquare: Bool { width == height }

    func scaled(by f: Double) -> Rect {
        Rect(width: width * f, height: height * f)
    }

    mutating func grow(by d: Double) {
        width += d
        height += d
    }
}
var r = Rect(width: 3, height: 4)
print(r.area, r.isSquare)
let r2 = r.scaled(by: 2)
print(r2)
r.grow(by: 1)
print(r, r.area)
let line = Rect(width: 5)
print(line.height, line)

struct Person {
    let name: String
    var age: Int
    var tags: [String] = []

    func greeting() -> String {
        "I am \(name), \(age)"
    }

    mutating func birthday() {
        age += 1
        tags.append("bday\(age)")
    }
}
var p = Person(name: "Lin", age: 29)
p.birthday()
p.birthday()
print(p.greeting(), p.tags)
print(p)
