// Int 算术、整除、取余、优先级、位运算、溢出包装运算
let a = 17
let b = 5
print(a + b, a - b, a * b, a / b, a % b)
print(-a / b, -a % b, a / -b)
print(2 + 3 * 4, (2 + 3) * 4, 10 - 4 - 3)
print(a & b, a | b, a ^ b, a << 2, a >> 1, ~a)
print(Int.max &+ 1 == Int.min, Int.min &- 1 == Int.max)
var x = 10
x += 5
x -= 3
x *= 2
x /= 4
x %= 4
print("x =", x)
print(abs(-12), min(4, 9), max(4, 9), min(7, 3, 5))
print(12.isMultiple(of: 4), 7.isMultiple(of: 2))
print(Int.max, Int.min)
