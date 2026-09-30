struct ConverterModel {
    var kind = "长度"
    var value: Double = 1

    func factors() -> [String: Double] {
        if kind == "长度" {
            return ["毫米": 0.001, "厘米": 0.01, "米": 1.0, "千米": 1000.0, "英寸": 0.0254, "英尺": 0.3048]
        }
        return ["克": 0.001, "千克": 1.0, "吨": 1000.0, "磅": 0.45359237, "盎司": 0.028349523]
    }

    func names() -> [String] {
        factors().keys.sorted()
    }

    func converted(_ unit: String) -> Double {
        value * (factors()[unit] ?? 0)
    }
}
