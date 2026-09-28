// Array：增删改查、下标、first/last、indices、contains、isEmpty、区间下标
var fruits = ["apple", "banana"]
fruits.append("cherry")
fruits.insert("apricot", at: 1)
print(fruits, fruits.count)
let removed = fruits.remove(at: 2)
print(removed, fruits)
fruits[0] = "avocado"
print(fruits.first ?? "none", fruits.last ?? "none", fruits.isEmpty)
print(fruits.contains("cherry"), fruits.contains("kiwi"))
for i in fruits.indices {
    print(i, fruits[i])
}
var nums = [4, 8, 15, 16, 23, 42]
print(nums[1...3], nums[0..<2].count)
print(nums.firstIndex(of: 15) ?? -1, nums.firstIndex(of: 7) ?? -1)
print(nums.min() ?? 0, nums.max() ?? 0)
nums.removeLast()
nums.removeFirst()
print(nums)
nums.append(contentsOf: [1, 2])
nums.reverse()
print(nums)
nums.swapAt(0, 1)
print(nums)
nums.sort()
print(nums)
var words = ["pear", "apple", "fig"]
words.sort(by: >)
print(words)
words.sort { $0.count < $1.count }
print(words)
var evens = [1, 2, 3, 4, 5]
evens.removeAll(where: { $0 % 2 == 1 })
print(evens)
print(Array([3, 1, 2].reversed()))
nums.removeAll()
print(nums, nums.isEmpty)
let empty: [Int] = []
print(empty.first ?? -1, empty.last ?? -1)
let repeated = Array(repeating: 0, count: 3)
print(repeated, [1, 2] + [3])
