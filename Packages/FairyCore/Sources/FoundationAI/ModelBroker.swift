import Foundation

/// 模型访问的唯一入口。
///
/// 策略：
/// - 只有设备端与 Apple 云端两个后端，默认设备端；
/// - 每个任务开始时实时调用 `checkAvailability(backend:)`，不依赖启动时的缓存；
/// - 云端首次使用前需要 `CloudConsentStore` 中的用户确认；
/// - 绝不在后端之间自动回退：设备端不可用时任务失败并给出原因，不会静默转到云端；
/// - 单在途：同一时刻只允许一个任务，新请求返回 `.busy`；
/// - 取消：`cancelCurrentTask()` 或调用方任务被取消都会停止底层生成并返回 `.cancelled`。
public actor ModelBroker {
    public static let defaultBackend = ModelBackend.onDevice

    private let drivers: [ModelBackend: any ModelBackendDriver]
    private let consent: CloudConsentStore
    public private(set) var isResponding = false
    private var currentTask: Task<ModelTaskOutcome, Never>?
    private var cancelRequested = false

    public init(drivers: [any ModelBackendDriver], consent: CloudConsentStore) {
        var map: [ModelBackend: any ModelBackendDriver] = [:]
        for driver in drivers { map[driver.backend] = driver }
        self.drivers = map
        self.consent = consent
    }

    /// 生产配置：设备端 Foundation Models + PCC（当前 SDK 缺失时固定 pccSDKMissing）。
    public static func live(consent: CloudConsentStore = .standard) -> ModelBroker {
        ModelBroker(drivers: [OnDeviceModelDriver(), PrivateCloudComputeDriver()], consent: consent)
    }

    public func checkAvailability(backend: ModelBackend) async -> ModelAvailability {
        guard let driver = drivers[backend] else { return .unknown }
        return await driver.checkAvailability()
    }

    public var hasCloudConsent: Bool { consent.hasConsented }

    /// 执行一次生成。`onPartial` 收到到目前为止的完整文本快照。
    public func perform(_ request: ModelRequest, onPartial: @escaping @Sendable (String) async -> Void) async -> ModelTaskOutcome {
        guard !isResponding else { return .failed(.busy) }
        isResponding = true
        cancelRequested = false
        defer {
            isResponding = false
            currentTask = nil
            cancelRequested = false
        }

        if request.backend == .privateCloudCompute, !consent.hasConsented {
            return .failed(.cloudConsentRequired)
        }
        guard let driver = drivers[request.backend] else {
            return .failed(.unavailable(.unknown))
        }
        let availability = await driver.checkAvailability()
        guard availability.isAvailable else {
            return .failed(.unavailable(availability))
        }
        if cancelRequested || Task.isCancelled {
            return .cancelled
        }

        let backend = request.backend
        let task = Task<ModelTaskOutcome, Never> {
            var latest = ""
            do {
                for try await snapshot in driver.streamResponse(to: request) {
                    latest = snapshot
                    await onPartial(snapshot)
                }
                if Task.isCancelled { return .cancelled }
                return .completed(ModelResponse(text: latest, backend: backend))
            } catch is CancellationError {
                return .cancelled
            } catch let failure as ModelTaskFailure {
                return Task.isCancelled ? .cancelled : .failed(failure)
            } catch {
                return Task.isCancelled ? .cancelled : .failed(.systemError(String(describing: error)))
            }
        }
        currentTask = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 取消在途任务（若在能力检测阶段，则在检测结束后立即以 cancelled 结束）。
    public func cancelCurrentTask() {
        guard isResponding else { return }
        cancelRequested = true
        currentTask?.cancel()
    }
}
