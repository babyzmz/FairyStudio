import Foundation

/// 单个模型后端的驱动。只由 ModelBroker 调用。
public protocol ModelBackendDriver: Sendable {
    var backend: ModelBackend { get }
    /// 实时检测可用性（每个任务开始时调用，不缓存）。
    func checkAvailability() async -> ModelAvailability
    /// 流式生成：每个元素是到目前为止的完整文本快照。
    /// 失败以 `ModelTaskFailure` 结束流；消费方取消时必须停止底层生成。
    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error>
}

extension ModelBackendDriver {
    /// 立即以失败结束的流。
    static func failedStream(_ failure: ModelTaskFailure) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }
}
