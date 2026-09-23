import RuntimeContracts

/// 一个 @State 存储单元。键 = 视图身份路径 + 字段名；视图重建不会重新初始化。
final class StateCell {
    let key: String
    let program: IRProgram
    var value: Value
    weak var store: StateStore?

    init(key: String, program: IRProgram, value: Value, store: StateStore) {
        self.key = key; self.program = program; self.value = value; self.store = store
    }

    func markDirty() { store?.dirty = true }
}

/// @State 存储。键为 `(视图身份路径, 字段名)`；视图身份路径由结构位置 + 自定义 View 类型名 + ForEach 稳定 id 组成。
///
/// 每次渲染开始时清空"本轮触及"集合；渲染结束后移除本轮未触及的单元（对应视图已从层级中消失，
/// 与 SwiftUI 一致：视图离开层级后其 @State 丢弃）。
final class StateStore {
    private(set) var cells: [String: StateCell] = [:]
    private var touched: Set<String> = []
    var dirty = false
    let program: IRProgram

    init(program: IRProgram) { self.program = program }

    static func key(viewPath: String, field: String) -> String { viewPath + "#" + field }

    /// 取得（或以初始值创建）状态单元。已存在时忽略新的初始值。
    func cell(viewPath: String, field: String, initial: Value) -> StateCell {
        let k = StateStore.key(viewPath: viewPath, field: field)
        touched.insert(k)
        if let c = cells[k] { return c }
        let c = StateCell(key: k, program: program, value: initial, store: self)
        cells[k] = c
        return c
    }

    func beginRender() { touched.removeAll(keepingCapacity: true) }

    func endRender() {
        for k in cells.keys where !touched.contains(k) { cells[k] = nil }
    }

    func value(forKey key: String) -> Value? { cells[key]?.value }
}
