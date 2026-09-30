import SwiftUI
import FoundationAI
import RuntimeContracts

// 变更卡片：文件、+/−行 diff 行数、说明；按钮：应用并运行 / 查看差异 / 放弃。
struct ChangeCardView: View {
    let pending: PendingChange
    let status: AssistantCardStatus
    var onApply: () -> Void
    var onDiscard: () -> Void
    var onLocate: (FileID, Int) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("代码修改（\(pending.files.count) 个文件）", systemImage: "doc.badge.gearshape")
                .font(.headline)
            ForEach(pending.files, id: \.path) { file in
                Button {
                    if let id = file.fileID { onLocate(id, 1) }
                } label: {
                    HStack {
                        Image(systemName: icon(for: file.kind))
                        Text(verbatim: file.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: "+\(file.addedLines)/−\(file.removedLines)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(file.fileID == nil)
                if let note = file.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if expanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detailedFiles, id: \.path) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: file.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(verbatim: file.contents)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            statusRow
            if status == .pending {
                HStack {
                    Button("应用并运行") { onApply() }
                        .buttonStyle(.borderedProminent)
                    Button(expanded ? "收起差异" : "查看差异") { expanded.toggle() }
                        .buttonStyle(.bordered)
                    Button("放弃", role: .destructive) { onDiscard() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("assistant.changeCard")
    }

    private var statusRow: some View {
        Group {
            switch status {
            case .pending:
                if pending.contextTrimmed {
                    Label("已裁剪上下文", systemImage: "scissors")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .applying:
                Label("应用中…", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
            case .applied:
                Label("已应用", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            case .discarded:
                Label("已放弃", systemImage: "xmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .expired:
                Label("已过期：项目有新版本，请重新发送", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            case let .applyFailed(detail):
                Label("应用失败：\(detail)", systemImage: "xmark.octagon")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func icon(for kind: PendingFileChange.Kind) -> String {
        switch kind {
        case .created: "doc.badge.plus"
        case .replaced: "doc.badge.gearshape"
        case .renamed: "pencil"
        case .deleted: "trash"
        }
    }

    /// 展开态显示各文件的新内容（create/replace 取候选快照）。
    private struct DetailedFile: Hashable {
        var path: String
        var contents: String
    }

    private var detailedFiles: [DetailedFile] {
        pending.files.compactMap { file in
            switch file.kind {
            case .created, .replaced:
                guard let id = file.fileID,
                      let snap = pending.candidate.file(id: id) else { return nil }
                return DetailedFile(path: file.path, contents: snap.contents)
            case .renamed, .deleted:
                return nil
            }
        }
    }
}
