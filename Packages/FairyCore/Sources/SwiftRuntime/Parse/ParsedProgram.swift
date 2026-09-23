import RuntimeContracts
import SwiftDiagnostics
import SwiftOperators
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// 一个已解析的源文件：运算符已按标准优先级折叠。
struct ParsedFile {
    let index: Int
    let source: SourceFile
    let map: SourceMap
    let tree: SourceFileSyntax
    let hasParseErrors: Bool

    var fileName: String { source.path.split(separator: "/").last.map(String.init) ?? source.path }
    var isMainSwift: Bool { fileName == "main.swift" }

    func range(of node: some SyntaxProtocol) -> RuntimeContracts.SourceRange {
        map.range(start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                  end: node.endPositionBeforeTrailingTrivia.utf8Offset)
    }
}

enum ProgramParser {
    /// 解析全部文件。文件先按 (path, id) 排序，保证处理顺序与输入顺序无关。
    static func parse(_ program: ProgramSource) -> (files: [ParsedFile], diagnostics: [RuntimeContracts.Diagnostic]) {
        let sorted = program.files.sorted { ($0.path, $0.id.rawValue) < ($1.path, $1.id.rawValue) }
        var files: [ParsedFile] = []
        var diags: [RuntimeContracts.Diagnostic] = []
        for (i, src) in sorted.enumerated() {
            let map = SourceMap(file: src)
            let raw = Parser.parse(source: src.contents)
            let parseDiags = ParseDiagnosticsGenerator.diagnostics(for: raw)
            for d in parseDiags where d.diagMessage.severity == .error {
                let start = d.position.utf8Offset
                let end = max(start, d.node.endPositionBeforeTrailingTrivia.utf8Offset)
                diags.append(RuntimeContracts.Diagnostic(kind: .parse, severity: .error, message: "语法错误：\(d.message)",
                                        range: map.range(start: start, end: min(end, start + 200))))
            }
            // 运算符折叠：标准运算符表；自定义运算符声明另行报"尚不支持"。
            let folded = OperatorTable.standardOperators.foldAll(raw) { _ in }
            let tree = folded.as(SourceFileSyntax.self) ?? raw
            files.append(ParsedFile(index: i, source: src, map: map, tree: tree,
                                    hasParseErrors: parseDiags.contains { $0.diagMessage.severity == .error }))
        }
        return (files, diags)
    }
}
