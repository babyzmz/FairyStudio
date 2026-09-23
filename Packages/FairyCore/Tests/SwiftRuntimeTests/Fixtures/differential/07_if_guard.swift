// if / else if / guard
func grade(_ score: Int) -> String {
    if score >= 90 {
        return "A"
    } else if score >= 80 {
        return "B"
    } else if score >= 60 {
        return "C"
    } else {
        return "F"
    }
}
print(grade(95), grade(85), grade(70), grade(10))
func describe(_ value: Int?) -> String {
    guard let v = value else {
        return "nothing"
    }
    guard v > 0 else {
        return "non-positive \(v)"
    }
    return "positive \(v)"
}
print(describe(nil), describe(-3), describe(8))
let temps = [12, 25, 31]
for t in temps {
    if t > 30 {
        print(t, "hot")
    } else if t > 20 {
        print(t, "warm")
    } else {
        print(t, "cool")
    }
}
let input: String? = "12"
if let text = input, let number = Int(text), number > 10 {
    print("big number", number)
}
