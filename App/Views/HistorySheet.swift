import SwiftUI
import ProjectContracts

/// 历史时间线（计划 §9.3）：自然语言任务记录 + 模型 + 已运行版本 + 恢复上一版。
/// 恢复只回滚源码（经同一事务校验）；业务数据不在记录范围内，不受影响。
struct HistorySheet: View {
    let session: AssistantSession
    let onRestore: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if session.appliedRecords.isEmpty {
                    ContentUnavailableView {
                        Label("还没有应用记录", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("AI 修改被应用后会出现在这里，可查看版本并恢复上一版源码。")
                    }
                } else {
                    List {
                        ForEach(Array(session.appliedRecords.enumerated().reversed()), id: \.element.id) { index, record in
                            row(index: index, record: record)
                        }
                    }
                }
            }
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(index: Int, record: AppliedChangeRecord) -> some View {
        let isLatest = index == session.appliedRecords.count - 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("r\\(record.revision.rawValue)").font(.headline)
                Text(record.backend).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(record.files.indices, id: \.self) { i in
                Text("\\(record.files[i].1)（+\\(record.files[i].2) / −\\(record.files[i].3)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isLatest && !record.previousFiles.isEmpty {
                Button("恢复上一版源码（不回滚业务数据）") {
                    onRestore(record.id)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 模板库（计划 §3.3）：按类别分组的完整列表；点击进入详情或复制为新作品。
struct TemplateGalleryView: View {
    let templates: [ProjectTemplate]
    let onCreate: (ProjectTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    private var categories: [(String, [ProjectTemplate])] {
        var order: [String] = []
        var map: [String: [ProjectTemplate]] = [:]
        for t in templates {
            let c = t.category ?? "其他"
            if map[c] == nil { order.append(c) }
            map[c, default: []].append(t)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(categories.indices, id: \.self) { ci in
                Section(categories[ci].0) {
                    ForEach(categories[ci].1, id: \.id) { template in
                        Button {
                            onCreate(template)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.displayName).font(.headline)
                                if let description = template.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("模板 · 复制为新作品").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.template.\\(template.id)")
                    }
                }
            }
        }
        .navigationTitle("模板库")
        .navigationBarTitleDisplayMode(.inline)
    }
}
