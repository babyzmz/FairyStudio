// Bool、比较、逻辑短路
func check(_ label: String, _ v: Bool) -> Bool {
    print("check", label)
    return v
}
let t = true
let f = false
print(t && f, t || f, !t, t == f, t != f)
if check("a", false) && check("b", true) {
    print("both")
} else {
    print("short-circuit and")
}
if check("c", true) || check("d", true) {
    print("short-circuit or")
}
print(3 < 5, 3 <= 3, 5 > 7, 5 >= 5, 4 == 4, 4 != 4)
print("apple" < "banana", "b" > "a")
var flag = false
flag.toggle()
print(flag)
let x = 7
let inRange = x > 0 && x < 10
print(inRange ? "in" : "out")
