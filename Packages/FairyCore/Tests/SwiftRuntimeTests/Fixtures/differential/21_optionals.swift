// Optional：??、if let、guard let、可选链、强制解包、打印 Optional(...)
struct Owner {
    var name: String
    var pet: Pet?
}
struct Pet {
    var name: String
    var age: Int
}
let alice = Owner(name: "Alice", pet: Pet(name: "Mimi", age: 3))
let bob = Owner(name: "Bob", pet: nil)
print(alice.pet?.name ?? "no pet", bob.pet?.name ?? "no pet")
print(alice.pet?.age, bob.pet?.age)
if let pet = alice.pet {
    print("\(alice.name) has \(pet.name)")
}
if let pet = bob.pet {
    print(pet.name)
} else {
    print("\(bob.name) has no pet")
}
func petAge(_ o: Owner) -> Int {
    guard let p = o.pet else { return -1 }
    return p.age
}
print(petAge(alice), petAge(bob))
var maybe: String? = "hi"
print(maybe!.uppercased(), maybe?.count ?? 0)
maybe = nil
print(maybe ?? "nil value", maybe == nil)
let numbers: [Int?] = [1, nil, 3]
print(numbers)
let n: Int? = 5
print(n, n == 5, n != nil)
var x: Int? = nil
x = 10
if let x {
    print("shorthand", x)
}
let words = ["one": 1]
print(words["one"], words["two"])
