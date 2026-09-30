import Foundation
import ProjectContracts
import RuntimeContracts

// 页面重构 P0 状态契约（docs/REFACTOR_P0.md §状态契约）。
// 三个状态轴相互独立：模型慢不代表作品卡住，生成取消不代表作品停止，
// 更新被阻断不代表原版本不可用。所有取值来自真实执行事件，不用定时器模拟。

// MARK: - 生成状态（AI 侧）

/// 对应计划 §8.1 GenerationState。idle/receiving 由会话直接派生；
/// validating/validating 后的等待由事件回写（P2 起管线提供阶段回调，当前为记录值）。
enum GenerationState: Equatable, Sendable {
    /// 无在途生成任务。
    case idle
    /// 正在接收模型输出（流式或工具循环进行中）。
    case receiving
    /// 模型输出已完整接收，正在校验/演算候选（P2 起由管线阶段回调驱动）。
    case validating
    /// 候选已就绪，等待用户确认（未开启自动应用时）。
    case waiting
    /// 本轮生成被用户取消。
    case cancelled
    /// 本轮生成失败（含校验失败、模型错误、输出截断）。
    case failed
}

// MARK: - 运行状态（作品侧）

/// 对应计划 §8.1 RuntimeState。由 RunState（RuntimeContracts）一对一映射，
/// 不引入新的事实来源。
enum RuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case interrupted
    case failed

    init(from runState: RunState) {
        switch runState {
        case .idle, .stopped: self = .stopped
        case .validating, .preparing: self = .starting
        case .running: self = .running
        case .stopping: self = .stopping
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        }
    }
}

// MARK: - 更新状态（候选 → 生效）

/// 对应计划 §8.1 UpdateState。跟踪最近一张改动卡的生命周期。
enum UpdateState: Equatable, Sendable {
    /// 没有候选。
    case none
    /// 候选已通过检查，等待应用。
    case ready
    /// 正在应用（写源码事务 + 重启实例）。
    case applying
    /// 已应用并运行。
    case applied
    /// 被阻断：候选过期（项目已有新版本）或需要数据/权限确认。
    case blocked
    /// 应用失败（原版本仍可用）。
    case failed
    /// 用户放弃候选。
    case discarded
}

extension UpdateState {
    init(from cardStatus: AssistantCardStatus) {
        switch cardStatus {
        case .pending: self = .ready
        case .applying: self = .applying
        case .applied: self = .applied
        case .expired: self = .blocked
        case .applyFailed: self = .failed
        case .discarded: self = .discarded
        }
    }
}

// MARK: - 版本关系

/// 计划 §8.1 的四版本模型（P0 记录其中可从现有管线直接取得的三个）：
/// - saved：工作副本修订（文件已保存到哪一版）；
/// - running：实际运行实例对应的源码修订（AI 应用后运行；手动运行的记录属 P1）；
/// - candidateBase：待应用候选的基线修订（过期检测的依据）。
/// 生成基线版本 = 候选 baseRevision 的来源快照修订，冻结于生成开始（见审计文档 §哈希）。
struct WorkspaceVersionRelationship: Equatable, Sendable {
    var saved: ProjectRevision?
    var running: ProjectRevision?
    var candidateBase: ProjectRevision?

    /// 用户可读的一行摘要，如"文件已保存 r13 · 正在运行 r12 · 有待应用修改（基线 r12）"。
    var summary: String {
        var parts: [String] = []
        if let saved { parts.append("文件已保存 r\(saved.rawValue)") }
        if let running { parts.append("正在运行 r\(running.rawValue)") }
        if let candidateBase { parts.append("待应用修改（基线 r\(candidateBase.rawValue)）") }
        return parts.isEmpty ? "无版本记录" : parts.joined(separator: " · ")
    }
}

// MARK: - 应用记录（P3 历史与恢复）

/// 一次成功应用的 AI 变更：只含源码信息；业务数据（Data/）不进此记录。
struct AppliedChangeRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var revision: ProjectRevision
    var backend: String
    var timestamp: Date
    /// 摘要：(标识, 路径, +行, −行)。
    var files: [(String, String, Int, Int)]
    /// 受影响文件的上一版内容（恢复上一版的数据来源）。
    var previousFiles: [(FileID, String, String)]

    static func == (lhs: AppliedChangeRecord, rhs: AppliedChangeRecord) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }
}

// MARK: - 更新策略（P3，替代"修改后直接运行"单开关）

enum UpdateStrategy: String, CaseIterable, Identifiable, Sendable {
    case manual = "手动确认"
    case autoCompatible = "自动应用兼容修改"
    case paused = "暂停更新"

    var id: String { rawValue }
}
