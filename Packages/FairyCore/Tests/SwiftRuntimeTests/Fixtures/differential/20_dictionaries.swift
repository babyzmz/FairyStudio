// Dictionary：下标读写、默认值、删除、keys/values（排序后输出以保证确定性）、for-in
var stock: [String: Int] = ["apple": 3, "pear": 5]
stock["kiwi"] = 7
stock["apple"] = 10
print(stock["apple"] ?? 0, stock["banana"] ?? 0, stock.count)
stock["pear"] = nil
print(stock.count, stock["pear"] == nil)
let removed = stock.removeValue(forKey: "kiwi")
print(removed ?? -1, stock.count)
var counts: [String: Int] = [:]
for word in ["a", "b", "a", "c", "a", "b"] {
    counts[word, default: 0] += 1
}
for key in counts.keys.sorted() {
    print(key, counts[key]!)
}
print(counts.values.sorted())
var totals = 0
for (_, v) in counts {
    totals += v
}
print("totals", totals)
let ages = ["ann": 31, "bob": 25]
let sortedByAge = ages.sorted { $0.value < $1.value }.map { $0.key }
print(sortedByAge)
print(ages.isEmpty, [String: Int]().isEmpty)
var nested: [String: [Int]] = [:]
nested["x", default: []].append(1)
nested["x", default: []].append(2)
print(nested["x"] ?? [])
