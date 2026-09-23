import Testing
import Foundation
import FoundationAI

/// 一次真实的本地模型调用（M0-C 门禁记录）。
/// - 可用时：经 ModelBroker 调用 SystemLanguageModel，记录实际后端、耗时、响应前 200 字；
/// - 不可用时：原样记录不可用原因，不做任何调用，更不提供假响应。
/// 输出行以 `[FAIRY-MODEL-CALL]` 开头，写入 xcodebuild 日志。
@Suite("本地模型真实调用", .serialized)
struct OnDeviceModelCallTests {
    static let prompt = "用一句话介绍你自己"

    private func log(_ line: String) {
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    @Test("用一句话介绍你自己（可用则真实调用，不可用则记录原因）", .timeLimit(.minutes(3)))
    func realCallOrRecordedReason() async {
        let driver = OnDeviceModelDriver()
        let raw = driver.rawAvailabilityDescription()
        let broker = ModelBroker.live()
        let availability = await broker.checkAvailability(backend: .onDevice)
        log("[FAIRY-MODEL-CALL] availability mapped=\(availability.code) raw=\(raw)")
        guard availability.isAvailable else {
            log("[FAIRY-MODEL-CALL] 未调用：设备端模型不可用（\(availability.reasonDescription)）")
            #expect(!raw.isEmpty)
            return
        }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await broker.perform(ModelRequest(prompt: Self.prompt, backend: .onDevice)) { _ in }
        let elapsed = clock.now - start
        switch outcome {
        case let .completed(response):
            let head = String(response.text.prefix(200))
            log("[FAIRY-MODEL-CALL] completed backend=\(response.backend.rawValue) elapsed=\(elapsed) chars=\(response.text.count) head200=\(head)")
            #expect(response.backend == .onDevice)
            #expect(!response.text.isEmpty)
        case let .failed(failure):
            log("[FAIRY-MODEL-CALL] failed elapsed=\(elapsed) failure=\(failure) message=\(failure.userMessage)")
            Issue.record("设备端报告可用但调用失败：\(failure)")
        case .cancelled:
            log("[FAIRY-MODEL-CALL] cancelled elapsed=\(elapsed)")
            Issue.record("调用被取消")
        }
    }
}
