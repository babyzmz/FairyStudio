// W3：元组构造 + let/var 解构声明 + 成员访问
let (a, b) = (1, 2)
print(a + b)
var (x, _, z): (Int, Double, String) = (7, 1.5, "hi")
print("\(x) \(z)")
x = 10
print(x)
func pair() -> (Int, Int) { (3, 4) }
let (p, q) = pair()
print(p * q)
let t = (name: "Ada", age: 36)
print(t.0, t.1, t.name, t.age)
let (n, g) = (t.name, t.age)
print("\(n) \(g)")
var u = (1, "s")
u.0 = 9
print(u)
