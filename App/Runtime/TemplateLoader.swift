import Foundation
import RuntimeContracts

/// TemplateLibrary 雏形：从 App 包内 `Templates/<id>/template.json` 读取模板的入口与文件清单，
/// 源码文件内容逐个从包内读取（不写死在 Swift 代码里）。M4 迁移到 Packages/FairyCore/Sources/TemplateLibrary。
struct ProjectTemplate: Sendable {
    /// 新格式：id/displayName/description/entrySymbol/files[{path}]。
    struct Manifest: Decodable, Sendable {
        struct File: Decodable, Sendable { var path: String }
        var formatVersion: Int
        var id: String
        var displayName: String
        var description: String?
        var category: String?
        var entrySymbol: String?
        // 旧格式（Templates/Counter 时代）：entry.rootView + files[{id, path}]。
        var entry: LegacyEntry?
        struct LegacyEntry: Decodable, Sendable { var rootView: String? }
        struct LegacyFile: Decodable, Sendable { var id: String; var path: String }
        var legacyFiles: [LegacyFile]?
        enum CodingKeys: String, CodingKey {
            case formatVersion, id, displayName, description, category, entrySymbol, entry, files
        }
        // files 可能是 [{path}] 或旧 [{id, path}]，都按 path 读取。
        var filePaths: [String]
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            id = try c.decode(String.self, forKey: .id)
            displayName = try c.decode(String.self, forKey: .displayName)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            category = try c.decodeIfPresent(String.self, forKey: .category)
            entrySymbol = try c.decodeIfPresent(String.self, forKey: .entrySymbol)
            entry = try c.decodeIfPresent(LegacyEntry.self, forKey: .entry)
            if let simple = try? c.decode([File].self, forKey: .files) {
                filePaths = simple.map(\.path)
            } else {
                legacyFiles = try c.decode([LegacyFile].self, forKey: .files)
                filePaths = legacyFiles?.map(\.path) ?? []
            }
        }
    }

    var id: String
    var displayName: String
    var description: String?
    var category: String?
    var entry: EntryPoint
    var files: [SourceFile]

    enum LoadError: Error, CustomStringConvertible {
        case missingDirectory(String)
        case ambiguousIdentifier(String)
        case unsupportedFormat(Int)
        case missingEntry
        case unreadableFile(String, any Error)

        var description: String {
            switch self {
            case let .missingDirectory(name): "App 包中找不到模板目录 Templates/\(name)"
            case let .ambiguousIdentifier(name): "多个内置模板使用同一标识：\(name)"
            case let .unsupportedFormat(version): "模板格式版本 \(version) 不受支持"
            case .missingEntry: "模板未声明入口（entrySymbol / entry.rootView）"
            case let .unreadableFile(path, error): "无法读取模板文件 \(path)：\(error)"
            }
        }
    }

    static func load(named name: String, bundle: Bundle = .main) throws -> ProjectTemplate {
        let base = try directory(named: name, bundle: bundle)
        let manifestURL = base.appendingPathComponent("template.json")
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LoadError.unreadableFile("template.json", error)
        }
        guard manifest.formatVersion == 1 else { throw LoadError.unsupportedFormat(manifest.formatVersion) }
        guard let rootView = manifest.entrySymbol ?? manifest.entry?.rootView else { throw LoadError.missingEntry }
        var files: [SourceFile] = []
        for (index, path) in manifest.filePaths.enumerated() {
            do {
                let contents = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                files.append(SourceFile(id: FileID("\(manifest.id)-\(index)"), path: path, contents: contents))
            } catch {
                throw LoadError.unreadableFile(path, error)
            }
        }
        return ProjectTemplate(id: manifest.id, displayName: manifest.displayName, description: manifest.description,
                               category: manifest.category, entry: .rootView(symbol: rootView), files: files)
    }

    /// Template IDs need not equal directory names (the legacy counter lives in Counter/).
    /// Resolve a unique manifest ID rather than relying on case-insensitive filesystems.
    private static func directory(named name: String, bundle: Bundle) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              let resources = bundle.resourceURL else { throw LoadError.missingDirectory(name) }
        let root = resources.appendingPathComponent("Templates", isDirectory: true)
        let direct = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("template.json").path) {
            return direct
        }
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let matches = directories.filter { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("template.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return false }
            return manifest.id == name
        }
        guard matches.count <= 1 else { throw LoadError.ambiguousIdentifier(name) }
        guard let match = matches.first else { throw LoadError.missingDirectory(name) }
        return match
    }

}
