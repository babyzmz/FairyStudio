// 运行错误：字典缺 key 时强制解包
let scores = ["ann": 90, "bob": 72]
for name in ["ann", "bob", "cid"] {
    let s = scores[name]!
    print(name, s)
}
print("unreachable")
