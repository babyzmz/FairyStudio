import RuntimeContracts

/// 每文件 source map：UTF-8 偏移 ↔ 行列。行列均为 1-based，列按 UTF-8 字节计（编辑器负责换算为 UTF-16）。
struct SourceMap: Sendable {
    let fileID: FileID
    let path: String
    /// 每一行起始处的 UTF-8 偏移。
    private let lineStarts: [Int]
    let utf8Count: Int

    init(file: SourceFile) {
        fileID = file.id
        path = file.path
        var starts = [0]
        var i = 0
        for b in file.contents.utf8 {
            i += 1
            if b == UInt8(ascii: "\n") { starts.append(i) }
        }
        lineStarts = starts
        utf8Count = i
    }

    var lineCount: Int { lineStarts.count }

    func location(utf8Offset raw: Int) -> SourceLocation {
        let offset = max(0, min(raw, utf8Count))
        // 二分查找最后一个 <= offset 的行首
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return SourceLocation(fileID: fileID, line: lo + 1, column: offset - lineStarts[lo] + 1, utf8Offset: offset)
    }

    func range(start: Int, end: Int) -> SourceRange {
        SourceRange(start: location(utf8Offset: start), end: location(utf8Offset: max(start, end)))
    }

    /// 行列 → UTF-8 偏移（越界返回 nil）。
    func utf8Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
        let start = lineStarts[line - 1]
        let lineEnd = line < lineStarts.count ? lineStarts[line] : utf8Count
        let off = start + column - 1
        return off <= lineEnd ? off : nil
    }
}
