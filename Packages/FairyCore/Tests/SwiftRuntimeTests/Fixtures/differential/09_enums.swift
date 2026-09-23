// enum：无关联值、switch、方法、计算属性、CaseIterable、rawValue
enum Direction: CaseIterable {
    case north, east, south, west

    var turnedRight: Direction {
        switch self {
        case .north: return .east
        case .east: return .south
        case .south: return .west
        case .west: return .north
        }
    }

    mutating func turnLeft() {
        switch self {
        case .north: self = .west
        case .west: self = .south
        case .south: self = .east
        case .east: self = .north
        }
    }
}
var d = Direction.north
print(d, d.turnedRight)
d.turnLeft()
print(d)
print(Direction.allCases.count)
for dir in Direction.allCases {
    print(dir, terminator: " ")
}
print()
enum Planet: Int {
    case mercury = 1, venus, earth, mars
}
print(Planet.earth.rawValue, Planet(rawValue: 4) ?? .mercury, Planet(rawValue: 9) == nil)
enum Suit: String {
    case hearts = "♥"
    case spades
}
print(Suit.hearts.rawValue, Suit.spades.rawValue, Suit(rawValue: "♥") == .hearts)
print(d == .east, d != .north)
let pair = [Direction.south, .north]
print(pair.count)
