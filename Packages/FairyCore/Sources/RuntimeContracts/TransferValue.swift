import Foundation

/// 运行时与宿主之间的值传输协议。只允许这些形态，禁止 Any 转发。
public indirect enum TransferValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([TransferValue])
    case dictionary([String: TransferValue])
}
