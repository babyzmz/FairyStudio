import Foundation

/// Apple 云端后端（Private Cloud Compute）。
///
/// 当前 iOS 26.2 SDK 中没有 PCC 相关符号（已 grep swiftinterface 核实），因此：
/// - 未定义编译条件 `FAIRY_PCC_SDK` 时，后端固定报告 `.pccSDKMissing`，不会发出任何请求；
/// - 定义 `FAIRY_PCC_SDK` 却没有按真实 SDK 实现时，编译直接失败（见下方 #error），避免编造 API。
/// 待 Xcode 27 / iOS 27 SDK 与官方文档核对后实现，核对清单见 docs/APPLE_MODELS.md。
public struct PrivateCloudComputeDriver: ModelBackendDriver {
    public let backend = ModelBackend.privateCloudCompute

    public init() {}

    #if FAIRY_PCC_SDK
    #error("FAIRY_PCC_SDK 已定义，但 PCC 后端尚未按 iOS 27 SDK 的真实符号实现。请先完成 docs/APPLE_MODELS.md 中的核对清单。")
    #else
    public func checkAvailability() async -> ModelAvailability {
        .pccSDKMissing
    }

    public func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<String, any Error> {
        Self.failedStream(.unavailable(.pccSDKMissing))
    }
    #endif
}
