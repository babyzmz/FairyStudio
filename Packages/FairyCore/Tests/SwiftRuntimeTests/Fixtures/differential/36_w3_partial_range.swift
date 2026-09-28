// W3：单侧范围（构造+打印+数组下标切片+比较）
let a = [10, 20, 30, 40, 50]
print(a[2...])
print(a[..<2])
print(a[...3])
print(a[0...])
print(a[..<5])
print(2...)
print(..<4)
print(...5)
print(a[2...] == a[2...])
print(a[..<2] == [10, 20])
let r = 1...
print(a[r])
let s = ..<3
print(a[s].count)
