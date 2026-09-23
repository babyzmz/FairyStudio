// 值语义：struct 复制、数组复制、嵌套结构、函数参数传值
struct Point {
    var x: Int
    var y: Int
}
struct Shape {
    var name: String
    var points: [Point]
}
var a = Point(x: 1, y: 2)
var b = a
b.x = 100
print(a.x, b.x)

var arr1 = [1, 2, 3]
var arr2 = arr1
arr2.append(4)
arr2[0] = 99
print(arr1, arr2)

var s1 = Shape(name: "tri", points: [Point(x: 0, y: 0), Point(x: 1, y: 0)])
var s2 = s1
s2.points[1].y = 7
s2.points.append(Point(x: 3, y: 3))
s2.name = "quad"
print(s1.name, s1.points.count, s1.points[1].y)
print(s2.name, s2.points.count, s2.points[1].y)

func mutateCopy(_ p: Point) -> Point {
    var q = p
    q.y += 10
    return q
}
let moved = mutateCopy(a)
print(a.y, moved.y)

var grid = [[0, 0], [0, 0]]
var gridCopy = grid
gridCopy[1][0] = 5
print(grid, gridCopy)

var dict1 = ["k": [1]]
var dict2 = dict1
dict2["k"]?.append(2)
dict2["new"] = [3]
print(dict1["k"] ?? [], dict2["k"] ?? [], dict1.count, dict2.count)
