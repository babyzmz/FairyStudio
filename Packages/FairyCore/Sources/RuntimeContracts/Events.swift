import Foundation

public enum ConsoleStream: String, Sendable, Codable { case stdout, stderr, debug }

/// 运行时 → 宿主。每个事件带 runID 和单调 sequence；宿主丢弃不属于当前实例或乱序的事件。
public struct RuntimeEventEnvelope: Sendable {
    public var runID: RunID
    public var sequence: UInt64
    public var event: RuntimeEvent
    public init(runID: RunID, sequence: UInt64, event: RuntimeEvent) { self.runID = runID; self.sequence = sequence; self.event = event }
}

public enum RuntimeEvent: Sendable {
    case stateChanged(RunState)
    case render(RenderTree)
    case diagnostic(Diagnostic)
    case console(ConsoleStream, String)
    case capabilityRequest(CapabilityRequest)
    case finished(ExitReason)
}

/// 宿主 → 运行时。UI 交互事件也带 runID + sequence，旧实例回调不得污染新实例。
public struct RuntimeInputEnvelope: Sendable {
    public var runID: RunID
    public var sequence: UInt64
    public var input: RuntimeInput
    public init(runID: RunID, sequence: UInt64, input: RuntimeInput) { self.runID = runID; self.sequence = sequence; self.input = input }
}

public enum RuntimeInput: Sendable, Hashable {
    case action(ActionID)
    case setBinding(BindingID, TransferValue)
    case appear(NodeID)
    case disappear(NodeID)
    case navigationPop(count: Int)
    case navigationPush(destinationID: NodeID)
    case dismissSheet
    case capabilityResponse(CapabilityRequest.ID, CapabilityResponse)
}

/// 项目请求宿主能力（文件、照片、音频…）。宿主策略 → 用户确认 → 系统权限 → 执行，由 CapabilityKit 负责。
public struct CapabilityRequest: Sendable, Hashable, Codable, Identifiable {
    public typealias ID = UUID
    public var id: ID
    public var capabilityID: String
    public var version: Int
    public var payload: TransferValue
    public init(id: ID = UUID(), capabilityID: String, version: Int = 1, payload: TransferValue) {
        self.id = id; self.capabilityID = capabilityID; self.version = version; self.payload = payload
    }
}

public enum CapabilityResponse: Sendable, Hashable, Codable {
    case success(TransferValue)
    case denied(reason: String)
    case unavailable(reason: String)
    case failed(message: String)
    case cancelled
}
