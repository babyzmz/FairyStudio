/// TextField 本地编辑缓冲与运行时文本的协调规则（纯值类型，平台无关，可在 macOS 单测）。
///
/// 规则：
/// 1. 用户编辑时，输入法仍在组字（marked text）则不回传；组字结束后回传最终文本。
/// 2. 运行时回写的文本若是我们发出过的值（回声），不覆盖本地（本地至少一样新）——光标不动。
/// 3. 运行时文本与上一次看到的相同（只是 revision 变了），不做任何事——光标不动。
/// 4. 运行时主动改了文本（非回声、与本地不同）：组字中则暂不覆盖，否则以运行时为准。
public struct TextBufferReconciler: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case keepLocal
        case applyRuntime(String)
    }

    /// 已发出但尚未被运行时回声确认的值（按发送顺序）。
    public private(set) var inFlight: [String] = []
    /// 上一次观察到的运行时文本。
    public private(set) var lastRuntimeText: String?
    /// 最多记录的在途值，防止运行时从不回声时无限增长。
    public static let inFlightLimit = 64

    public init() {}

    /// 用户编辑后调用。返回需要回传给运行时的文本；组字中或未变化时返回 nil。
    public mutating func userEdited(_ text: String, isComposing: Bool) -> String? {
        guard !isComposing else { return nil }
        if inFlight.last == text { return nil }
        if inFlight.isEmpty, text == lastRuntimeText { return nil }
        inFlight.append(text)
        if inFlight.count > Self.inFlightLimit {
            inFlight.removeFirst(inFlight.count - Self.inFlightLimit)
        }
        return text
    }

    /// 运行时给出（可能未变化的）文本时调用。
    public mutating func runtimeUpdated(_ runtimeText: String, localText: String, isComposing: Bool) -> Decision {
        defer { lastRuntimeText = runtimeText }
        if let echoIndex = inFlight.firstIndex(of: runtimeText) {
            inFlight.removeFirst(echoIndex + 1)
            return .keepLocal
        }
        if runtimeText == lastRuntimeText || runtimeText == localText {
            return .keepLocal
        }
        if isComposing {
            // 组字期间不打断输入法；组字结束后用户文本会回传，以用户输入为准。
            return .keepLocal
        }
        inFlight.removeAll()
        return .applyRuntime(runtimeText)
    }
}
