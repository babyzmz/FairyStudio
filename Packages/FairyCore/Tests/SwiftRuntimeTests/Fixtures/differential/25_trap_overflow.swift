// 运行错误：整数溢出（之前的输出必须保留）
var x = Int.max - 2
for i in 0..<5 {
    print("step", i, x)
    x += 1
}
print("unreachable")
