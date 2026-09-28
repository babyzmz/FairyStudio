// String 常用 API 与插值
import Foundation
let s = "Hello, Swift"
print(s.count, s.isEmpty, "".isEmpty)
print(s.uppercased(), s.lowercased())
print(s.contains("Swift"), s.hasPrefix("Hell"), s.hasSuffix("!"))
let name = "世界"
print("你好，\(name)！长度 \(name.count)")
var greeting = "Hi"
greeting += " there"
greeting.append("!")
print(greeting)
let parts = "a,b,c".split(separator: ",")
print(parts.count)
print(String(repeating: "ab", count: 3))
print(String(42) + "!", String(3.5))
let multi = """
    第一行
      缩进的第二行
    第三行 \(1 + 2)
    """
print(multi)
print("tab\tquote\"backslash\\")
print(String(s.reversed()))
print(["x", "y", "z"].joined(separator: "-"))
print("a" + "b" + "c", "abc" == "abc", "abc" < "abd")
let emoji = "🇨🇳👍🏽"
print(emoji.count)
print("Hello, Swift".replacingOccurrences(of: "Swift", with: "World"))
print("  padded  ".trimmingCharacters(in: .whitespacesAndNewlines))
