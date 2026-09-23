// while / repeat-while / break / continue
var n = 27
var steps = 0
while n != 1 {
    if n % 2 == 0 {
        n /= 2
    } else {
        n = 3 * n + 1
    }
    steps += 1
}
print("collatz steps", steps)
var i = 0
repeat {
    i += 1
    if i == 2 { continue }
    if i == 5 { break }
    print("repeat", i)
} while i < 10
var found = -1
for x in 1...100 {
    if x * x > 50 {
        found = x
        break
    }
}
print("found", found)
var odd = [Int]()
for x in 1...10 {
    if x % 2 == 0 { continue }
    odd.append(x)
}
print(odd)
var queue = [3, 1, 2]
while let last = queue.popLast() {
    print("pop", last)
}
