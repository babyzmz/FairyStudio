// print 格式：separator/terminator、集合、嵌套结构体、枚举、元组、字符串转义
struct Tag {
    var label: String
    var weight: Double
}
struct Post {
    var title: String
    var tags: [Tag]
    var views: Int?
}
enum Status {
    case draft, published
}
let post = Post(title: "Hello", tags: [Tag(label: "swift", weight: 1)], views: 42)
print(post)
print(post.tags)
print(Status.draft, [Status.published])
print("a", "b", "c", separator: "-")
print("no newline", terminator: "")
print(" | continued")
print([1, 2, 3], ["x": 1], [String: Int](), [Int]())
print(["quote\"d", "tab\t"])
print((1, "two"), (x: 1, y: 2.5))
print([[1, 2], [3]])
print(1...3, 0..<2)
print("emoji 🎉", "中文")
let empty = ""
print(empty, "after empty")
print()
print("done")
