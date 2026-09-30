import SwiftUI
import RuntimeContracts

// 诊断卡片：可展开，点某行经 onLocate 定位到文件行。
struct DiagnosticCardView: View {
    let diagnostics: [Diagnostic]
    let source: String
    var onLocate: (FileID, Int) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Image(systemName: hasErrors ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(hasErrors ? .red : .green)
                    Text("\(source)：\(errorCount) 个错误，\(warningCount) 个警告")
                        .font(.headline)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(diagnostics) { diag in
                    diagnosticRow(diag)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("assistant.diagnosticCard")
    }

    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    private var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    private var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    private func diagnosticRow(_ diag: Diagnostic) -> some View {
        Button {
            if let range = diag.range { onLocate(range.start.fileID, range.start.line) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "[\(diag.severity)] \(diag.kind.rawValue)：\(diag.message)")
                    .font(.callout)
                if let range = diag.range {
                    Text(verbatim: "\(range.start.fileID):\(range.start.line)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let suggestion = diag.suggestion {
                    Text(verbatim: "建议：\(suggestion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(diag.range == nil)
    }
}
