import Foundation
import Synchronization
@testable import FoundationAI

/// 测试专用的假后端（只存在于测试目标）。记录调用次数，可控制可用性、输出与挂起。
final class FakeModelDriver: ModelBackendDriver {
    let backend: ModelBackend
    private let availability: Mutex<ModelAvailability>
    private let chunks: [String]
    private let failure: ModelTaskFailure?
    private let hangAfterChunks: Bool
    let availabilityChecks = Mutex(0)
    let streamCalls = Mutex(0)
    let streamCancelled = Mutex(false)

    init(backend: ModelBackend, availability: ModelAvailability = .available, chunks: [String] = ["你", "你好"],
         failure: ModelTaskFailure? = nil, hangAfterChunks: Bool = false) {
        self.backend = backend
        self.availability = Mutex(availability)
        self.chunks = chunks
        self.failure = failure
        self.hangAfterChunks = hangAfterChunks
    }

    func setAvailability(_ value: ModelAvailability) {
        availability.withLock { $0 = value }
    }

    func checkAvailability() async -> ModelAvailability {
        availabilityChecks.withLock { $0 += 1 }
        return availability.withLock { $0 }
    }

    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error> {
        streamCalls.withLock { $0 += 1 }
        let chunks = chunks
        let failure = failure
        let hang = hangAfterChunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if hang {
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        self.streamCancelled.withLock { $0 = true }
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 收集 onPartial 快照，并允许测试等待第一条快照。
final class PartialCollector: Sendable {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: String.self)
    }

    var handler: @Sendable (String) async -> Void {
        { [continuation] text in continuation.yield(text) }
    }

    func first() async -> String? {
        for await value in stream { return value }
        return nil
    }
}

func isolatedConsent(_ name: String = #function) -> CloudConsentStore {
    let store = CloudConsentStore(suiteName: "fairy.tests.\(name).\(UUID().uuidString)")
    store.revokeConsent()
    return store
}
