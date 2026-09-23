// switch：整数、字符串、区间、多值、where、值绑定、default
func classify(_ n: Int) -> String {
    switch n {
    case 0:
        return "zero"
    case 1, 2, 3:
        return "small"
    case 4...9:
        return "medium"
    case let x where x < 0:
        return "negative \(x)"
    default:
        return "large"
    }
}
for n in [0, 2, 7, -4, 100] {
    print(n, classify(n))
}
func animal(_ s: String) -> String {
    switch s {
    case "cat", "dog":
        return "pet"
    case "lion":
        return "wild"
    default:
        return "unknown"
    }
}
print(animal("dog"), animal("lion"), animal("fish"))
let flag = true
switch flag {
case true:
    print("yes")
case false:
    print("no")
}
var hits = 0
for v in 1...20 {
    switch v % 5 {
    case 0:
        hits += 1
    default:
        break
    }
}
print("hits", hits)
