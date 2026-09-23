import Foundation
import RuntimeContracts
import SwiftRuntime

/// App 可用的执行引擎。M0-C 起正式路径只有 SwiftRuntime 解释器；夹具引擎（DevFixtures）不再进入 App，只供测试目标使用。
/// M5 的 WebRuntime 接入时在这里增加 case。
enum EngineChoice: String, Hashable, Identifiable, CaseIterable {
    case swiftRuntime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .swiftRuntime: "SwiftRuntime \(SwiftRuntimeEngine.version)"
        }
    }

    func makeEngine() -> any RuntimeEngine {
        switch self {
        case .swiftRuntime: SwiftRuntimeEngine()
        }
    }
}

/// 引擎内部的存活资源计数（运行实例 / 执行线程 / 内部任务），用于验证 run/stop 后无残留。只读诊断。
struct EngineLiveCounts: Hashable, Sendable {
    var instances: Int
    var threads: Int
    var tasks: Int

    var isZero: Bool { instances == 0 && threads == 0 && tasks == 0 }
}

/// 能报告存活资源计数的引擎。
protocol LiveCountReporting {
    var liveCounts: EngineLiveCounts { get }
}

extension SwiftRuntimeEngine: LiveCountReporting {
    var liveCounts: EngineLiveCounts {
        EngineLiveCounts(instances: liveCounters.liveInstances, threads: liveCounters.liveThreads, tasks: liveCounters.liveTasks)
    }
}
