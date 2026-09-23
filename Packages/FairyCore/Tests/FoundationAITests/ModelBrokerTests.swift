import Testing
import Foundation
@testable import FoundationAI

@Suite("ModelBroker 策略")
struct ModelBrokerTests {
    @Test("默认后端是设备端")
    func defaultIsOnDevice() {
        #expect(ModelBroker.defaultBackend == .onDevice)
        #expect(ModelRequest(prompt: "x").backend == .onDevice)
    }

    @Test("成功流式生成：返回实际后端与最终文本")
    func completes() async {
        let driver = FakeModelDriver(backend: .onDevice, chunks: ["你", "你好", "你好。"])
        let broker = ModelBroker(drivers: [driver], consent: isolatedConsent())
        let outcome = await broker.perform(ModelRequest(prompt: "hi")) { _ in }
        #expect(outcome == .completed(ModelResponse(text: "你好。", backend: .onDevice)))
        #expect(await broker.isResponding == false)
    }

    @Test("每个任务开始时都重新检测可用性（不是只在启动时）")
    func checksAvailabilityPerTask() async {
        let driver = FakeModelDriver(backend: .onDevice)
        let broker = ModelBroker(drivers: [driver], consent: isolatedConsent())
        _ = await broker.perform(ModelRequest(prompt: "1")) { _ in }
        driver.setAvailability(.modelNotReady)
        let second = await broker.perform(ModelRequest(prompt: "2")) { _ in }
        #expect(second == .failed(.unavailable(.modelNotReady)))
        #expect(driver.availabilityChecks.withLock { $0 } == 2)
        #expect(driver.streamCalls.withLock { $0 } == 1)
    }

    @Test("单在途：已有任务时新请求返回 busy；取消后返回 cancelled 且底层生成被停止")
    func singleInFlightAndCancel() async {
        let driver = FakeModelDriver(backend: .onDevice, chunks: ["部分"], hangAfterChunks: true)
        let broker = ModelBroker(drivers: [driver], consent: isolatedConsent())
        let collector = PartialCollector()
        let running = Task { await broker.perform(ModelRequest(prompt: "长任务"), onPartial: collector.handler) }
        #expect(await collector.first() == "部分")
        #expect(await broker.isResponding)

        let second = await broker.perform(ModelRequest(prompt: "第二个")) { _ in }
        #expect(second == .failed(.busy))

        await broker.cancelCurrentTask()
        #expect(await running.value == .cancelled)
        #expect(await broker.isResponding == false)
        // 底层流收到取消。
        for _ in 0..<50 where !driver.streamCancelled.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(driver.streamCancelled.withLock { $0 })
    }

    @Test("调用方任务被取消也会停止生成")
    func callerCancellation() async {
        let driver = FakeModelDriver(backend: .onDevice, chunks: ["a"], hangAfterChunks: true)
        let broker = ModelBroker(drivers: [driver], consent: isolatedConsent())
        let collector = PartialCollector()
        let running = Task { await broker.perform(ModelRequest(prompt: "x"), onPartial: collector.handler) }
        _ = await collector.first()
        running.cancel()
        #expect(await running.value == .cancelled)
    }

    @Test("GenerationError 以明确状态返回")
    func generationFailureSurfaces() async {
        let driver = FakeModelDriver(backend: .onDevice, chunks: [], failure: .exceededContextWindowSize("too long"))
        let broker = ModelBroker(drivers: [driver], consent: isolatedConsent())
        let outcome = await broker.perform(ModelRequest(prompt: "x")) { _ in }
        #expect(outcome == .failed(.exceededContextWindowSize("too long")))
    }

    @Test("云端首次使用需要用户确认；未确认时不调用云端")
    func cloudRequiresConsent() async {
        let cloud = FakeModelDriver(backend: .privateCloudCompute)
        let consent = isolatedConsent()
        let broker = ModelBroker(drivers: [FakeModelDriver(backend: .onDevice), cloud], consent: consent)
        let denied = await broker.perform(ModelRequest(prompt: "x", backend: .privateCloudCompute)) { _ in }
        #expect(denied == .failed(.cloudConsentRequired))
        #expect(cloud.streamCalls.withLock { $0 } == 0)
        #expect(cloud.availabilityChecks.withLock { $0 } == 0)

        consent.grantConsent()
        let allowed = await broker.perform(ModelRequest(prompt: "x", backend: .privateCloudCompute)) { _ in }
        #expect(allowed == .completed(ModelResponse(text: "你好", backend: .privateCloudCompute)))
        consent.revokeConsent()
        #expect(consent.hasConsented == false)
    }

    @Test("设备端不可用时绝不静默转到云端（即使云端可用且已确认）")
    func noSilentCloudFallback() async {
        let local = FakeModelDriver(backend: .onDevice, availability: .appleIntelligenceNotEnabled)
        let cloud = FakeModelDriver(backend: .privateCloudCompute)
        let consent = isolatedConsent()
        consent.grantConsent()
        let broker = ModelBroker(drivers: [local, cloud], consent: consent)
        let outcome = await broker.perform(ModelRequest(prompt: "机密内容", backend: .onDevice)) { _ in }
        #expect(outcome == .failed(.unavailable(.appleIntelligenceNotEnabled)))
        #expect(cloud.streamCalls.withLock { $0 } == 0)
        #expect(local.streamCalls.withLock { $0 } == 0)
    }

    @Test("生产配置下的 PCC 请求：确认后仍因 SDK 缺失而失败")
    func liveBrokerPCC() async {
        let consent = isolatedConsent()
        consent.grantConsent()
        let broker = ModelBroker.live(consent: consent)
        #expect(await broker.checkAvailability(backend: .privateCloudCompute) == .pccSDKMissing)
        let outcome = await broker.perform(ModelRequest(prompt: "x", backend: .privateCloudCompute)) { _ in }
        #expect(outcome == .failed(.unavailable(.pccSDKMissing)))
    }
}
