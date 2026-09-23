// 算法：冒泡排序、埃氏筛、二分查找、FizzBuzz、字符统计
func bubbleSort(_ input: [Int]) -> [Int] {
    var a = input
    if a.count < 2 { return a }
    for i in 0..<a.count {
        for j in 0..<(a.count - 1 - i) {
            if a[j] > a[j + 1] {
                a.swapAt(j, j + 1)
            }
        }
    }
    return a
}
print(bubbleSort([5, 1, 4, 2, 8, 0]))

func primes(upTo n: Int) -> [Int] {
    var isPrime = Array(repeating: true, count: n + 1)
    isPrime[0] = false
    isPrime[1] = false
    var p = 2
    while p * p <= n {
        if isPrime[p] {
            var m = p * p
            while m <= n {
                isPrime[m] = false
                m += p
            }
        }
        p += 1
    }
    return (0...n).filter { isPrime[$0] }
}
print(primes(upTo: 50))

func binarySearch(_ a: [Int], _ target: Int) -> Int? {
    var lo = 0
    var hi = a.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if a[mid] == target { return mid }
        if a[mid] < target { lo = mid + 1 } else { hi = mid - 1 }
    }
    return nil
}
let sorted = [1, 3, 5, 7, 9, 11]
print(binarySearch(sorted, 7) ?? -1, binarySearch(sorted, 4) ?? -1)

for i in 1...15 {
    if i % 15 == 0 {
        print("FizzBuzz")
    } else if i % 3 == 0 {
        print("Fizz")
    } else if i % 5 == 0 {
        print("Buzz")
    } else {
        print(i)
    }
}

var freq: [String: Int] = [:]
for ch in "mississippi" {
    freq[String(ch), default: 0] += 1
}
print(freq.keys.sorted().map { "\($0)=\(freq[$0]!)" }.joined(separator: " "))
