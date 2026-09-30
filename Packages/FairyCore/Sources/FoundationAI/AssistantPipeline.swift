import Foundation
import ProjectContracts
import RuntimeContracts

// 助手改码闭环的纯逻辑（可单测）：上下文组装 → 模型 → 解析 → 内存演算 → 候选校验 → 修复回喂。
// 不依赖 SwiftUI / RunCoordinator / SwiftRuntime：校验经 `AssistantValidating` 协议抽象，
// App 层注入 coordinator 持有的引擎，单测注入假 validator；模型调用经 `perform` 闭包注入，
// 调用方（AssistantSession）把它接到 ModelBroker 的流式生成，单测接到假 driver 回放。

// MARK: - 输入输出

/// 上下文预算：不写死任何容量数字；`exceededContextWindowSize` 触发时逐级退避。
public enum ContextBudget: Sendable, Hashable, CaseIterable {
    /// 文件列表（含 hash 前缀与行数）+ 当前文件全文 + 能力摘要 + 最近诊断 + 最近 N 轮。
    case full
    /// 文件列表只留签名（path + hash 前缀）；当前文件全文保留；能力摘要截断。
    case signaturesOnly
    /// 在 signaturesOnly 基础上再去掉旧轮次。
    case noHistory

    var next: ContextBudget? {
        switch self {
        case .full: .signaturesOnly
        case .signaturesOnly: .noHistory
        case .noHistory: nil
        }
    }
}

public struct TurnMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case user, assistant }
    public var role: Role
    public var text: String
    public init(role: Role, text: String) {
        self.role = role; self.text = text
    }
}

/// 一轮请求的全部输入。`alreadyUsedRounds` / `lastErrorSignature` 用于把"最多 2 轮"计数
/// 延续到运行失败后的修复（session 在 apply+run 失败后带着新快照再次调用）。
public struct AssistantTurnInput: Sendable {
    public var userPrompt: String
    public var snapshot: ProjectSnapshot
    public var backendName: String
    public var selectedPath: String?
    public var capabilitySummary: String
    public var diagnosticsSummary: String
    public var history: [TurnMessage]
    public var budget: ContextBudget
    public var alreadyUsedRounds: Int
    public var lastErrorSignature: String?
    /// 运行失败后的修复上下文（上一轮诊断），拼在 prompt 最前。
    public var repairContext: String?

    public init(userPrompt: String, snapshot: ProjectSnapshot, backendName: String,
                selectedPath: String? = nil, capabilitySummary: String = "",
                diagnosticsSummary: String = "", history: [TurnMessage] = [],
                budget: ContextBudget = .full, alreadyUsedRounds: Int = 0,
                lastErrorSignature: String? = nil, repairContext: String? = nil) {
        self.userPrompt = userPrompt; self.snapshot = snapshot; self.backendName = backendName
        self.selectedPath = selectedPath; self.capabilitySummary = capabilitySummary
        self.diagnosticsSummary = diagnosticsSummary; self.history = history; self.budget = budget
        self.alreadyUsedRounds = alreadyUsedRounds; self.lastErrorSignature = lastErrorSignature
        self.repairContext = repairContext
    }
}

public struct PendingFileChange: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case created, replaced, renamed, deleted }
    public var path: String
    public var fileID: FileID?
    public var kind: Kind
    public var addedLines: Int
    public var removedLines: Int
    public var note: String?
    public init(path: String, fileID: FileID? = nil, kind: Kind,
                addedLines: Int, removedLines: Int, note: String? = nil) {
        self.path = path; self.fileID = fileID; self.kind = kind
        self.addedLines = addedLines; self.removedLines = removedLines; self.note = note
    }
}

/// 校验通过、待用户（或 autoRun）应用的候选变更。
public struct PendingChange: Sendable, Hashable {
    public var changeSet: FileChangeSet
    public var candidate: ProjectSnapshot
    public var files: [PendingFileChange]
    public var validation: ValidationResult
    public var repairRoundsUsed: Int
    public var lastErrorSignature: String?
    public var contextTrimmed: Bool
    public var backendName: String
    public init(changeSet: FileChangeSet, candidate: ProjectSnapshot, files: [PendingFileChange],
                validation: ValidationResult, repairRoundsUsed: Int, lastErrorSignature: String? = nil,
                contextTrimmed: Bool, backendName: String) {
        self.changeSet = changeSet; self.candidate = candidate; self.files = files
        self.validation = validation; self.repairRoundsUsed = repairRoundsUsed
        self.lastErrorSignature = lastErrorSignature; self.contextTrimmed = contextTrimmed
        self.backendName = backendName
    }
}

