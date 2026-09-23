import Foundation
import RuntimeContracts
import SwiftRuntime

/// fairy-run：SwiftRuntime 的无头运行工具（开发验证用，不进入产品）。
enum CLI {
    static let usage = """
    用法：
      fairy-run run <目录|文件.swift>... [--entry script|rootView:名称|mainApp] [--max-steps N] [--json] [--module-name 名称]
      fairy-run render <目录|文件.swift>... [--entry ...] [--max-steps N] [--appear]
      fairy-run validate <目录|文件.swift>... [--json]
      fairy-run catalog [--markdown]

    退出码：0 正常结束；1 运行错误（trap）或失败；2 预算超限；3 校验失败；64 用法错误。
    """

    struct Options {
        var command = ""
        var paths: [String] = []
        var entry: String?
        var maxSteps: Int?
        var json = false
        var markdown = false
        var appear = false
        var moduleName = "main"
    }

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        guard let cmd = args.first else { return nil }
        o.command = cmd
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--entry":
                i += 1
                guard i < args.count else { return nil }
                o.entry = args[i]
            case "--max-steps":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else { return nil }
                o.maxSteps = n
            case "--module-name":
                i += 1
                guard i < args.count else { return nil }
                o.moduleName = args[i]
            case "--json": o.json = true
            case "--markdown": o.markdown = true
            case "--appear": o.appear = true
            default:
                if a.hasPrefix("--") { return nil }
                o.paths.append(a)
            }
            i += 1
        }
        return o
    }

    /// 收集源文件：目录递归查找 .swift（按相对路径排序），FileID 与 path 使用相对路径。
    static func loadProgram(_ paths: [String], moduleName: String) throws -> ProgramSource {
        var files: [SourceFile] = []
        let fm = FileManager.default
        for p in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else {
                throw CLIError.message("找不到路径：\(p)")
            }
            if isDir.boolValue {
                let base = URL(fileURLWithPath: p).standardizedFileURL
                guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                var found: [URL] = []
                for case let url as URL in en where url.pathExtension == "swift" { found.append(url.standardizedFileURL) }
                for url in found.sorted(by: { $0.path < $1.path }) {
                    let rel = String(url.path.dropFirst(base.path.count + 1))
                    files.append(SourceFile(id: FileID(rel), path: rel, contents: try String(contentsOf: url, encoding: .utf8)))
                }
            } else {
                let url = URL(fileURLWithPath: p)
                files.append(SourceFile(id: FileID(url.lastPathComponent), path: url.lastPathComponent,
                                        contents: try String(contentsOf: url, encoding: .utf8)))
            }
        }
        if files.isEmpty { throw CLIError.message("没有找到 .swift 文件。") }
        return ProgramSource(moduleName: moduleName, files: files)
    }

    enum CLIError: Error { case message(String) }

    static func resolveEntry(_ spec: String?, _ v: ValidationResult) -> EntryPoint? {
        if let spec {
            if spec == "script" {
                for e in v.entryPoints { if case .script = e { return e } }
                return nil
            }
            if spec == "mainApp" { return .mainApp }
            if spec.hasPrefix("rootView:") { return .rootView(symbol: String(spec.dropFirst("rootView:".count))) }
            return nil
        }
        if v.entryPoints.contains(.mainApp) { return .mainApp }
        for e in v.entryPoints { if case .script = e { return e } }
        let roots = v.entryPoints.filter { if case .rootView = $0 { return true }; return false }
        if roots.count == 1 { return roots[0] }
        if let cv = roots.first(where: { $0 == .rootView(symbol: "ContentView") }) { return cv }
        return roots.first
    }

    static func formatDiagnostic(_ d: Diagnostic) -> String {
        var loc = ""
        if let r = d.range { loc = "\(r.start.fileID):\(r.start.line):\(r.start.column): " }
        let cap = d.capabilityID.map { " [\($0)]" } ?? ""
        return "\(loc)\(d.severity.rawValue): \(d.kind.rawValue): \(d.message)\(cap)"
    }

    static func printErr(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    static func writeOut(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }

    static func jsonString<T: Encodable>(_ v: T, pretty: Bool) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? String(data: enc.encode(v), encoding: .utf8)) ?? "{}"
    }

    // MARK: - 命令

    static func main(_ args: [String]) async -> Int32 {
        guard let o = parse(args) else {
            printErr(usage)
            return 64
        }
        switch o.command {
        case "catalog":
            if o.markdown { writeOut(SupportDocGenerator.markdown(SwiftRuntimeEngine.catalog)) } else {
                writeOut(jsonString(SwiftRuntimeEngine.catalog, pretty: true) + "\n")
            }
            return 0
        case "validate", "run", "render":
            break
        default:
            printErr(usage)
            return 64
        }
        guard !o.paths.isEmpty else {
            printErr(usage)
            return 64
        }
        let program: ProgramSource
        do { program = try loadProgram(o.paths, moduleName: o.moduleName) } catch CLIError.message(let m) {
            printErr(m)
            return 64
        } catch {
            printErr("\(error)")
            return 64
        }
        let engine = SwiftRuntimeEngine()
        let v = await engine.validate(program)
        if o.command == "validate" {
            if o.json {
                writeOut(jsonString(v, pretty: true) + "\n")
            } else {
                for d in v.diagnostics { writeOut(formatDiagnostic(d) + "\n") }
                writeOut("入口：\(v.entryPoints)\n能力：\(v.referencedCapabilities.joined(separator: ", "))\n")
            }
            return v.isRunnable ? 0 : 3
        }
        if !v.isRunnable {
            for d in v.diagnostics { printErr(formatDiagnostic(d)) }
            return 3
        }
        guard let entry = resolveEntry(o.entry, v) else {
            printErr("无法确定入口（可用：\(v.entryPoints)）。请使用 --entry。")
            return 64
        }
        var budget = ExecutionBudget.default
        if let n = o.maxSteps { budget.maxSteps = n }
        let handle: SwiftRunHandle
        do { handle = try await engine.runHandle(program, entry: entry, budget: budget) } catch {
            printErr("启动失败：\(error)")
            return 1
        }
        var exit: Int32 = 0
        var lastTree: RenderTree?
        var isUI = true
        if case .script = entry { isUI = false }
        var appearSent = false
        for await env in handle.events {
            if o.json && o.command == "run" { writeOut(jsonString(EventJSON(env), pretty: false) + "\n") }
            switch env.event {
            case .console(_, let text):
                if !o.json && o.command == "run" { writeOut(text) }
            case .diagnostic(let d):
                if !o.json { printErr(formatDiagnostic(d)) }
            case .render(let tree):
                lastTree = tree
                if o.appear && !appearSent {
                    appearSent = true
                    var seq: UInt64 = 1
                    for nid in appearNodes(tree.root) {
                        await handle.send(RuntimeInputEnvelope(runID: handle.runID, sequence: seq, input: .appear(nid)))
                        seq += 1
                    }
                }
                if isUI { Task { await handle.stop() } }
            case .stateChanged(let s):
                if s == .failed && exit == 0 { exit = 1 }
                if s == .failed && lastTree == nil && !isUI { exit = max(exit, 1) }
            case .finished(let reason):
                switch reason {
                case .completed, .stoppedByUser: break
                case .trap, .internalError: exit = 1
                case .budgetExceeded: exit = 2
                }
            case .capabilityRequest:
                break
            }
        }
        await handle.stop()
        if o.command == "render" {
            if let t = lastTree { writeOut(jsonString(t, pretty: true) + "\n") } else {
                printErr("没有产生 RenderTree。")
                if exit == 0 { exit = 1 }
            }
        }
        return exit
    }

    static func appearNodes(_ n: RenderNode) -> [NodeID] {
        var out: [NodeID] = []
        if n.modifiers.contains(where: { if case .onAppear = $0 { return true }; if case .task = $0 { return true }; return false }) {
            out.append(n.id)
        }
        for c in n.children { out += appearNodes(c) }
        return out
    }
}

/// 事件的 JSON 表示（--json）。
struct EventJSON: Encodable {
    let runID: String
    let sequence: UInt64
    let type: String
    var state: String?
    var tree: RenderTree?
    var diagnostic: Diagnostic?
    var stream: String?
    var text: String?
    var reason: ExitReason?

    init(_ env: RuntimeEventEnvelope) {
        runID = env.runID.description
        sequence = env.sequence
        switch env.event {
        case .stateChanged(let s): type = "stateChanged"; state = s.rawValue
        case .render(let t): type = "render"; tree = t
        case .diagnostic(let d): type = "diagnostic"; diagnostic = d
        case .console(let s, let t): type = "console"; stream = s.rawValue; text = t
        case .capabilityRequest: type = "capabilityRequest"
        case .finished(let r): type = "finished"; reason = r
        }
    }
}
