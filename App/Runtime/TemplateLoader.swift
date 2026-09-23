import Foundation
import RuntimeContracts

/// TemplateLibrary 雏形：从 App 包内 `Templates/<名称>/template.json` 读取模板的入口与文件清单，
/// 源码文件内容逐个从包内读取（不写死在 Swift 代码里）。M4 迁移到 Packages/FairyCore/Sources/TemplateLibrary。
struct ProjectTemplate: Sendable {
    struct Manifest: Decodable, Sendable {
        struct Entry: Decodable, Sendable { var rootView: String? }
        struct File: Decodable, Sendable { var id: String; var path: String }
        var formatVersion: Int
        var id: String
        var displayName: String
        var entry: Entry
        var files: [File]
    }

    var id: String
    var displayName: String
    var entry: EntryPoint
    var files: [SourceFile]

    enum LoadError: Error, CustomStringConvertible {
        case missingDirectory(String)
        case unsupportedFormat(Int)
        case missingEntry
        case unreadableFile(String, any Error)

        var description: String {
            switch self {
            case let .missingDirectory(name): "App 包中找不到模板目录 Templates/\(name)"
            case let .unsupportedFormat(version): "模板格式版本 \(version) 不受支持"
            case .missingEntry: "模板未声明入口（entry.rootView）"
            case let .unreadableFile(path, error): "无法读取模板文件 \(path)：\(error)"
            }
        }
    }

    static func load(named name: String, bundle: Bundle = .main) throws -> ProjectTemplate {
        guard let base = bundle.url(forResource: name, withExtension: nil, subdirectory: "Templates") else {
            throw LoadError.missingDirectory(name)
        }
        let manifestURL = base.appendingPathComponent("template.json")
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LoadError.unreadableFile("template.json", error)
        }
        guard manifest.formatVersion == 1 else { throw LoadError.unsupportedFormat(manifest.formatVersion) }
        guard let rootView = manifest.entry.rootView else { throw LoadError.missingEntry }
        let files = try manifest.files.map { file in
            do {
                let contents = try String(contentsOf: base.appendingPathComponent(file.path), encoding: .utf8)
                return SourceFile(id: FileID(file.id), path: file.path, contents: contents)
            } catch {
                throw LoadError.unreadableFile(file.path, error)
            }
        }
        return ProjectTemplate(id: manifest.id, displayName: manifest.displayName, entry: .rootView(symbol: rootView), files: files)
    }
}