public enum AssistantTurnError: Error, Sendable, Hashable {
    case modelFailed(ModelTaskFailure)
    case parseFailed(String)
    case previewFailed(String)
    case repairExhausted(String)
    case contextOverflow
    /// 自动续写后输出仍不完整（端上模型上下文太小，装不下完整改码输出）。
    case outputTruncated

    public var userMessage: String {
        switch self {
        case let .modelFailed(f): f.userMessage
        case let .parseFailed(d): "没能理解模型的修改：\(d)"
        case let .previewFailed(d): d
        case let .repairExhausted(d): "自动修复已用完 2 轮，剩余问题：\(d)"
        case .contextOverflow: "项目内容或所需输出超出端上模型上下文（指令、提示与输出共享约 4K tokens），自动裁剪后仍放不下；请把需求拆小：一次只改一个文件，或分几条消息逐步提出"
        case .outputTruncated: "模型输出被端上模型上下文上限截断，自动续写后仍不完整。请把需求拆小：一次只改一个文件，或分几条消息逐步提出"
        }
    }
}

public enum AssistantTurnResult: Sendable {
    /// 校验通过的候选变更（走变更卡片）。
    case proposed(PendingChange)
    /// 模型纯文本回答（无 JSON 块，不建卡片）。
    case noChange(String)
    case failed(AssistantTurnError)
}

public struct AssistantTurnOutcome: Sendable {
    public var result: AssistantTurnResult
    /// 本轮是否裁剪过上下文（UI 显示"已裁剪上下文"）。
    public var contextTrimmed: Bool
    /// 模型回复尾部：供会话侧识别 [[MORE]] 续作标记（多文件任务分批完成）。
    public var modelTail: String
    public init(result: AssistantTurnResult, contextTrimmed: Bool, modelTail: String = "") {
        self.result = result; self.contextTrimmed = contextTrimmed; self.modelTail = modelTail
    }
}

/// 候选程序校验抽象：App 层注入 coordinator 持有的引擎；FoundationAI 不依赖 SwiftRuntime。
public protocol AssistantValidating: Sendable {
    func validate(_ program: ProgramSource) async -> ValidationResult
}

// MARK: - Pipeline

public struct AssistantPipeline: Sendable {
    public var historyLimit: Int
    public var capabilityLineLimit: Int
    /// 输出被截断时的最大自动续写轮数（每次续写都是一次新模型调用）。
    public var maxContinuations: Int

    public init(historyLimit: Int = 6, capabilityLineLimit: Int = 32, maxContinuations: Int = 2) {
        self.historyLimit = historyLimit; self.capabilityLineLimit = capabilityLineLimit
        self.maxContinuations = maxContinuations
    }

    /// 管线阶段事件：供 UI 状态契约（GenerationState）观察，不伪造进度。
    public enum Phase: Sendable, Equatable {
        case awaitingModel      // 即将调用模型
        case modelComplete      // 模型输出已完整接收
        case candidateReady     // 候选通过校验
    }

