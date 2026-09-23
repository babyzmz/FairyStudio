// 运行错误：强制解包 nil
let inputs = ["10", "20", "x", "40"]
var sum = 0
for s in inputs {
    let n = Int(s)!
    sum += n
    print("sum", sum)
}
print("unreachable")
