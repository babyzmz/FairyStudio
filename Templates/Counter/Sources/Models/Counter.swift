// 计数器模型：与 Views/ContentView.swift 互相引用（跨文件）。
struct CounterModel {
    private(set) var count: Int = 0
    var step: Int = 1

    mutating func increment() {
        count += step
    }

    mutating func reset() {
        count = 0
    }

    var label: String {
        "Count: \(count)"
    }
}
