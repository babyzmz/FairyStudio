import Foundation
import FoundationModels
import Synchronization
import FoundationAI
import ProjectContracts
import RuntimeContracts
import SwiftRuntime

// 真实 agent 能力（W2 交接时列入 M3，按用户反馈提前）：设备端会话挂接 FoundationModels
// Tool 循环。模型经 listFiles / readFile / readCapability / readDiagnostics 了解项目，
// 经 proposeChanges 提交结构化文件操作——可多次调用（建议每个文件一次），单次调用很小，
// 天然绕开"整包变更装不进 4K 输出"的问题。累加的操作序列化成 ```json 块回灌
// AssistantPipeline：解析 / 预览 / 校验 / 修复回喂 / 变更卡片全部复用既有闭环。
// 云端后端与单测仍走纯文本路径（broker），不依赖本文件。

// MARK: - 会话侧抽象（可注入假件）

/// 一次 agent 回合的输入：会话已算好的项目上下文（与纯文本路径同一来源）。
struct AgentTurnContext: Sendable {
    let snapshot: ProjectSnapshot
    let catalogEntries: [CapabilityEntry]
    let diagnosticsSummary: String
}

/// agent 回合输出。
struct AgentTurnOutput: Sendable {
    var finalText: String
    /// proposeChanges 工具累计提交的操作。
    var proposedOperations: [ProposedOperation]

    /// 供 pipeline 消费的文本：有操作时序列化成 ```json 块，下游解析/预览/校验不变；
    /// 无操作时就是最终纯文本（pipeline 走 noChange，不建卡）。
    var pipelineText: String {
        guard !proposedOperations.isEmpty else { return finalText }
        let intro = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try JSONEncoder().encode(ProposedChangeSet(operations: proposedOperations))
            let json = String(data: data, encoding: .utf8) ?? "{\"operations\":[]}"
            return "\(intro.isEmpty ? "已通过工具提交文件修改。" : intro)\n```json\n\(json)\n```"
        } catch {
            return intro
        }
    }
}

/// agent 执行器。生产实现 `FoundationModelsAgentRunner`；单测注入假件。
protocol AgentPerforming: Sendable {
    func run(prompt: String, context: AgentTurnContext,
             onEvent: @escaping @Sendable (String) async -> Void) async throws -> AgentTurnOutput
}

// MARK: - 工具参数（@Generable 自动生成 schema）
//
// 注意：`ProposedOperation` 的 `@Generable` 在包内被 `!SWIFT_PACKAGE` 条件挡住
// （Xcode 集成构建的 SwiftPM 包同样定义 SWIFT_PACKAGE，宏从未展开），
// 因此工具参数用本文件的镜像类型，提交后转回 `ProposedOperation`。

/// AgentFileOperation → ProposedOperation（字段一一对应）。
private extension ProposedOperation {
    init(_ op: AgentFileOperation) {
        self.init(action: op.action, fileID: op.fileID, path: op.path,
                  expectedBaseHash: op.expectedBaseHash, contents: op.contents,
                  newPath: op.newPath, note: op.note)
    }
}

@Generable
struct AgentFileOperation {
    @Guide(description: "操作类型：create|replace|rename|delete")
    var action: String
    /// 既有文件用 fileID（listFiles 给出），新建文件用 path。
    var fileID: String?
    var path: String?
    /// 可省略，工具侧自动填入读取时哈希。
    var expectedBaseHash: String?
    /// create / replace 的完整文件内容。
    var contents: String?
    /// rename 的新路径。
    var newPath: String?
    /// 给用户看的一句话说明。
    var note: String?
}

@Generable
struct AgentReadFileArguments {
    @Guide(description: "要读取的文件路径，如 Sources/ContentView.swift")
    var path: String
}

@Generable
struct AgentReadCapabilityArguments {
    @Guide(description: "能力关键词，如 Text、Slider、String；留空查看全部摘要")
    var query: String
}

