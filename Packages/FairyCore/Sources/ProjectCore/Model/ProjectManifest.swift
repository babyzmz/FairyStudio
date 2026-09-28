import Foundation
import RuntimeContracts
import ProjectContracts

/// `.mojoproject/project.json`：项目清单。字段含义见 docs/PROJECT_FORMAT.md。
/// 清单同时保存文件表（fileID ↔ 路径）与修订号；文件内容只保存在各自的文件里。
public struct ProjectManifest: Codable, Sendable, Hashable {
    /// 清单格式版本。读取到更高版本时拒绝打开（不猜测未知字段语义）。
    public static let currentSchemaVersion = 1
    /// v1 语言配置：SwiftRuntime 支持的 Swift/SwiftUI 子集。
    public static let defaultLanguageProfile = "swift-subset-v1"
    /// 幂等去重保留的最近 ChangeSet ID 数。
    public static let appliedChangeSetLimit = 500

    public var schemaVersion: Int
    public var projectID: ProjectID
    public var displayName: String
    /// 创建/最后迁移时所用的运行时语义版本（"主.次.修订"）。
    public var runtimeVersion: String
    public var languageProfile: String
    public var moduleName: String
    public var entryKind: ProjectEntryKind
    /// 脚本入口：顶层代码文件（main.swift）的项目相对路径（与 entrySymbol 互斥）。
    public var entryFile: String?
    /// 根视图入口：根 View 类型名（与 entryFile 互斥）。两者都为空表示 `@main App` 入口。
    public var entrySymbol: String?
    public var sourceRoots: [String]
    public var resourceRoots: [String]
    /// 业务数据（Data/）的 schema 版本；0 表示尚无数据模型。
    public var dataSchemaVersion: Int
    /// 项目声明需要的宿主能力（capability catalog ID），供权限预检。
    public var requestedCapabilities: [String]
    /// 从模板创建时的模板 ID。
    public var templateID: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var revision: ProjectRevision
    /// 文件表：稳定 fileID ↔ 项目相对路径。改名只改路径，不改 fileID。
    public var files: [FileRecord]
    /// 最近提交过的 ChangeSet ID（幂等去重）。
    public var appliedChangeSets: [UUID]

    public struct FileRecord: Codable, Sendable, Hashable {
        public var id: FileID
        public var path: String
        public init(id: FileID, path: String) { self.id = id; self.path = path }
    }

    public init(projectID: ProjectID = ProjectID(), displayName: String, runtimeVersion: String, moduleName: String,
                entryKind: ProjectEntryKind = .nativeSwift, entryFile: String? = nil, entrySymbol: String? = "ContentView",
                templateID: String? = nil, requestedCapabilities: [String] = [], dataSchemaVersion: Int = 0,
                createdAt: Date = Date(), files: [FileRecord] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projectID = projectID
        self.displayName = displayName
        self.runtimeVersion = runtimeVersion
        self.languageProfile = Self.defaultLanguageProfile
        self.moduleName = moduleName
        self.entryKind = entryKind
        self.entryFile = entryFile
        self.entrySymbol = entrySymbol
        self.sourceRoots = [ProjectLayout.sources]
        self.resourceRoots = [ProjectLayout.resources]
        self.dataSchemaVersion = dataSchemaVersion
        self.requestedCapabilities = requestedCapabilities
        self.templateID = templateID
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.revision = ProjectRevision(0)
        self.files = files
        self.appliedChangeSets = []
    }

    /// 交给运行时的入口。entryFile 按路径找到当前 fileID（改名时清单同步更新路径）。
    public var entryPoint: EntryPoint {
        if let entryFile, let record = files.first(where: { $0.path == entryFile }) {
            return .script(record.id)
        }
        if let entrySymbol, !entrySymbol.isEmpty { return .rootView(symbol: entrySymbol) }
        return .mainApp
    }

    /// 入口的可读说明（作品卡与工作区显示）。
    public var entryDescription: String {
        switch entryPoint {
        case .script: "脚本 \((entryFile.map { ($0 as NSString).lastPathComponent }) ?? "main.swift")"
        case let .rootView(symbol): "根视图 \(symbol)"
        case .mainApp: "@main App"
        }
    }

    public var parsedRuntimeVersion: RuntimeVersion? { RuntimeVersion(parsing: runtimeVersion) }

    // 解码时对可选字段宽容；schemaVersion / projectID / 文件表必须存在。
    enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, displayName, runtimeVersion, languageProfile, moduleName, entryKind, entryFile, entrySymbol
        case sourceRoots, resourceRoots, dataSchemaVersion, requestedCapabilities, templateID, createdAt, modifiedAt, revision
        case files, appliedChangeSets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        projectID = try c.decode(ProjectID.self, forKey: .projectID)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "未命名作品"
        runtimeVersion = try c.decodeIfPresent(String.self, forKey: .runtimeVersion) ?? "0.0.0"
        languageProfile = try c.decodeIfPresent(String.self, forKey: .languageProfile) ?? Self.defaultLanguageProfile
        moduleName = try c.decodeIfPresent(String.self, forKey: .moduleName) ?? "App"
        entryKind = try c.decodeIfPresent(ProjectEntryKind.self, forKey: .entryKind) ?? .nativeSwift
        entryFile = try c.decodeIfPresent(String.self, forKey: .entryFile)
        entrySymbol = try c.decodeIfPresent(String.self, forKey: .entrySymbol)
        sourceRoots = try c.decodeIfPresent([String].self, forKey: .sourceRoots) ?? [ProjectLayout.sources]
        resourceRoots = try c.decodeIfPresent([String].self, forKey: .resourceRoots) ?? [ProjectLayout.resources]
        dataSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .dataSchemaVersion) ?? 0
        requestedCapabilities = try c.decodeIfPresent([String].self, forKey: .requestedCapabilities) ?? []
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        revision = try c.decodeIfPresent(ProjectRevision.self, forKey: .revision) ?? ProjectRevision(0)
        files = try c.decode([FileRecord].self, forKey: .files)
        appliedChangeSets = try c.decodeIfPresent([UUID].self, forKey: .appliedChangeSets) ?? []
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProjectManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ProjectManifest.self, from: data)
    }
}

extension RuntimeVersion {
    /// 解析 "主.次.修订"；格式不对返回 nil。
    public init?(parsing text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else { return nil }
        self.init(a, b, c)
    }
}

/// 模块名：只保留 ASCII 字母、数字与下划线，首字符不能是数字；为空时用 "App"。
public enum ModuleNaming {
    public static func moduleName(for displayName: String) -> String {
        var result = ""
        for scalar in displayName.unicodeScalars where scalar.isASCII {
            let v = scalar.value
            let isLetter = (65...90).contains(v) || (97...122).contains(v)
            let isDigit = (48...57).contains(v)
            if isLetter || isDigit || v == 95 { result.unicodeScalars.append(scalar) }
        }
        if let first = result.unicodeScalars.first, (48...57).contains(first.value) { result = "_" + result }
        return result.isEmpty ? "App" : result
    }
}
