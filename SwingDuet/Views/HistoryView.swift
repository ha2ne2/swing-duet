import SwiftUI

/// 比較の履歴。タップで開き直し、スワイプで削除する
struct HistoryView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let onOpen: (ComparisonProject) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        "履歴はまだありません",
                        systemImage: "clock",
                        description: Text("両方の動画がそろった比較が、自動でここに残ります。"))
                } else {
                    List {
                        ForEach(store.projects) { project in
                            Button {
                                onOpen(project)
                                dismiss()
                            } label: {
                                HistoryRow(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var store: ProjectStore
    let project: ComparisonProject

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(VideoSide.allCases) { side in
                    let config = project.config(for: side)
                    VideoThumbnail(url: store.videoURL(for: config.fileName), time: config.phases.impact, aspect: 44 / 60)
                        .frame(width: 44, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                Text("\(store.model(id: project.modelID)?.name ?? "お手本") · 自分 \(project.mine.phases.tempoText) · お手本 \(project.model.phases.tempoText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
