import Foundation

let word = "Swift rocks"
print(word.count, word.isEmpty)
print(word.first ?? "-", word.last ?? "-")
print(word.description)
print(word.dropFirst(2), "|", word.dropLast(3))
print(String(word.prefix(5)), String(word.suffix(5)))
print(word.filter { $0 != "o" })
print(word.map { $0.uppercased() }.joined())
print(word.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: ","))
print(String(word.sorted()))
print(word.components(separatedBy: " "))
var title = "abc"
title.removeLast()
print(title)
var blank = "xy"
blank.removeAll()
print(blank.isEmpty)

let nums = [3, 1, 2]
print(nums.lastIndex(of: 1) ?? -1)
print(nums.startIndex, nums.endIndex)
print(nums.prefix(2), nums.suffix(2))
print(nums.dropFirst(), nums.dropLast(1))
print((1..<6).reduce(0, +))
print((1..<6).allSatisfy { $0 > 0 })
print((1..<6).compactMap { $0 % 2 == 0 ? $0 * 10 : nil })
print(Array((1..<6).sorted().reversed()))
print((1..<6).enumerated().map { $0.offset })
print((1..<6).firstIndex(of: 3) ?? -1)
print((1..<6).min() ?? -1, (1..<6).max() ?? -1)
print(Array((1..<6).dropFirst(2)))

let prices = ["a": 1, "b": 2]
print(prices.map { $0.0 }.sorted())
let doubled = prices.mapValues { $0 * 2 }
print(doubled["a"] ?? -1, doubled["b"] ?? -1)
print(prices.contains { $0.value > 1 })
var stock = ["x": 1]
let old = stock.updateValue(5, forKey: "x")
print(old ?? -1, stock["x"] ?? -1)
stock.removeAll()
print(stock.count, stock.isEmpty)

print(2.5.rounded(), 2.5.rounded(.up), 2.5.rounded(.down))
print((-2.5).rounded(.toNearestOrAwayFromZero), 2.5.rounded(.toNearestOrEven))
print(2.0.isNaN, Double.infinity.isInfinite, (2.0).isFinite)
print(3.7.description)
print((-5).magnitude, (-5).signum(), 5.magnitude)
print(true.description, false.description)

print(sqrt(4.0), floor(2.7), ceil(2.1), round(2.5))
print(sin(0.0), cos(0.0))
print(exp(0.0), log(1.0), pow(2.0, 10.0))

let names = ["a", "b", "c"]
let codes = [1, 2]
for p in zip(names, codes) {
    print(p.0, p.1)
}
let pairs = Array(zip(codes, names))
print(pairs.count)
let cells = Array(repeatElement(0, count: 2))
print(cells)
