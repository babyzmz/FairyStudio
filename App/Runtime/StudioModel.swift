import Foundation
import Observation
import RuntimeContracts

/// 「运行实验」页的状态：可编辑源码文件（默认加载 Counter 模板）、入口、预算与 RunCoordinator。
@MainActor
@Observable
final class StudioModel {
    struct EditableFile: Identifiable, Hashable {
        let id: FileID
        var path: String
        var contents: String

        var fileName: String { (path as NSString).lastPathComponent }
    }

    /// 文件顺序即传给运行时的 `ProgramSource.files` 顺序；可交换以验证顺序无关。
    var files: [EditableFile]
    var selectedFileID: FileID
    let entry: EntryPoint
    let templateName: String
    let engineChoice: EngineChoice
    let budget: ExecutionBudget
    /// 预算说明（DEBUG 长预算时在诊断面板可见）。
    let budgetDescription: String
    let coordinator: RunCoordinator

    init(templateName: String = "Counter", engineChoice: EngineChoice = .swiftRuntime,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        let loaded: ProjectTemplate
        var loadError: String?
        do {
            loaded = try ProjectTemplate.load(named: templateName)
        } catch {
            // 模板缺失是打包错误：如实显示为空项目并在诊断中给出原因，不用内置字符串替代。
            loaded = ProjectTemplate(id: templateName, displayName: templateName, entry: .rootView(symbol: "ContentView"), files: [])
            loadError = "\(error)"
        }
        let files = loaded.files.map { EditableFile(id: $0.id, path: $0.path, contents: $0.contents) }
        self.files = files
        self.selectedFileID = files.first?.id ?? FileID("none")
        self.entry = loaded.entry
        self.templateName = loaded.displayName
        self.engineChoice = engineChoice
        let (budget, description) = Self.budget(from: arguments)
        self.budget = budget
        self.budgetDescription = description
        self.coordinator = RunCoordinator(engine: engineChoice.makeEngine())
        if let loadError { coordinator.reportHostError("模板加载失败：\(loadError)") }
    }

    /// 默认使用契约默认预算。DEBUG 构建可用启动参数 `-fairy.budget long` 换成「长预算」
    /// （步数几乎不限、单片墙钟 1 小时），用于测量用户点击停止的延迟：否则无限循环会先被默认预算中断。
    static func budget(from arguments: [String]) -> (ExecutionBudget, String) {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-fairy.budget"), arguments.indices.contains(index + 1), arguments[index + 1] == "long" {
            return (ExecutionBudget(maxSteps: Int.max / 2, sliceWallClock: .seconds(3600)), "调试长预算（maxSteps≈∞，slice 1h）")
        }
        #endif
        return (.default, "默认预算（maxSteps 5,000,000，slice 200ms）")
    }

    var program: ProgramSource {
        ProgramSource(moduleName: "Experiment", files: files.map { SourceFile(id: $0.id, path: $0.path, contents: $0.contents) })
    }

    /// 当前文件顺序（显示与测试用）。
    var fileOrderDescription: String {
        files.map(\.fileName).joined(separator: " → ")
    }

    func run() {
        coordinator.run(program, entry: entry, budget: budget)
    }

    func stop() {
        coordinator.stop()
    }

    /// 交换（反转）文件顺序。运行结果不得因此改变（运行时先收集全部声明再解析引用）。
    func reverseFileOrder() {
        files.reverse()
    }

    func contents(of fileID: FileID) -> String {
        files.first { $0.id == fileID }?.contents ?? ""
    }

    func updateContents(of fileID: FileID, to contents: String) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        guard files[index].contents != contents else { return }
        files[index].contents = contents
    }
}