    /// perform：prompt → 模型全文；抛 `ModelTaskFailure`（含 exceededContextWindowSize）或 CancellationError。
    /// 用户取消（Task 取消）以 throw 形式上抛，调用方不得落盘。
    public func runTurn(_ input: AssistantTurnInput,
                        perform: @Sendable (String) async throws -> String,
                        validator: any AssistantValidating,
                        onPhase: (@Sendable (Phase) -> Void)? = nil) async throws -> AssistantTurnOutcome {
        var budget = input.budget
        var trimmed = false
        var outputWarning: String?
        var tracker = RepairTracker(usedRounds: input.alreadyUsedRounds, lastSignature: input.lastErrorSignature)
        var history = Array(input.history.suffix(historyLimit))
        var repairSection = input.repairContext

        while true {
            onPhase?(.awaitingModel)
            let prompt = AssistantPromptBuilder.build(input, budget: budget, history: history,
                                                      repairSection: repairSection,
                                                      capabilityLineLimit: capabilityLineLimit,
                                                      outputWarning: outputWarning)
            let generated: (text: String, truncated: Bool)
            do {
                generated = try await Self.generateComplete(prompt, perform: perform,
                                                            maxContinuations: maxContinuations)
                // 迟到结果直接丢弃：调用方取消后不再做解析/演算/校验，更不落盘。
                try Task.checkCancellation()
            } catch let failure as ModelTaskFailure where failure.isContextOverflow {
                // 预算退避：先缩短文件摘要（只留签名），再去掉旧轮次；同时要求模型精简输出——
                // 上下文是输入与输出共享的，光缩输入不一定救得回长输出。
                if let next = budget.next {
                    budget = next
                    trimmed = true
                    outputWarning = "上一次输出超出上下文上限。只改一个文件，输出最短必要的 JSON；改动大就本轮先做第一步。"
                    continue
                }
                return AssistantTurnOutcome(result: .failed(.contextOverflow), contextTrimmed: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ModelTaskFailure {
                return AssistantTurnOutcome(result: .failed(.modelFailed(failure)), contextTrimmed: trimmed)
            } catch {
                return AssistantTurnOutcome(result: .failed(.modelFailed(.systemError(String(describing: error)))),
                                            contextTrimmed: trimmed)
            }
            let text = generated.text
            onPhase?(.modelComplete)

            // 续写后仍不完整：明确报"输出被截断"，不误走纯文本 / 解析失败路径。
            if generated.truncated {
                return AssistantTurnOutcome(result: .failed(.outputTruncated), contextTrimmed: trimmed)
            }

            let proposed: ProposedChangeSet
            do {
                proposed = try ProposeChangesTool.parse(from: text)
            } catch is ProposeChangesTool.NoBlockFound {
                return AssistantTurnOutcome(result: .noChange(text), contextTrimmed: trimmed,
                                            modelTail: Self.moreMarkerTail(of: text))
            } catch let turnError as AssistantTurnError {
                return AssistantTurnOutcome(result: .failed(turnError), contextTrimmed: trimmed)
            } catch {
                return AssistantTurnOutcome(result: .failed(.parseFailed(String(describing: error))),
                                            contextTrimmed: trimmed)
            }

            let changeSet: FileChangeSet
            do {
                changeSet = try ProposeChangesTool.buildChangeSet(
                    from: proposed, base: input.snapshot, backendName: input.backendName,
                    summary: "AI（\(input.backendName)）：\(String(input.userPrompt.prefix(60)))")
            } catch let proposal as AssistantProposalError {
                return AssistantTurnOutcome(result: .failed(.parseFailed(proposal.userMessage)),
                                            contextTrimmed: trimmed)
            }

            let candidate: ProjectSnapshot
            do {
                candidate = try ChangeSetPreview.apply(changeSet, to: input.snapshot)
            } catch let preview as ChangeSetError {
                return AssistantTurnOutcome(result: .failed(.previewFailed(Self.previewMessage(preview))),
                                            contextTrimmed: trimmed)
            } catch {
                return AssistantTurnOutcome(result: .failed(.previewFailed(String(describing: error))),
                                            contextTrimmed: trimmed)
            }

            let validation = await validator.validate(candidate.program)
            let hasErrors = validation.diagnostics.contains { $0.severity == .error }
            if !hasErrors {
                onPhase?(.candidateReady)
                let files = Self.fileChanges(proposed: proposed, changeSet: changeSet,
                                             base: input.snapshot, candidate: candidate)
                let pending = PendingChange(changeSet: changeSet, candidate: candidate, files: files,
                                            validation: validation, repairRoundsUsed: tracker.usedRounds,
                                            lastErrorSignature: tracker.lastSignature,
                                            contextTrimmed: trimmed, backendName: input.backendName)
                return AssistantTurnOutcome(result: .proposed(pending), contextTrimmed: trimmed,
                                            modelTail: Self.moreMarkerTail(of: text))
            }
            let signature = AssistantRepair.signature(of: validation.diagnostics)
            guard tracker.shouldRepair(signature: signature) else {
                let remaining = validation.diagnostics
                    .filter { $0.severity == .error }
                    .map { "[\($0.kind.rawValue)] \($0.message)" }
                    .joined(separator: "\n")
                return AssistantTurnOutcome(result: .failed(.repairExhausted(remaining)),
                                            contextTrimmed: trimmed)
            }
            repairSection = Self.repairPrompt(diagnostics: validation.diagnostics, round: tracker.usedRounds)
            history.append(TurnMessage(role: .assistant, text: String(text.prefix(1000))))
            history = Array(history.suffix(historyLimit))
        }
    }

    // MARK: - 内部

    /// 续作标记：多文件任务分批完成时，模型在回复结尾输出 [[MORE]] 表示"还有下一批"。
    public static let moreMarker = "[[MORE]]"

    static func moreMarkerTail(of text: String) -> String {
        String(text.suffix(300))
    }

    /// 生成 + 截断续写：端上模型上下文（指令 + 提示 + 输出共享，约 4K）装不下完整改码输出时，
    /// 回复会在 JSON 中途断掉；检测到截断就带着已输出全文再调一次模型，把剩余部分续上。
    /// 最多 `maxContinuations` 轮，每轮必须有新增内容（无进展即停）。
    /// 返回 `truncated`：循环结束时输出仍不完整（围栏未闭合 / 裸 JSON 不合法），调用方据此报 `outputTruncated`，
    /// 不应再走解析路径——为可解析性收尾补了闭合围栏，但 JSON 本身不保证完整。
    static func generateComplete(_ prompt: String,
                                 perform: @Sendable (String) async throws -> String,
                                 maxContinuations: Int) async throws -> (text: String, truncated: Bool) {
        var text = try await perform(prompt)
        try Task.checkCancellation()
        var rounds = 0
        while looksTruncated(text), rounds < maxContinuations {
            rounds += 1
            let piece = try await perform(continuationPrompt(text))
            try Task.checkCancellation()
            let merged = mergeContinuation(into: text, piece: piece)
            if merged == text { break }
            text = merged
        }
        return (text, looksTruncated(text))
    }

    /// 输出是否疑似不完整：
    /// - 裸 `{` 开头：JSON 不合法即截断；
    /// - 有 ```json 块：闭合块看块内 JSON 能否解析；未闭合块取 "```json" 之后到末尾尝试解析，
    ///   内容完整（只缺闭合围栏）不算截断。
    /// 注意用 JSONSerialization 而非 Decodable：字段名错误等 schema 问题是 parseFailed，不是截断。
    static func looksTruncated(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) == nil
        }
        guard text.contains("```json") else { return false }
        if let block = ProposeChangesTool.extractJSONBlock(from: text) {
            return (try? JSONSerialization.jsonObject(with: Data(block.utf8))) == nil
        }
        guard let start = text.range(of: "```json") else { return false }
        let body = String(text[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) == nil
    }

    /// 续写提示。每次请求都是全新会话（模型无记忆），必须自带被截断的全文，
    /// 并严格约束"只补缺失部分"，否则模型重开或加说明都会污染合并结果。
    static func continuationPrompt(_ text: String) -> String {
        """
        你上一条回复在输出途中被上下文上限截断，以下是已输出的全部内容：

        \(text)

        请只续写缺失的剩余部分，从上面内容的结尾直接接着输出：不要重复任何已有内容、\
        不要重新开始、不要任何说明文字、不要输出 ``` 围栏。如果是 JSON，直接续写剩余的字段与元素，\
        直到 JSON 完整结束。
        """
    }

    /// 合并续写片段：剥掉片段自带的围栏行与首尾空白后直接拼接（不加分隔符——
    /// 截断常发生在 JSON 字符串内部，任何插入字符都会破坏 JSON），再按需补闭合围栏。
    static func mergeContinuation(into text: String, piece: String) -> String {
        let cleaned = piece
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        var merged = text + cleaned
        let fenceCount = merged.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 { merged += "\n```" }
        return merged
    }

    static func previewMessage(_ error: ChangeSetError) -> String {
        switch error {
        case .hashMismatch, .revisionMismatch:
            return "补丁基于旧版本，已被拒绝（\(String(describing: error))）；请重新读取项目后重试。"
        case let .fileNotFound(id): return "补丁引用的文件不存在：\(id)"
        case let .pathConflict(p): return "路径冲突：\(p)"
        case let .invalidPath(p): return "非法路径：\(p)"
        case let .limitExceeded(d): return "超出工程上限：\(d)"
        case let .alreadyApplied(id): return "该变更已应用（\(id)）"
        case let .storage(d): return "存储失败：\(d)"
        }
    }

    static func repairPrompt(diagnostics: [Diagnostic], round: Int) -> String {
        let lines = diagnostics.map { "- [\($0.severity)] \($0.kind.rawValue)：\($0.message)" }.joined(separator: "\n")
        return "上一轮修改校验未通过（第 \(round) 轮修复），诊断如下，请针对性修正后重新输出完整 FileChangeSet JSON：\n\(lines)"
    }

    static func fileChanges(proposed: ProposedChangeSet, changeSet: FileChangeSet,
                            base: ProjectSnapshot, candidate: ProjectSnapshot) -> [PendingFileChange] {
        zip(proposed.operations, changeSet.operations).map { prop, op in
            switch op {
            case let .create(path, contents):
                return PendingFileChange(path: path, kind: .created,
                                         addedLines: lineCount(contents), removedLines: 0, note: prop.note)
            case let .replace(fileID, _, _):
                let old = base.file(id: fileID)?.contents ?? ""
                let new = candidate.file(id: fileID)?.contents ?? ""
                let (added, removed) = AssistantDiff.stat(old: old, new: new)
                let path = candidate.file(id: fileID)?.path ?? base.file(id: fileID)?.path ?? fileID.rawValue
                return PendingFileChange(path: path, fileID: fileID, kind: .replaced,
                                         addedLines: added, removedLines: removed, note: prop.note)
            case let .rename(fileID, _, newPath):
                return PendingFileChange(path: newPath, fileID: fileID, kind: .renamed,
                                         addedLines: 0, removedLines: 0, note: prop.note)
            case let .delete(fileID, _):
                let old = base.file(id: fileID)?.contents ?? ""
                let path = base.file(id: fileID)?.path ?? fileID.rawValue
                return PendingFileChange(path: path, fileID: fileID, kind: .deleted,
                                         addedLines: 0, removedLines: lineCount(old), note: prop.note)
            }
        }
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }
}

// MARK: - 行级 diff 统计（前后公共行裁掉，中间计 +/−）

public enum AssistantDiff {
    public static func stat(old: String, new: String) -> (added: Int, removed: Int) {
        if old == new { return (0, 0) }
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        return (b.count - pre - suf, a.count - pre - suf)
    }
}

// MARK: - Prompt 组装

public enum AssistantPromptBuilder {
    public static func build(_ input: AssistantTurnInput, budget: ContextBudget, history: [TurnMessage],
                             repairSection: String?, capabilityLineLimit: Int,
                             outputWarning: String? = nil) -> String {
        var parts: [String] = []
        parts.append("""
            你是 FairyStudio（iOS 本地 SwiftUI 运行环境）的编程助手。只改必要文件；用 fileID 标识既有文件。
            端上模型上下文只有约 4K tokens（你看到的全部内容与你的输出共享），因此：输出尽量短，\
            不加注释与空行，不复述未修改的代码；新建项目时最小可运行优先，每个文件 ≤ 50 行。
            多文件任务分批进行：本轮提交一部分，若还有下一批，在回复最末尾单独输出标记 [[MORE]]；\
            全部完成后不要再输出该标记（收到"继续"时接着做下一批，不要重复已完成的内容）。
            回复格式：先用一句话说明改了什么，然后输出一个 ```json 代码块，内容为 {"operations":[...]}；\
            每项含 action（create|replace|rename|delete）、fileID 或 path、预计新内容 contents（create/replace 必填）、\
            newPath（rename 必填）、note（一句话说明）。expectedBaseHash 可省略（由工具侧自动填入读取时哈希）。
            只使用能力目录中 supported / partial 的能力；unsupported 会导致校验失败。
            若无需改码，直接纯文本回答，不要输出 JSON。
            """)
        if let outputWarning, !outputWarning.isEmpty {
            parts.append("## 输出约束\n\(outputWarning)")
        }
        if let repairSection, !repairSection.isEmpty {
            parts.append("## 待修复的诊断\n\(repairSection)")
        }
        parts.append("## 用户需求\n\(input.userPrompt)")
        parts.append("## 项目文件（\(input.snapshot.files.count) 个，修订 \(input.snapshot.revision)）\n" +
            ListFilesTool.output(for: input.snapshot, signaturesOnly: budget != .full))
        if let path = input.selectedPath,
           let read = ReadFileTool.read(input.snapshot, path: path) {
            parts.append("## 当前打开文件 \(path)（hash \(read.file.hash)）全文\n\(read.excerpt)")
        }
        let capLines = input.capabilitySummary.components(separatedBy: "\n")
        let capLimit = budget == .full ? capabilityLineLimit : min(20, capabilityLineLimit)
        parts.append("## 能力目录摘要\n" + capLines.prefix(capLimit).joined(separator: "\n"))
        if !input.diagnosticsSummary.isEmpty {
            if budget == .noHistory {
                // 最低预算下诊断只留错误行。
                let errLines = input.diagnosticsSummary.components(separatedBy: "\n").filter {
                    $0.contains("[error]")
                }
                parts.append("## 最近诊断（仅错误）\n" + (errLines.isEmpty ? "无错误" : errLines.joined(separator: "\n")))
            } else {
                parts.append("## 最近诊断\n\(input.diagnosticsSummary)")
            }
        }
        if budget != .noHistory, !history.isEmpty {
            let turns = history.map { $0.role == .user ? "用户：\($0.text)" : "助手：\($0.text)" }
                .joined(separator: "\n")
            parts.append("## 最近对话\n\(turns)")
        }
        return parts.joined(separator: "\n\n")
    }
}

extension ModelTaskFailure {
    var isContextOverflow: Bool {
        if case .exceededContextWindowSize = self { return true }
        return false
    }
}
