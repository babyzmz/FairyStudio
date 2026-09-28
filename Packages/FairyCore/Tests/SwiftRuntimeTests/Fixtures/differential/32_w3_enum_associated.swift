// W3：enum 关联值（构造+存储）+ switch 模式匹配（含绑定与 where）
enum Outcome {
    case ok(Int)
    case err(String)
    case point(x: Int, y: String)
    case none
}
let a = Outcome.ok(42)
print(a)
let b: Outcome = .err("boom")
print(b)
print(Outcome.point(x: 1, y: "hi"))
print(Outcome.none)
func describe(_ r: Outcome) -> String {
    switch r {
    case .ok(let n): return "ok \(n)"
    case .err(let m): return "err \(m)"
    case .point(x: let x, y: let y): return "pt \(x) \(y)"
    case .none: return "none"
    }
}
print(describe(a))
print(describe(b))
print(describe(.point(x: 2, y: "yo")))
switch a {
case .ok(42): print("exact")
default: print("other")
}
switch b {
case .err(let m) where m.count > 2: print("long \(m)")
default: print("other2")
}
if case .ok(let n) = a { print("ifcase \(n)") }
switch a {
case let .ok(n): print("let-prefix \(n)")
default: print("no")
}
switch b {
case .ok(_): print("is-ok")
case .err(_): print("is-err")
default: print("neither")
}
