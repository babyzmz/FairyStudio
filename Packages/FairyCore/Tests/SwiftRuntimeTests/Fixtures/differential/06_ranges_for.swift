// 区间与 for-in
for i in 0..<3 {
    print("half-open", i)
}
for i in 1...3 {
    print("closed", i)
}
var sum = 0
for n in stride(from: 0, to: 10, by: 3) {
    sum += n
}
print("stride sum", sum)
for n in stride(from: 5, through: 1, by: -2) {
    print("down", n)
}
for _ in 0..<2 {
    print("wild")
}
let r = 2..<6
print(r.count, r.contains(3), r.contains(6), r.lowerBound, r.upperBound)
print(Array(1...5))
for (i, c) in ["a", "b"].enumerated() {
    print(i, c)
}
for i in (1...4).reversed() {
    print("rev", i)
}
for i in 1...10 where i % 3 == 0 {
    print("where", i)
}
for ch in "hey" {
    print(ch)
}
