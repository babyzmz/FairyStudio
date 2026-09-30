import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import ProjectContracts
import RuntimeContracts

// 模型输出的变更提议：约束模型只输出结构化的文件操作数组。
//
// 说明：
// - Xcode iOS 构建（非 SPM）且有 FoundationModels SDK 时（Xcode 27 SDK 已核实含 `@Generable`，
//   见 docs/APPLE_MODELS.md），本结构带 `@Generable`，可直接用于约束生成；
// - SPM 构建（含 macOS 单测，部署目标 macOS 15 而 `@Generable` 要求 macOS 26+）退化为纯
//   Codable，供假 driver 回放与 JSON 解析单测。条件用 `SWIFT_PACKAGE`（SPM 专有定义）区分，
//   不用 SDK 版本猜测。
#if canImport(FoundationModels) && !SWIFT_PACKAGE
@Generable
#endif
public struct ProposedChangeSet: Sendable, Hashable, Codable {
    public var operations: [ProposedOperation]

    public init(operations: [ProposedOperation]) {
        self.operations = operations
    }
}

#if canImport(FoundationModels) && !SWIFT_PACKAGE
@Generable
#endif
public struct ProposedOperation: Sendable, Hashable, Codable {
    /// create | replace | rename | delete。
    public var action: String
    /// 目标文件：优先 fileID（改名不变），其次 path（相对项目，如 Sources/ContentView.swift）。
    public var fileID: String?
    public var path: String?
    /// 模型可省略；组装提交时由工具侧自动填入读取时的哈希。
    public var expectedBaseHash: String?
    /// create / replace 的新内容。
    public var contents: String?
    /// rename 的新路径。
    public var newPath: String?
    /// 给用户看的一句话说明。
    public var note: String?

    public init(action: String, fileID: String? = nil, path: String? = nil,
                expectedBaseHash: String? = nil, contents: String? = nil,
                newPath: String? = nil, note: String? = nil) {
        self.action = action
        self.fileID = fileID
        self.path = path
        self.expectedBaseHash = expectedBaseHash
        self.contents = contents
        self.newPath = newPath
        self.note = note
    }
}

/// 提议组装失败（模型输出缺字段 / 指的文件不存在）。
public enum AssistantProposalError: Error, Sendable, Hashable {
    case unknownAction(String)
    case unknownFile(String)
    case missingContents(String)
    case missingPath(String)
    case missingNewPath(String)
    case emptyOperations

    public var userMessage: String {
        switch self {
        case let .unknownAction(a): "模型输出了未知操作：\(a)"
        case let .unknownFile(f): "模型引用的文件不存在：\(f)"
        case let .missingContents(f): "缺少新文件内容：\(f)"
        case let .missingPath(a): "缺少路径：\(a)"
        case let .missingNewPath(f): "缺少新路径：\(f)"
        case .emptyOperations: "模型没有提出任何文件修改"
        }
    }
}
