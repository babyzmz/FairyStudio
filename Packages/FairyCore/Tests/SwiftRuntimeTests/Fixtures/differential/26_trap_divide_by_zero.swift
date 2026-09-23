// 运行错误：除以零
func ratio(_ a: Int, _ b: Int) -> Int {
    a / b
}
let divisors = [4, 2, 1, 0, 5]
for d in divisors {
    print("100 /", d, "=", ratio(100, d))
}
print("unreachable")
