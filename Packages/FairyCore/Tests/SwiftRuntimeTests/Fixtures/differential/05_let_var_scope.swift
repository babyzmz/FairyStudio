// let/var、作用域、遮蔽、类型标注、可选默认 nil
let a: Int = 1
var b = 2
b = b + a
do {
    let a = 100
    print("inner a", a)
}
print("outer a", a, "b", b)
var c: Double = 3
c += 1
print(c)
var opt: Int?
print(opt ?? -1)
opt = 5
print(opt ?? -1)
func shadow(_ a: Int) -> Int {
    let a = a * 2
    return a
}
print(shadow(21))
var list: [String] = []
list.append("x")
print(list)