@Generable
struct AgentReadDiagnosticsArguments {
    @Guide(description: "留空即可")
    var section: String?
}

@Generable
struct AgentProposeChangesArguments {
    @Guide(description: "本轮要提交的文件操作；每个文件一条，create/replace 的 contents 必须是完整文件内容")
    var operations: [AgentFileOperation]
}

@Generable
struct AgentListFilesArguments {
    @Guide(description: "可选：只列出路径包含此前缀的文件，留空列出全部")
    var prefix: String?
}

// MARK: - 工具实现（数据来自会话侧上下文，不自行持有存储）

private struct ListFilesAgentTool: Tool {
    let snapshot: ProjectSnapshot
    let name = "listFiles"
    let description = "列出项目全部文件：路径、fileID、内容哈希前缀与行数。"
    typealias Arguments = AgentListFilesArguments

    func call(arguments: Arguments) async throws -> String {
        let output = ListFilesTool.output(for: snapshot)
        guard let prefix = arguments.prefix?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prefix.isEmpty else { return output }
        let lines = output.components(separatedBy: "\n").filter { $0.contains(prefix) }
        return lines.isEmpty ? "没有匹配前缀 \"\(prefix)\" 的文件。" : lines.joined(separator: "\n")
    }
}

private struct ReadFileAgentTool: Tool {
    let snapshot: ProjectSnapshot
    let name = "readFile"
    let description = "读取一个文件的完整内容。"
    typealias Arguments = AgentReadFileArguments

    func call(arguments: Arguments) async throws -> String {
        guard let read = ReadFileTool.read(snapshot, path: arguments.path) else {
            return "找不到文件：\(arguments.path)。用 listFiles 查看现有文件。"
        }
        return "path=\(read.file.path)\n\(read.excerpt)"
    }
}

private struct ReadCapabilityAgentTool: Tool {
    let entries: [CapabilityEntry]
    let name = "readCapability"
    let description = "查询 Swift/SwiftUI 运行环境支持的能力；生成的代码只能使用 supported / partial 条目。"
    typealias Arguments = AgentReadCapabilityArguments

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.id.lowercased().contains(query)
                || $0.displayName.lowercased().contains(query)
                || $0.category.rawValue.lowercased().contains(query)
        }
        guard !filtered.isEmpty else {
            return "没有匹配 \"\(arguments.query)\" 的能力条目；该能力很可能不受支持，请换用目录内能力。"
        }
        return ReadCapabilityTool.summary(entries: filtered, lineLimit: 40)
    }
}

private struct ReadDiagnosticsAgentTool: Tool {
    let diagnosticsSummary: String
    let name = "readDiagnostics"
    let description = "查看最近一次运行的诊断与控制台输出。"
    typealias Arguments = AgentReadDiagnosticsArguments

    func call(arguments: Arguments) async throws -> String {
        diagnosticsSummary.isEmpty ? "还没有运行记录。" : diagnosticsSummary
    }
}

/// proposeChanges 的跨调用累加器（一次 run 内共享，run 结束即弃）。
final class ProposedOperationsAccumulator: Sendable {
    private let operations = Mutex<[AgentFileOperation]>([])

    var all: [ProposedOperation] {
        operations.withLock { $0 }.map(ProposedOperation.init)
    }

    func append(_ new: [AgentFileOperation]) -> Int {
        operations.withLock { ops in
            ops.append(contentsOf: new)
            return ops.count
        }
    }
}

private struct ProposeChangesAgentTool: Tool {
    let accumulator: ProposedOperationsAccumulator
    let onEvent: @Sendable (String) async -> Void
    let name = "proposeChanges"
    let description = """
        提交结构化文件操作，可多次调用（建议每个文件一次）。action 取 create|replace|rename|delete；\
        create/replace 必须给完整 contents；expectedBaseHash 可省略。
        """
    typealias Arguments = AgentProposeChangesArguments

