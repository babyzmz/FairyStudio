// W3：Double 格式化（String(format:) 仅 %.Nf）+ Date 只读基础
import Foundation
print(String(format: "%.2f", 3.14159))
print(String(format: "%.0f", 2.5))
print(String(format: "v=%.1f", 1.25))
print(String(format: "%.3f", 2.0))
print(String(format: "100%%"))
let now = Date()
print(now.description.hasPrefix("20"))
print(Date.now.description.hasPrefix("20"))
print(now == Date.now || now < Date.now)
print(String(describing: Date.now).hasPrefix("20"))
print("\(Date.now)".hasPrefix("20"))
print(now.description == now.description)
