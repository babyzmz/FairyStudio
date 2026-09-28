// W3：inout 形参与 &实参（按地址回写）
func inc(_ x: inout Int) { x += 1 }
var a = 10
inc(&a)
print(a)
func swap2(_ x: inout Int, _ y: inout Int) {
    let t = x
    x = y
    y = t
}
var p = 1, q = 2
swap2(&p, &q)
print("\(p) \(q)")
func bump(_ v: inout Int, by d: Int = 5) { v += d }
var m = 0
bump(&m)
bump(&m, by: 3)
print(m)
struct Bag {
    var items: [Int]
    mutating func drainOne(_ out: inout Int) -> Int {
        out = items.count
        return items.removeLast()
    }
}
var bag = Bag(items: [1, 2, 3])
var total = 0
print(bag.drainOne(&total))
print(total, bag.items)
func chain(_ x: inout Int) { inc(&x); inc(&x) }
var c = 0
chain(&c)
print(c)
var arr = [10, 20, 30]
inc(&arr[1])
print(arr)
