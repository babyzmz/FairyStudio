// 自定义 init、static 属性与方法、extension、Equatable
struct Temperature: Equatable {
    static let freezing = Temperature(celsius: 0)
    static var created = 0

    var celsius: Double

    init(celsius: Double) {
        self.celsius = celsius
        Temperature.created += 1
    }

    init(fahrenheit: Double) {
        celsius = (fahrenheit - 32) * 5 / 9
        Temperature.created += 1
    }

    static func average(_ a: Temperature, _ b: Temperature) -> Temperature {
        Temperature(celsius: (a.celsius + b.celsius) / 2)
    }
}

extension Temperature {
    var fahrenheit: Double { celsius * 9 / 5 + 32 }

    func describe() -> String {
        "\(celsius)°C = \(fahrenheit)°F"
    }
}

let boiling = Temperature(celsius: 100)
let body = Temperature(fahrenheit: 98.6)
print(boiling.describe())
print(body.celsius > 36.9, body.celsius < 37.1)
print(Temperature.average(boiling, Temperature.freezing).celsius)
print(Temperature.created)
print(boiling == Temperature(celsius: 100), boiling == Temperature.freezing)

struct Counter {
    private(set) var value = 0
    mutating func tick() { value += 1 }
}
var counter = Counter()
counter.tick()
counter.tick()
print(counter.value)