    func call(arguments: Arguments) async throws -> String {
        guard !arguments.operations.isEmpty else {
            return "operations 为空，没有提交任何操作。"
        }
        let total = accumulator.append(arguments.operations)
        let paths = arguments.operations.compactMap { $0.path ?? $0.fileID }.joined(separator: ", ")
        let note = "已提交 \(arguments.operations.count) 个操作（累计 \(total)）：\(paths)"
        await onEvent(note)
        return "\(note)。全部文件提交完成后即可给出总结。"
    }
}

// MARK: - 生产实现

/// FoundationModels 工具循环执行器。无状态：每次 run 新建会话与累加器。
struct FoundationModelsAgentRunner: AgentPerforming {
    static let instructions = """
        你是 FairyStudio（iOS 本地 SwiftUI 运行环境）的编程助手，通过工具了解项目并提交修改：
        - 先用 listFiles 看文件列表，用 readFile 读取相关文件内容；
        - 只使用 readCapability 中 supported / partial 的能力，unsupported 会导致校验失败；
        - 用 proposeChanges 提交修改：可多次调用，每个文件一次，contents 必须完整；\
        输出尽量短，不加注释与空行；新建项目最小可运行，每个文件 ≤ 50 行；
        - 从零创建类需求：先规划文件清单（模型 / 视图 / 入口），逐个文件提交；本轮未全部完成时\
        在总结最末尾单独输出标记 [[MORE]]（会自动收到"继续"），全部完成则不要输出；\
        收到"继续"时接着做下一批，不要重复已完成的内容；
        - 全部提交完成后，用一两句话总结你做了什么。不要在回复里输出 JSON。
        """

    func run(prompt: String, context: AgentTurnContext,
             onEvent: @escaping @Sendable (String) async -> Void) async throws -> AgentTurnOutput {
        // 与 broker 文本路径同一口径：每个任务开始时实时检测可用性。
        let availability = await OnDeviceModelDriver().checkAvailability()
        guard availability.isAvailable else {
            throw ModelTaskFailure.unavailable(availability)
        }
        let (session, accumulator) = Self.makeSession(context: context, onEvent: onEvent)
        // 输出上限 = 上下文上限（同文本路径口径，见 docs/APPLE_MODELS.md §9）。
        let options = GenerationOptions(maximumResponseTokens: SystemLanguageModel.default.contextSize)
        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(to: prompt, options: options)
        } catch let error as LanguageModelSession.GenerationError {
            throw FoundationModelsBridge.failure(for: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // iOS 27：上下文超限从 LanguageModelError.contextSizeExceeded 抛出，
            // 必须映射进退避链路（否则退避不触发，用户直接看到系统错误）。
            if #available(iOS 27.0, *), let modelError = error as? LanguageModelError {
                throw FoundationModelsBridge.failure(for: modelError)
            }
            throw ModelTaskFailure.systemError(String(describing: error))
        }
        return AgentTurnOutput(finalText: response.content, proposedOperations: accumulator.all)
    }

    /// 会话构造（含全部工具 schema）。不依赖模型可用性，可单测：
    /// schema 非法会在构造时暴露，而不是留到设备端工具循环里崩。
    static func makeSession(context: AgentTurnContext,
                            onEvent: @escaping @Sendable (String) async -> Void)
        -> (session: LanguageModelSession, accumulator: ProposedOperationsAccumulator) {
        let accumulator = ProposedOperationsAccumulator()
        let session = LanguageModelSession(
            tools: [
                ListFilesAgentTool(snapshot: context.snapshot),
                ReadFileAgentTool(snapshot: context.snapshot),
                ReadCapabilityAgentTool(entries: context.catalogEntries),
                ReadDiagnosticsAgentTool(diagnosticsSummary: context.diagnosticsSummary),
                ProposeChangesAgentTool(accumulator: accumulator, onEvent: onEvent),
            ],
            instructions: Self.instructions)
        return (session, accumulator)
    }
}
